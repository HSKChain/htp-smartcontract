// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    ReasonCode,
    RoundingMode,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

struct FeeVersionRegisteredData {
    uint256 chainId;
    uint32 schemaVersion;
    uint32 revision;
    ScopeType scopeType;
    bytes32 scopeKeyHash;
    uint16 investorRateBps;
    bool investorHasCap;
    uint256 investorCapAmount;
    uint16 makerRateBps;
    bool makerHasCap;
    uint256 makerCapAmount;
    RoundingMode roundingMode;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    address collector;
    uint64 validFrom;
    uint64 validUntil;
    bytes32 feeConstraintHash;
    bytes32 replacesFeeVersionId;
    bytes32 configHash;
}

struct FeeVersionStatusChangedData {
    uint256 chainId;
    FeeVersionStatus oldStatus;
    FeeVersionStatus newStatus;
    ReasonCode reason;
    bytes32 evidenceHash;
    address actor;
}

contract FeeRegistryEventsTest is FeeRegistryTestBase {
    bytes32 private constant EPOCH_CREATED_TOPIC = 0x7d43dc3c6f3d57c8ffce1061fccada9efed53bdd2532405eea0827729c901898;
    bytes32 private constant EPOCH_SEALED_TOPIC = 0x0daad8c916c273bb2765cceaaafb26c77b79e38cd65cded0d97e8da85c251394;
    bytes32 private constant EPOCH_STATUS_TOPIC = 0xf9d1ca1c9e871ddeaacba2df9f4251811de55de3ab43c351952aaaf3be3bd6f9;
    bytes32 private constant FEE_REGISTERED_TOPIC = 0x41e5bd04365f1b62c24eca3db64a849b5d2cfbcb80ee6b1d2b39dd5fd0dba36c;
    bytes32 private constant FEE_STATUS_TOPIC = 0x153dc82feef2c8ab13b7fa9eacad96bf7d19c84ce29014b2eea80c1bf30c14ee;

    function testEpochAndFeeEventsUseLiteralTopicsAndReplayableFields() public {
        vm.recordLogs();
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertEpochCreated(logs, epoch);

        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        vm.recordLogs();
        _registerFee(config);
        logs = vm.getRecordedLogs();
        _assertFeeRegistered(logs, config);

        vm.recordLogs();
        _sealEpoch(epoch);
        logs = vm.getRecordedLogs();
        _assertEpochSealed(logs, epoch);

        vm.recordLogs();
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        logs = vm.getRecordedLogs();
        _assertFeeActivated(logs, config);

        vm.warp(epoch.quoteValidFrom);
        vm.recordLogs();
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, config.feeVersionId);
        logs = vm.getRecordedLogs();
        _assertEpochActivated(logs);
    }

    function _assertEpochCreated(Vm.Log[] memory logs, FeePolicyEpochConfig memory epoch) private view {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EPOCH_CREATED_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(1)));
        (
            uint256 chainId,
            uint64 quoteValidFrom,
            uint64 quoteValidUntil,
            uint64 settlementValidUntil,
            bytes32 epochHash,
            address epochActor
        ) = abi.decode(logs[0].data, (uint256, uint64, uint64, uint64, bytes32, address));
        assertEq(chainId, block.chainid);
        assertEq(quoteValidFrom, epoch.quoteValidFrom);
        assertEq(quoteValidUntil, epoch.quoteValidUntil);
        assertEq(settlementValidUntil, epoch.settlementValidUntil);
        assertEq(epochHash, epoch.configHash);
        assertEq(epochActor, address(timelock));
    }

    function _assertFeeRegistered(Vm.Log[] memory logs, FeeConfig memory config) private view {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], FEE_REGISTERED_TOPIC);
        assertEq(logs[0].topics[1], config.feeVersionId);
        assertEq(logs[0].topics[2], bytes32(uint256(1)));
        assertEq(logs[0].topics[3], config.matchedScopeHash);
        FeeVersionRegisteredData memory registered = abi.decode(logs[0].data, (FeeVersionRegisteredData));
        assertEq(registered.chainId, block.chainid);
        assertEq(registered.schemaVersion, config.schemaVersion);
        assertEq(registered.revision, config.revision);
        assertEq(uint8(registered.scopeType), uint8(config.scopeType));
        assertEq(registered.scopeKeyHash, config.scopeKeyHash);
        assertEq(registered.investorRateBps, config.investorRateBps);
        assertEq(registered.investorHasCap, config.investorHasCap);
        assertEq(registered.investorCapAmount, config.investorCapAmount);
        assertEq(registered.makerRateBps, config.makerRateBps);
        assertEq(registered.makerHasCap, config.makerHasCap);
        assertEq(registered.makerCapAmount, config.makerCapAmount);
        assertEq(uint8(registered.roundingMode), uint8(config.roundingMode));
        assertEq(registered.settlementToken, config.settlementToken);
        assertEq(registered.settlementTokenConfigId, config.settlementTokenConfigId);
        assertEq(registered.settlementTokenConfigHash, config.settlementTokenConfigHash);
        assertEq(registered.collector, config.collector);
        assertEq(registered.validFrom, config.validFrom);
        assertEq(registered.validUntil, config.validUntil);
        assertEq(registered.feeConstraintHash, config.feeConstraintHash);
        assertEq(registered.replacesFeeVersionId, config.replacesFeeVersionId);
        assertEq(registered.configHash, config.configHash);
    }

    function _assertEpochSealed(Vm.Log[] memory logs, FeePolicyEpochConfig memory epoch) private view {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EPOCH_SEALED_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(1)));
        (uint256 sealedChainId, bytes32 sealedConfigHash, address sealedActor) =
            abi.decode(logs[0].data, (uint256, bytes32, address));
        assertEq(sealedChainId, block.chainid);
        assertEq(sealedConfigHash, epoch.configHash);
        assertEq(sealedActor, address(timelock));
    }

    function _assertFeeActivated(Vm.Log[] memory logs, FeeConfig memory config) private view {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], FEE_STATUS_TOPIC);
        assertEq(logs[0].topics[1], config.feeVersionId);
        assertEq(logs[0].topics[2], bytes32(uint256(1)));
        FeeVersionStatusChangedData memory feeStatus = abi.decode(logs[0].data, (FeeVersionStatusChangedData));
        assertEq(feeStatus.chainId, block.chainid);
        assertEq(uint8(feeStatus.oldStatus), uint8(FeeVersionStatus.REGISTERED));
        assertEq(uint8(feeStatus.newStatus), uint8(FeeVersionStatus.ACTIVE));
        assertEq(uint8(feeStatus.reason), uint8(ReasonCode.NONE));
        assertEq(feeStatus.evidenceHash, bytes32(0));
        assertEq(feeStatus.actor, address(timelock));
    }

    function _assertEpochActivated(Vm.Log[] memory logs) private view {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EPOCH_STATUS_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(1)));
        (
            uint256 statusChainId,
            FeePolicyEpochStatus oldStatus,
            FeePolicyEpochStatus newStatus,
            bytes32 statusEvidence,
            address statusActor
        ) = abi.decode(logs[0].data, (uint256, FeePolicyEpochStatus, FeePolicyEpochStatus, bytes32, address));
        assertEq(statusChainId, block.chainid);
        assertEq(uint8(oldStatus), uint8(FeePolicyEpochStatus.DRAFT));
        assertEq(uint8(newStatus), uint8(FeePolicyEpochStatus.ACTIVE));
        assertEq(statusEvidence, bytes32(0));
        assertEq(statusActor, address(timelock));
    }
}
