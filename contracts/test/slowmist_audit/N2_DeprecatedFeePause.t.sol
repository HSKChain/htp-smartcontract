// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {FeeVersionStatus, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

/// @notice SlowMist N2: a deprecated fee remains usable for historical quotes but can be emergency-paused.
contract SlowMistN2DeprecatedFeePauseTest is UsdySettlementFixture {
    function test_N2_PauserCanStopDeprecatedFeeSettlement() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _deprecateFee();
        assertTrue(_feeExecutable());

        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA201)));

        assertEq(
            uint8(feeRegistry.getFeeVersion(usdyFeeConfig.feeVersionId).status),
            uint8(FeeVersionStatus.DEPRECATED_PAUSED)
        );
        assertFalse(_feeExecutable());

        vm.expectPartialRevert(HTPErrors.FeeSnapshotMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function test_N2_UnpauseRestoresDeprecatedStateAndHistoricalSettlement() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _deprecateFee();

        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA202)));
        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            usdyFeeConfig.feeVersionId, usdyFeeConfig.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xA203))
        );

        assertEq(
            uint8(feeRegistry.getFeeVersion(usdyFeeConfig.feeVersionId).status), uint8(FeeVersionStatus.DEPRECATED)
        );
        assertTrue(_feeExecutable());

        _settleUsdy(params);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function test_N2_RepeatedTransitionsReportDeprecatedLifecycleTarget() public {
        _deprecateFee();
        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA204)));

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.UnauthorizedStateTransition.selector,
                usdyFeeConfig.feeVersionId,
                uint8(FeeVersionStatus.DEPRECATED_PAUSED),
                uint8(FeeVersionStatus.DEPRECATED_PAUSED)
            )
        );
        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA205)));

        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            usdyFeeConfig.feeVersionId, usdyFeeConfig.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xA206))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.UnauthorizedStateTransition.selector,
                usdyFeeConfig.feeVersionId,
                uint8(FeeVersionStatus.DEPRECATED),
                uint8(FeeVersionStatus.DEPRECATED)
            )
        );
        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            usdyFeeConfig.feeVersionId, usdyFeeConfig.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xA207))
        );
    }

    function _deprecateFee() private {
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(
            usdyFeeConfig.feeVersionId, ReasonCode.PLANNED_MIGRATION, bytes32(uint256(0xA200))
        );
        assertEq(
            uint8(feeRegistry.getFeeVersion(usdyFeeConfig.feeVersionId).status), uint8(FeeVersionStatus.DEPRECATED)
        );
    }

    function _feeExecutable() private view returns (bool) {
        return feeRegistry.isFeeVersionExecutable(
            USDY_FEE_EPOCH,
            usdyAssetVersionConfig.assetVersionId,
            usdyFeeConfig.feeVersionId,
            usdyFeeConfig.matchedScopeHash,
            usdyFeeConfig.feeConstraintHash
        );
    }
}
