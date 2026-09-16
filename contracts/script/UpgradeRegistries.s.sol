// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script} from "forge-std/Script.sol";
import {DirectOperation} from "./DeployTypes.sol";
import {IDvPGovernanceView} from "../src/interfaces/IDvPGovernanceView.sol";
import {IDvPSettlement} from "../src/interfaces/IDvPSettlement.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {ReasonCode} from "../src/types/HTPTypes.sol";

interface IUpgradeableRegistry {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
}

struct UpgradeSnapshot {
    address implementation;
    bytes32 implementationCodeHash;
    bytes32 dependentHistoryHash;
    bytes32[] publicStateHashes;
}

struct UpgradeVerificationSet {
    address[] registries;
    address[] implementations;
    bytes32[] codeHashes;
    UpgradeSnapshot[] beforeStates;
    bytes[][] publicStateProbes;
    address expectedDefaultAdmin;
    address expectedGovernance;
    address expectedUpgrader;
}

/// @notice Fixed pause -> upgrade -> verify -> unpause runbook.
contract UpgradeRegistries is Script {
    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error UpgradeRunbookCheckFailed(bytes32 check, address target);
    error DependentDvpNotPaused(address dvp);
    error ProbeFailed(address target, bytes data);

    function snapshot(address registry, bytes[] calldata publicStateProbes)
        external
        view
        returns (UpgradeSnapshot memory state)
    {
        state.implementation = _implementation(registry);
        state.implementationCodeHash = state.implementation.codehash;
        state.dependentHistoryHash = _dependentHistoryHash(registry);
        state.publicStateHashes = _probeHashes(registry, publicStateProbes);
    }

    function buildUpgrade(
        address registry,
        address expectedCurrentImplementation,
        address newImplementation,
        bytes calldata migrationCall
    ) external view returns (DirectOperation memory operation) {
        if (_implementation(registry) != expectedCurrentImplementation) {
            revert UpgradeRunbookCheckFailed("STALE_IMPLEMENTATION", registry);
        }
        if (newImplementation == address(0) || newImplementation.code.length == 0) {
            revert UpgradeRunbookCheckFailed("NEW_IMPLEMENTATION_CODE", newImplementation);
        }
        _requireEveryDependentPaused(registry);
        operation = DirectOperation({
            target: registry,
            data: abi.encodeCall(IUpgradeableRegistry.upgradeToAndCall, (newImplementation, migrationCall))
        });
    }

    function verifyUpgrade(
        address registry,
        address expectedNewImplementation,
        bytes32 expectedNewCodeHash,
        UpgradeSnapshot calldata beforeState,
        bytes[] calldata publicStateProbes,
        address expectedDefaultAdmin,
        address expectedGovernance,
        address expectedUpgrader
    ) external view {
        _verifyUpgrade(
            registry,
            expectedNewImplementation,
            expectedNewCodeHash,
            beforeState,
            publicStateProbes,
            expectedDefaultAdmin,
            expectedGovernance,
            expectedUpgrader
        );
    }

    function buildUnpauseAfterSuccessfulVerification(
        address dvp,
        UpgradeVerificationSet calldata verification,
        bytes32 rehearsalEvidenceHash
    ) external view returns (DirectOperation memory operation) {
        uint256 count = verification.registries.length;
        if (
            count == 0 || count != verification.implementations.length || count != verification.codeHashes.length
                || count != verification.beforeStates.length || count != verification.publicStateProbes.length
        ) {
            revert UpgradeRunbookCheckFailed("UPGRADE_SET_LENGTH", dvp);
        }
        if (!IDvPGovernanceView(dvp).globalPaused()) {
            revert UpgradeRunbookCheckFailed("DVP_NOT_PAUSED", dvp);
        }
        if (rehearsalEvidenceHash == bytes32(0)) revert UpgradeRunbookCheckFailed("EVIDENCE_REQUIRED", dvp);
        for (uint256 i = 0; i < count; ++i) {
            _verifyUpgrade(
                verification.registries[i],
                verification.implementations[i],
                verification.codeHashes[i],
                verification.beforeStates[i],
                verification.publicStateProbes[i],
                verification.expectedDefaultAdmin,
                verification.expectedGovernance,
                verification.expectedUpgrader
            );
        }
        operation = DirectOperation({
            target: dvp,
            data: abi.encodeCall(IDvPSettlement.unpauseGlobal, (ReasonCode.GOVERNANCE_ACTION, rehearsalEvidenceHash))
        });
    }

    function dependentHistoryHash(address registry) external view returns (bytes32) {
        return _dependentHistoryHash(registry);
    }

    function _verifyUpgrade(
        address registry,
        address expectedNewImplementation,
        bytes32 expectedNewCodeHash,
        UpgradeSnapshot calldata beforeState,
        bytes[] calldata publicStateProbes,
        address expectedDefaultAdmin,
        address expectedGovernance,
        address expectedUpgrader
    ) private view {
        if (publicStateProbes.length == 0 || beforeState.publicStateHashes.length == 0) {
            revert UpgradeRunbookCheckFailed("PUBLIC_PROBES_REQUIRED", registry);
        }
        if (_implementation(registry) != expectedNewImplementation) {
            revert UpgradeRunbookCheckFailed("UPGRADE_SLOT", registry);
        }
        if (expectedNewImplementation.codehash != expectedNewCodeHash) {
            revert UpgradeRunbookCheckFailed("UPGRADE_CODE_HASH", expectedNewImplementation);
        }
        if (_dependentHistoryHash(registry) != beforeState.dependentHistoryHash) {
            revert UpgradeRunbookCheckFailed("DEPENDENT_HISTORY_CHANGED", registry);
        }
        bytes32[] memory afterHashes = _probeHashes(registry, publicStateProbes);
        if (afterHashes.length != beforeState.publicStateHashes.length) {
            revert UpgradeRunbookCheckFailed("PROBE_LENGTH", registry);
        }
        for (uint256 i = 0; i < afterHashes.length; ++i) {
            if (afterHashes[i] != beforeState.publicStateHashes[i]) {
                revert UpgradeRunbookCheckFailed("PUBLIC_STORAGE_CHANGED", registry);
            }
        }
        IAccessControl access = IAccessControl(registry);
        if (
            !access.hasRole(Roles.DEFAULT_ADMIN_ROLE, expectedDefaultAdmin)
                || !access.hasRole(Roles.GOVERNANCE_ROLE, expectedGovernance)
                || !access.hasRole(Roles.UPGRADER_ROLE, expectedUpgrader)
        ) {
            revert UpgradeRunbookCheckFailed("ADMIN_ROLES_CHANGED", registry);
        }
        _requireEveryDependentPaused(registry);
    }

    function _requireEveryDependentPaused(address registry) private view {
        IUpgradeableRegistry target = IUpgradeableRegistry(registry);
        uint256 count = target.getDependentDvpCount();
        if (count == 0) revert UpgradeRunbookCheckFailed("NO_DEPENDENT_DVP", registry);
        for (uint256 i = 0; i < count; ++i) {
            (address dvp, bool retiredExempt) = target.getDependentDvp(i);
            if (retiredExempt) continue;
            if (!IDvPGovernanceView(dvp).globalPaused()) revert DependentDvpNotPaused(dvp);
        }
    }

    function _dependentHistoryHash(address registry) private view returns (bytes32 digest) {
        IUpgradeableRegistry target = IUpgradeableRegistry(registry);
        uint256 count = target.getDependentDvpCount();
        digest = keccak256(abi.encode(count));
        for (uint256 i = 0; i < count; ++i) {
            (address dvp, bool retiredExempt) = target.getDependentDvp(i);
            digest = keccak256(abi.encode(digest, i, dvp, retiredExempt));
        }
    }

    function _probeHashes(address target, bytes[] calldata probes) private view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](probes.length);
        for (uint256 i = 0; i < probes.length; ++i) {
            (bool success, bytes memory result) = target.staticcall(probes[i]);
            if (!success) revert ProbeFailed(target, probes[i]);
            hashes[i] = keccak256(result);
        }
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
