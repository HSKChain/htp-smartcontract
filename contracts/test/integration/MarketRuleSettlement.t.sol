// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, FundPriceTerms, MarketRuleConfig, ParticipantType, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract MarketRuleSettlementTest is DvPPreCheckTestBase {
    function testMinimumQuantityAndQuantityStepBlockSettlement() public view {
        SettlementParams memory belowMinimum = _validPreCheckParams();
        belowMinimum.firmQuote.minExecutableQuantity = 0.5 ether;
        belowMinimum.firmQuote.maxExecutableQuantity = 100.5 ether;
        belowMinimum.snapshot.executedQuantity = 10.5 ether;
        belowMinimum.tradeIntent.executedQuantity = 10.5 ether;
        _resign(belowMinimum);
        _assertBlocked(belowMinimum, HTPErrors.MarketRuleQuantityViolation.selector);

        SettlementParams memory wrongStep = _validPreCheckParams();
        wrongStep.firmQuote.stepQuantity = 0.5 ether;
        _resign(wrongStep);
        _assertBlocked(wrongStep, HTPErrors.MarketRuleQuantityViolation.selector);
    }

    function testPriceTickChecksFundQuotedPrice() public view {
        SettlementParams memory params = _validPreCheckParams();
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

        _assertBlocked(params, HTPErrors.MarketRulePriceTickViolation.selector);
    }

    function testMinimumCashPrincipalBlocksSettlement() public {
        MarketRuleConfig memory next = _activateNextRule(12_000_000);
        SettlementParams memory params = _validPreCheckParams();
        _bindSelectedMarketRule(params, next);
        _resign(params);

        _assertBlocked(params, HTPErrors.MarketRuleMinimumPrincipalViolation.selector);
    }

    function testLegacyRuleServesOnlyItsHistoricalQuoteWindow() public {
        _activateNextRule(marketRuleConfig.minCashPrincipal);

        SettlementParams memory historical = _validPreCheckParams();
        (Decision decision, bytes4 reason) = dvp.preCheck(historical);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));

        historical.firmQuote.expiresAt = SETTLEMENT_VALID_UNTIL + 1;
        historical.snapshot.quoteExpiresAt = SETTLEMENT_VALID_UNTIL + 1;
        _resign(historical);
        _assertBlocked(historical, HTPErrors.MarketRuleSnapshotMismatch.selector);
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

    function _assertBlocked(SettlementParams memory params, bytes4 expectedReason) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, expectedReason);
    }
}
