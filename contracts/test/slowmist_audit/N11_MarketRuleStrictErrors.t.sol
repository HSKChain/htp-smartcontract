// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    Decision,
    FundPriceTerms,
    MarketRuleConfig,
    NonceStatus,
    NonceType,
    ParticipantType,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

/// @notice SlowMist N11: strict settlement preserves deterministic market-rule errors.
contract SlowMistN11MarketRuleStrictErrorsTest is DvPPreCheckTestBase {
    function test_N11_SettleReportsPriceTickViolation() public {
        SettlementParams memory params = _priceTickViolation();
        _assertPreCheckReason(params, HTPErrors.MarketRulePriceTickViolation.selector);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.MarketRulePriceTickViolation.selector,
                params.snapshot.marketRuleConfigId,
                uint256(1_140_001),
                marketRuleConfig.priceTick
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSettlementStateUntouched(params);
    }

    function test_N11_SettleReportsMinimumPrincipalViolation() public {
        MarketRuleConfig memory next = _activateNextRule(12_000_000);
        SettlementParams memory params = _validPreCheckParams();
        _bindSelectedMarketRule(params, next);
        _resign(params);
        _assertPreCheckReason(params, HTPErrors.MarketRuleMinimumPrincipalViolation.selector);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.MarketRuleMinimumPrincipalViolation.selector,
                next.marketRuleConfigId,
                params.snapshot.cashPrincipal,
                next.minCashPrincipal
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertSettlementStateUntouched(params);
    }

    function _priceTickViolation() private view returns (SettlementParams memory params) {
        params = _validPreCheckParams();
        FundPriceTerms memory terms =
            FundPriceTerms({navPerUnit: 1_140_001, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))});
        bytes memory priceData = abi.encode(terms);
        bytes32 priceTermsHash = HTPHashing.hashFundPriceTerms(terms);

        params.firmQuote.priceData = priceData;
        params.snapshot.priceData = priceData;
        params.tradeIntent.priceData = priceData;
        params.firmQuote.priceTermsHash = priceTermsHash;
        params.snapshot.priceTermsHash = priceTermsHash;
        params.tradeIntent.priceTermsHash = priceTermsHash;
        params.snapshot.cashPrincipal = 11_400_010;
        params.tradeIntent.cashPrincipal = 11_400_010;
        _applyFeeAmounts(params, ParticipantType.INVESTOR, ParticipantType.MAKER, feeConfig);
        _resign(params);
    }

    function _activateNextRule(uint256 minCashPrincipal) private returns (MarketRuleConfig memory next) {
        next = marketRuleConfig;
        next.revision = marketRuleConfig.revision + 1;
        next.replacesConfigId = marketRuleConfig.marketRuleConfigId;
        next.marketRuleConfigId = ConfigId.derive(
            ConfigId.MARKET_RULE_NAMESPACE, next.schemaVersion, block.chainid, next.assetVersionId, next.revision
        );
        next.minCashPrincipal = minCashPrincipal;
        next.configHash = bytes32(0);
        next.configHash = HTPHashing.hashMarketRuleConfig(next);

        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(next);
        vm.startPrank(address(timelock));
        marketRuleRegistry.sealMarketRule(next.marketRuleConfigId, next.configHash);
        marketRuleRegistry.activateMarketRule(next.marketRuleConfigId, next.configHash);
        vm.stopPrank();
    }

    function _bindSelectedMarketRule(SettlementParams memory params, MarketRuleConfig memory rule) private pure {
        params.firmQuote.marketRuleConfigId = rule.marketRuleConfigId;
        params.firmQuote.marketRuleConfigHash = rule.configHash;
        params.snapshot.marketRuleConfigId = rule.marketRuleConfigId;
        params.snapshot.marketRuleConfigHash = rule.configHash;
        params.tradeIntent.marketRuleConfigId = rule.marketRuleConfigId;
        params.tradeIntent.marketRuleConfigHash = rule.configHash;
    }

    function _assertPreCheckReason(SettlementParams memory params, bytes4 expectedReason) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, expectedReason);
    }

    function _assertSettlementStateUntouched(SettlementParams memory params) private view {
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.UNUSED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.UNUSED)
        );
    }
}
