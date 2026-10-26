// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {FeeConfig, FeePolicyEpochConfig, FeePolicyEpochStatus, ReasonCode, ScopeType} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

/// @notice SlowMist N1: an epoch cannot become ACTIVE without an ACTIVE serving fee.
contract SlowMistN1FeePolicyEpochReadinessTest is FeeRegistryTestBase {
    function test_N1_RegisteredFeeDoesNotMakeEpochReady() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory fee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);

        vm.warp(epoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), fee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, fee.feeVersionId);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.DRAFT));
    }

    function test_N1_FailedActivationDoesNotDemoteCurrentEpoch() public {
        _publishGlobalFeeEpoch(1);
        FeePolicyEpochConfig memory secondEpoch = _createEpoch(2);
        FeeConfig memory registeredOnly = _feeConfig(2, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(registeredOnly);
        _sealEpoch(secondEpoch);

        vm.warp(secondEpoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(2), registeredOnly.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(2, secondEpoch.configHash, registeredOnly.feeVersionId);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.ACTIVE));
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(2).status), uint8(FeePolicyEpochStatus.DRAFT));
    }

    function test_N1_PausedOrDeprecatedServingFeeDoesNotMakeEpochReady() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory globalFee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        FeeConfig memory chainFee = _feeConfig(1, ScopeType.CHAIN, bytes32(block.chainid), 1, bytes32(0));
        _registerFee(globalFee);
        _registerFee(chainFee);
        _sealEpoch(epoch);
        _activateFee(globalFee);
        _activateFee(chainFee);

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(globalFee.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA001)));
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(chainFee.feeVersionId, ReasonCode.PLANNED_MIGRATION, bytes32(uint256(0xA002)));

        vm.warp(epoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), globalFee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, globalFee.feeVersionId);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), chainFee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, chainFee.feeVersionId);
    }

    function test_N1_CurrentServingRevisionIsReady() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory first = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        FeeConfig memory second = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 2, first.feeVersionId);
        _registerFee(first);
        _registerFee(second);
        _sealEpoch(epoch);
        _activateFee(first);
        _activateFee(second);

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(first.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA003)));
        _activateEpoch(epoch, second.feeVersionId);
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.ACTIVE));
    }

    function test_N1_PausedCurrentRevisionCannotRelyOnOverwrittenActiveRevision() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory first = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        FeeConfig memory second = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 2, first.feeVersionId);
        _registerFee(first);
        _registerFee(second);
        _sealEpoch(epoch);
        _activateFee(first);
        _activateFee(second);

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(second.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA004)));

        vm.warp(epoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), second.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, second.feeVersionId);
    }

    function test_N1_SettlementTokenPausedAfterFeeActivationKeepsEpochDraft() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory fee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);
        _activateFee(fee);

        vm.prank(PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            settlementTokenConfig.configId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA005))
        );

        vm.warp(epoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), fee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, fee.feeVersionId);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.DRAFT));
    }

    function test_N1_ExpiredServingFeeKeepsEpochDraft() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory fee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        fee.validUntil = epoch.quoteValidFrom + 1 hours;
        fee.feeConstraintHash = HTPHashing.hashFeeConstraint(fee);
        fee.configHash = HTPHashing.hashFeeConfig(fee);
        _registerFee(fee);
        _sealEpoch(epoch);
        _activateFee(fee);

        vm.warp(fee.validUntil + 1);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), fee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, fee.feeVersionId);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.DRAFT));
    }

    function _publishGlobalFeeEpoch(uint64 epochNumber) private returns (FeePolicyEpochConfig memory epoch) {
        epoch = _createEpoch(epochNumber);
        FeeConfig memory fee = _feeConfig(epochNumber, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);
        _activateFee(fee);
        _activateEpoch(epoch, fee.feeVersionId);
    }

    function _activateFee(FeeConfig memory fee) private {
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(fee.feeVersionId, fee.configHash);
    }
}
