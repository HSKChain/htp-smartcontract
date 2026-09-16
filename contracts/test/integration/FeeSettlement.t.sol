// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetClass,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    ReasonCode,
    RoundingMode,
    ScopeType,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract FeeSettlementTest is UsdySettlementFixture {
    uint64 private constant TEST_EPOCH = 3;
    uint64 private constant TEST_CREATED_AT = USDY_CREATED_AT + 1;

    function testAssetVersionScopeSettles() public {
        _assertScopeSettles(ScopeType.ASSET_VERSION);
    }

    function testInstrumentFallbackSettles() public {
        _assertScopeSettles(ScopeType.INSTRUMENT);
    }

    function testAssetClassFallbackSettles() public {
        _assertScopeSettles(ScopeType.ASSET_CLASS);
    }

    function testChainFallbackSettles() public {
        _assertScopeSettles(ScopeType.CHAIN);
    }

    function testGlobalFallbackSettles() public {
        _assertScopeSettles(ScopeType.GLOBAL);
    }

    function testLegacyEpochDeprecatedFeeSettlesInsideBoundWindow() public {
        SettlementParams memory legacyParams = _validUsdyBuyParams();
        _activateFeeForScope(ScopeType.GLOBAL);
        assertEq(
            uint8(feeRegistry.getFeePolicyEpoch(USDY_FEE_EPOCH).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING)
        );

        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(
            uint8(feeRegistry.getFeeVersion(usdyFeeConfig.feeVersionId).status), uint8(FeeVersionStatus.DEPRECATED)
        );

        _settleUsdy(legacyParams);
        assertTrue(dvp.usedQuoteHash(legacyParams.tradeIntent.quoteHash));
    }

    function testPausedLegacyFeeFailsClosedWithoutLocks() public {
        SettlementParams memory legacyParams = _validUsdyBuyParams();
        _activateFeeForScope(ScopeType.GLOBAL);
        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.expectPartialRevert(HTPErrors.FeeSnapshotMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(legacyParams);
        assertFalse(dvp.usedQuoteHash(legacyParams.tradeIntent.quoteHash));
    }

    function testClosedLegacyEpochIsNotServiceable() public {
        _activateFeeForScope(ScopeType.GLOBAL);
        vm.warp(SETTLEMENT_VALID_UNTIL + 1);
        vm.prank(address(timelock));
        feeRegistry.closeFeePolicyEpoch(USDY_FEE_EPOCH, EVIDENCE_HASH);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(USDY_FEE_EPOCH).status), uint8(FeePolicyEpochStatus.CLOSED));
        vm.expectPartialRevert(HTPErrors.FeePolicyEpochNotServiceable.selector);
        feeRegistry.resolveApplicableFee(USDY_FEE_EPOCH, usdyAssetVersionConfig.assetVersionId);
    }

    function testExpiredSettlementFailsWhileLegacyEpochRemainsServiceable() public {
        SettlementParams memory legacyParams = _validUsdyBuyParams();
        _activateFeeForScope(ScopeType.GLOBAL);
        vm.warp(TRADE_DEADLINE + 1);

        assertEq(
            uint8(feeRegistry.getFeePolicyEpoch(USDY_FEE_EPOCH).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING)
        );
        vm.expectPartialRevert(HTPErrors.InvalidSettlementTimeWindow.selector);
        vm.prank(EXECUTOR);
        dvp.settle(legacyParams);
        assertFalse(dvp.usedSnapshotHash(legacyParams.tradeIntent.snapshotHash));
    }

    function _assertScopeSettles(ScopeType scopeType) private {
        FeeConfig memory selected = _activateFeeForScope(scopeType);
        SettlementParams memory params = _validUsdyBuyParams();
        _bindFee(params, selected);
        params.snapshot.createdAt = TEST_CREATED_AT;
        _resign(params);

        uint256 gasBefore = gasleft();
        _settleUsdy(params);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_fee_scope_settle_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 1_150_000);

        assertTrue(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
        assertEq(params.snapshot.matchedScopeHash, selected.matchedScopeHash);
    }

    function _activateFeeForScope(ScopeType scopeType) private returns (FeeConfig memory config) {
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: TEST_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: TEST_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 scopeKeyHash = FeeScope.key(
            scopeType,
            usdyAssetVersionConfig.assetVersionId,
            usdyAssetVersionConfig.economicAssetIdHash,
            AssetClass.FUND,
            block.chainid
        );
        bytes32 matchedScopeHash = FeeScope.matchedHash(TEST_EPOCH, scopeType, scopeKeyHash);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: TEST_EPOCH,
            scopeType: scopeType,
            scopeKeyHash: scopeKeyHash,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: TEST_CREATED_AT,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(config);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(TEST_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(TEST_CREATED_AT);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(TEST_EPOCH, epoch.configHash);
    }

    function _bindFee(SettlementParams memory params, FeeConfig memory config) private pure {
        params.firmQuote.feePolicyEpoch = config.feePolicyEpoch;
        params.firmQuote.feeVersionId = config.feeVersionId;
        params.firmQuote.matchedScopeHash = config.matchedScopeHash;
        params.firmQuote.feeConstraintHash = config.feeConstraintHash;
        params.tradeIntent.feePolicyEpoch = config.feePolicyEpoch;
        params.tradeIntent.feeVersionId = config.feeVersionId;
        params.tradeIntent.matchedScopeHash = config.matchedScopeHash;
        params.tradeIntent.feeConstraintHash = config.feeConstraintHash;
        params.snapshot.feePolicyEpoch = config.feePolicyEpoch;
        params.snapshot.feeVersionId = config.feeVersionId;
        params.snapshot.matchedScopeHash = config.matchedScopeHash;
        params.snapshot.feeConstraintHash = config.feeConstraintHash;
    }
}
