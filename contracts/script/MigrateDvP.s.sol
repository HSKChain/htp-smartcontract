// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DirectOperation} from "./DeployTypes.sol";
import {IDvPGovernanceView} from "../src/interfaces/IDvPGovernanceView.sol";
import {IDvPSettlement} from "../src/interfaces/IDvPSettlement.sol";
import {IAssetVersionRegistry} from "../src/interfaces/IAssetVersionRegistry.sol";
import {AssetVersionConfig, AssetVersionRecord, AssetVersionStatus, ReasonCode} from "../src/types/HTPTypes.sol";

interface IDependentDvpRegistry {
    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
}

/// @notice Stage-gated DvP migration operation builder.
contract MigrateDvP {
    error MigrationOrderViolation(bytes32 stage, address target);

    function buildAuthorizeNewDvp(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address[] calldata dependentRegistries,
        bytes32 expectedNewDeploymentVersionHash,
        bytes32 evidenceHash
    ) external view returns (DirectOperation[] memory operations) {
        _requirePausedLive(oldDvp, "AUTHORIZE_OLD_PAUSED");
        _requirePausedLive(newDvp, "AUTHORIZE_NEW_PAUSED");
        if (
            address(IDvPSettlement(newDvp).eligibilityRegistry()) != eligibilityRegistry
                || IDvPGovernanceView(newDvp).deploymentVersionHash() != expectedNewDeploymentVersionHash
        ) {
            revert MigrationOrderViolation("NEW_DVP_IMMUTABLES", newDvp);
        }
        if (_isDependent(eligibilityRegistry, newDvp)) {
            revert MigrationOrderViolation("DEPENDENT_ALREADY_REGISTERED", eligibilityRegistry);
        }
        if (evidenceHash == bytes32(0)) revert MigrationOrderViolation("EVIDENCE_REQUIRED", newDvp);
        if (dependentRegistries.length != 8) {
            revert MigrationOrderViolation("EIGHT_REGISTRIES_REQUIRED", newDvp);
        }
        _requireExactRegistrySet(newDvp, dependentRegistries);

        uint256 operationCount = dependentRegistries.length;
        operations = new DirectOperation[](operationCount);
        bool foundEligibility;
        for (uint256 i = 0; i < dependentRegistries.length; ++i) {
            address registry = dependentRegistries[i];
            if (_isDependent(registry, newDvp)) {
                revert MigrationOrderViolation("DEPENDENT_ALREADY_REGISTERED", registry);
            }
            if (registry == eligibilityRegistry) foundEligibility = true;
            operations[i] = DirectOperation({
                target: registry,
                data: abi.encodeCall(IDependentDvpRegistry.registerDependentDvp, (newDvp, evidenceHash))
            });
        }
        if (!foundEligibility) {
            revert MigrationOrderViolation("ELIGIBILITY_REGISTRY_MISSING", eligibilityRegistry);
        }
    }

    function buildRegisterNewAssetVersion(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address assetVersionRegistry,
        AssetVersionConfig calldata config
    ) external view returns (DirectOperation memory operation) {
        _requirePausedLive(oldDvp, "REGISTER_OLD_PAUSED");
        _requirePausedLive(newDvp, "REGISTER_NEW_PAUSED");
        if (!_isDependent(eligibilityRegistry, newDvp) || !_isDependent(assetVersionRegistry, newDvp)) {
            revert MigrationOrderViolation("NEW_DVP_NOT_REGISTERED", eligibilityRegistry);
        }
        if (
            config.dvpContract != newDvp
                || config.deploymentVersionHash != IDvPGovernanceView(newDvp).deploymentVersionHash()
                || config.replacesAssetVersionId == bytes32(0)
        ) {
            revert MigrationOrderViolation("NEW_ASSET_DOMAIN", assetVersionRegistry);
        }
        AssetVersionRecord memory previous =
            IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(config.replacesAssetVersionId);
        if (
            !previous.exists || previous.config.dvpContract != oldDvp || previous.config.assetToken != config.assetToken
                || previous.config.economicAssetIdHash != config.economicAssetIdHash
        ) {
            revert MigrationOrderViolation("OLD_ASSET_MISMATCH", assetVersionRegistry);
        }
        if (IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(config.assetVersionId).exists) {
            revert MigrationOrderViolation("NEW_ASSET_ALREADY_REGISTERED", assetVersionRegistry);
        }
        operation = DirectOperation({
            target: assetVersionRegistry, data: abi.encodeCall(IAssetVersionRegistry.registerAssetVersion, (config))
        });
    }

    function verifyNewConsumerAuthorization(address eligibilityRegistry, address newDvp, bytes32 newAssetVersionId)
        external
        view
    {
        if (!_isDependent(eligibilityRegistry, newDvp)) {
            revert MigrationOrderViolation("NEW_DVP_NOT_REGISTERED", eligibilityRegistry);
        }
        AssetVersionRecord memory record =
            IDvPSettlement(newDvp).assetVersionRegistry().getAssetVersion(newAssetVersionId);
        if (!record.exists || record.config.dvpContract != newDvp) {
            revert MigrationOrderViolation("NEW_ASSET_AUTHORIZATION", eligibilityRegistry);
        }
    }

    /// @dev The list must come from the deployment manifest plus AssetVersionRegistered
    /// history because the production registry intentionally has no global enumeration ABI.
    function buildPauseOldAssetVersions(
        address oldDvp,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        bytes32 evidenceHash
    ) external view returns (DirectOperation[] memory operations) {
        _requirePausedLive(oldDvp, "PAUSE_VERSIONS_OLD_DVP");
        if (evidenceHash == bytes32(0)) revert MigrationOrderViolation("EVIDENCE_REQUIRED", oldDvp);
        _requireOldAssetVersions(
            oldDvp, assetVersionRegistry, oldAssetVersionIds, AssetVersionStatus.ACTIVE, "OLD_ASSET_NOT_ACTIVE"
        );
        operations = new DirectOperation[](oldAssetVersionIds.length);
        for (uint256 i = 0; i < oldAssetVersionIds.length; ++i) {
            operations[i] = DirectOperation({
                target: assetVersionRegistry,
                data: abi.encodeCall(
                    IAssetVersionRegistry.pauseAssetVersion,
                    (oldAssetVersionIds[i], ReasonCode.PLANNED_MIGRATION, evidenceHash)
                )
            });
        }
    }

    function buildActivateDeprecateAndRevokeOldConsumer(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        bytes32 newAssetVersionId,
        bytes32 expectedConfigHash,
        bytes32 evidenceHash
    ) external view returns (DirectOperation[] memory operations) {
        _requirePausedLive(oldDvp, "REVOKE_OLD_PAUSED");
        _requirePausedLive(newDvp, "REVOKE_NEW_PAUSED");
        if (evidenceHash == bytes32(0)) revert MigrationOrderViolation("EVIDENCE_REQUIRED", oldDvp);
        if (!_isDependent(eligibilityRegistry, newDvp)) {
            revert MigrationOrderViolation("AUTHORIZATION_NOT_VERIFIED", eligibilityRegistry);
        }
        _requireOldAssetVersions(
            oldDvp, assetVersionRegistry, oldAssetVersionIds, AssetVersionStatus.PAUSED, "OLD_ASSET_NOT_PAUSED"
        );
        AssetVersionRecord memory record =
            IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(newAssetVersionId);
        if (
            !record.exists || record.status != AssetVersionStatus.REGISTERED || record.config.dvpContract != newDvp
                || record.config.configHash != expectedConfigHash
        ) {
            revert MigrationOrderViolation("NEW_ASSET_NOT_REGISTERED", assetVersionRegistry);
        }
        if (!_contains(oldAssetVersionIds, record.config.replacesAssetVersionId)) {
            revert MigrationOrderViolation("REPLACED_ASSET_NOT_LISTED", assetVersionRegistry);
        }

        uint256 operationCount = oldAssetVersionIds.length + 1;
        operations = new DirectOperation[](operationCount);
        operations[0] = DirectOperation({
            target: assetVersionRegistry,
            data: abi.encodeCall(IAssetVersionRegistry.activateAssetVersion, (newAssetVersionId, expectedConfigHash))
        });
        for (uint256 i = 0; i < oldAssetVersionIds.length; ++i) {
            operations[i + 1] = DirectOperation({
                target: assetVersionRegistry,
                data: abi.encodeCall(
                    IAssetVersionRegistry.deprecateAssetVersion,
                    (oldAssetVersionIds[i], ReasonCode.PLANNED_MIGRATION, evidenceHash)
                )
            });
        }
    }

    function verifyConsumerCutover(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        bytes32 newAssetVersionId,
        bytes32 incorrectAssetVersionId
    ) external view {
        _verifyConsumerCutover(
            oldDvp,
            newDvp,
            eligibilityRegistry,
            assetVersionRegistry,
            oldAssetVersionIds,
            newAssetVersionId,
            incorrectAssetVersionId
        );
    }

    function buildUnpauseNewDvp(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        bytes32 newAssetVersionId,
        bytes32 incorrectAssetVersionId,
        bytes32 rehearsalEvidenceHash
    ) external view returns (DirectOperation memory operation) {
        _requirePausedLive(oldDvp, "UNPAUSE_OLD_PAUSED");
        _requirePausedLive(newDvp, "UNPAUSE_NEW_PAUSED");
        if (rehearsalEvidenceHash == bytes32(0)) revert MigrationOrderViolation("EVIDENCE_REQUIRED", newDvp);
        _verifyConsumerCutover(
            oldDvp,
            newDvp,
            eligibilityRegistry,
            assetVersionRegistry,
            oldAssetVersionIds,
            newAssetVersionId,
            incorrectAssetVersionId
        );
        operation = _operation(
            newDvp, abi.encodeCall(IDvPSettlement.unpauseGlobal, (ReasonCode.PLANNED_MIGRATION, rehearsalEvidenceHash))
        );
    }

    function buildRetireOldDvp(address oldDvp, address newDvp, address eligibilityRegistry, bytes32 evidenceHash)
        external
        view
        returns (DirectOperation memory operation)
    {
        _requirePausedLive(oldDvp, "RETIRE_OLD_PAUSED");
        if (IDvPGovernanceView(newDvp).globalPaused() || IDvPGovernanceView(newDvp).retired()) {
            revert MigrationOrderViolation("NEW_DVP_NOT_LIVE", newDvp);
        }
        if (!_isDependent(eligibilityRegistry, newDvp)) {
            revert MigrationOrderViolation("DEPENDENT_RETIRE_ORDER", eligibilityRegistry);
        }
        if (evidenceHash == bytes32(0)) revert MigrationOrderViolation("EVIDENCE_REQUIRED", oldDvp);
        operation =
            _operation(oldDvp, abi.encodeCall(IDvPSettlement.retire, (ReasonCode.PLANNED_MIGRATION, evidenceHash)));
    }

    function _requirePausedLive(address dvp, bytes32 stage) private view {
        if (!IDvPGovernanceView(dvp).globalPaused() || IDvPGovernanceView(dvp).retired()) {
            revert MigrationOrderViolation(stage, dvp);
        }
    }

    function _isDependent(address registry, address dvp) private view returns (bool) {
        IDependentDvpRegistry target = IDependentDvpRegistry(registry);
        uint256 count = target.getDependentDvpCount();
        for (uint256 i = 0; i < count; ++i) {
            (address candidate,) = target.getDependentDvp(i);
            if (candidate == dvp) return true;
        }
        return false;
    }

    function _verifyConsumerCutover(
        address oldDvp,
        address newDvp,
        address eligibilityRegistry,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        bytes32 newAssetVersionId,
        bytes32 incorrectAssetVersionId
    ) private view {
        if (
            incorrectAssetVersionId == bytes32(0) || incorrectAssetVersionId == newAssetVersionId
                || _contains(oldAssetVersionIds, incorrectAssetVersionId)
        ) {
            revert MigrationOrderViolation("INVALID_NEGATIVE_CONTROL", eligibilityRegistry);
        }
        if (!_isDependent(eligibilityRegistry, newDvp)) {
            revert MigrationOrderViolation("DEPENDENT_CUTOVER", eligibilityRegistry);
        }
        _requireOldAssetVersions(
            oldDvp, assetVersionRegistry, oldAssetVersionIds, AssetVersionStatus.DEPRECATED, "OLD_ASSET_NOT_DEPRECATED"
        );
        AssetVersionRecord memory newRecord =
            IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(newAssetVersionId);
        if (
            !newRecord.exists || newRecord.config.dvpContract != newDvp || newRecord.status != AssetVersionStatus.ACTIVE
        ) {
            revert MigrationOrderViolation("NEW_ASSET_AUTHORIZATION", eligibilityRegistry);
        }
        if (IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(incorrectAssetVersionId).exists) {
            revert MigrationOrderViolation("WRONG_ASSET_AUTHORIZED", eligibilityRegistry);
        }
    }

    function _requireOldAssetVersions(
        address oldDvp,
        address assetVersionRegistry,
        bytes32[] calldata oldAssetVersionIds,
        AssetVersionStatus expectedStatus,
        bytes32 stage
    ) private view {
        if (oldAssetVersionIds.length == 0) {
            revert MigrationOrderViolation("OLD_ASSET_LIST_EMPTY", oldDvp);
        }
        for (uint256 i = 0; i < oldAssetVersionIds.length; ++i) {
            if (oldAssetVersionIds[i] == bytes32(0)) {
                revert MigrationOrderViolation("OLD_ASSET_ID_ZERO", assetVersionRegistry);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (oldAssetVersionIds[j] == oldAssetVersionIds[i]) {
                    revert MigrationOrderViolation("OLD_ASSET_DUPLICATE", assetVersionRegistry);
                }
            }
            AssetVersionRecord memory record =
                IAssetVersionRegistry(assetVersionRegistry).getAssetVersion(oldAssetVersionIds[i]);
            if (!record.exists || record.config.dvpContract != oldDvp || record.status != expectedStatus) {
                revert MigrationOrderViolation(stage, assetVersionRegistry);
            }
        }
    }

    function _contains(bytes32[] calldata values, bytes32 candidate) private pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == candidate) return true;
        }
        return false;
    }

    function _requireExactRegistrySet(address newDvp, address[] calldata supplied) private view {
        IDvPSettlement dvp = IDvPSettlement(newDvp);
        address[8] memory expected = [
            address(dvp.participantRegistry()),
            address(dvp.assetVersionRegistry()),
            address(dvp.eligibilityRegistry()),
            address(dvp.feeRegistry()),
            address(dvp.marketRuleRegistry()),
            address(dvp.settlementTokenRegistry()),
            address(dvp.adapterRegistry()),
            address(dvp.principalCalculatorRegistry())
        ];
        for (uint256 expectedIndex = 0; expectedIndex < expected.length; ++expectedIndex) {
            uint256 matches;
            for (uint256 suppliedIndex = 0; suppliedIndex < supplied.length; ++suppliedIndex) {
                if (supplied[suppliedIndex] == expected[expectedIndex]) ++matches;
            }
            if (matches != 1) {
                revert MigrationOrderViolation("REGISTRY_SET_MISMATCH", expected[expectedIndex]);
            }
        }
    }

    function _operation(address target, bytes memory payload) private pure returns (DirectOperation memory) {
        return DirectOperation({target: target, data: payload});
    }
}
