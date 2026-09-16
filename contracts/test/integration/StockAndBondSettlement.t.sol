// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetClass,
    BondPriceTerms,
    Decision,
    RestrictionMode,
    SettlementParams,
    StockPriceTerms,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {IntegrationERC20Token} from "test/fixtures/IntegrationTokens.sol";
import {CrossAssetSettlementFixture} from "test/helpers/CrossAssetSettlementFixture.sol";

contract StockAndBondSettlementTest is CrossAssetSettlementFixture {
    function testStockSettlementUsesSignedUnitPrice() public {
        IntegrationERC20Token stockToken = new IntegrationERC20Token(18);
        StockPriceTerms memory terms = StockPriceTerms({
            unitPrice: 1_140_000,
            priceAsOf: USDY_CREATED_AT,
            referenceMarketHash: bytes32(uint256(0x5101)),
            priceSourceHash: bytes32(uint256(0x5102))
        });
        SettlementParams memory params = _activateAndBuildAssetSettlement(
            AssetClass.STOCK,
            stockCalculator,
            stockToken,
            adapterConfig,
            TokenStandard.ERC20,
            RestrictionMode.UNRESTRICTED,
            abi.encode(terms),
            HTPHashing.hashStockPriceTerms(terms),
            3
        );

        _settleUsdy(params);

        assertEq(stockToken.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(stockToken.balanceOf(params.snapshot.buyer), 10 ether);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), 11_382_900);
        assertTrue(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
    }

    function testBondSettlementUsesCleanPricePlusAccruedInterest() public {
        IntegrationERC20Token bondToken = new IntegrationERC20Token(18);
        BondPriceTerms memory terms = BondPriceTerms({
            cleanPricePerUnit: 1_000_000,
            accruedInterestPerUnit: 140_000,
            settlementDate: 20_260_812,
            sourceHash: bytes32(uint256(0xB010))
        });
        SettlementParams memory params = _activateAndBuildAssetSettlement(
            AssetClass.BOND,
            bondCalculator,
            bondToken,
            adapterConfig,
            TokenStandard.ERC20,
            RestrictionMode.UNRESTRICTED,
            abi.encode(terms),
            HTPHashing.hashBondPriceTerms(terms),
            3
        );

        _settleUsdy(params);

        assertEq(bondToken.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(bondToken.balanceOf(params.snapshot.buyer), 10 ether);
        assertEq(params.snapshot.cashPrincipal, 11_400_000);
        assertTrue(dvp.usedQuoteHash(params.snapshot.quoteHash));
    }

    function testStockTickChecksUnitPrice() public {
        IntegrationERC20Token stockToken = new IntegrationERC20Token(18);
        StockPriceTerms memory terms = StockPriceTerms({
            unitPrice: 1_140_001,
            priceAsOf: USDY_CREATED_AT,
            referenceMarketHash: bytes32(uint256(0x5201)),
            priceSourceHash: bytes32(uint256(0x5202))
        });
        SettlementParams memory params = _activateAndBuildAssetSettlement(
            AssetClass.STOCK,
            stockCalculator,
            stockToken,
            adapterConfig,
            TokenStandard.ERC20,
            RestrictionMode.UNRESTRICTED,
            abi.encode(terms),
            HTPHashing.hashStockPriceTerms(terms),
            3
        );
        (,,, uint256 principal) =
            stockCalculator.calculate(params.snapshot.priceData, params.snapshot.executedQuantity, 18);
        params.snapshot.cashPrincipal = principal;
        params.tradeIntent.cashPrincipal = principal;
        _applyIdentityFeeAmounts(params, integrationFeeConfig);
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.MarketRulePriceTickViolation.selector);
    }

    function testBondTickChecksCleanPriceRatherThanFullPrice() public {
        IntegrationERC20Token bondToken = new IntegrationERC20Token(18);
        BondPriceTerms memory terms = BondPriceTerms({
            cleanPricePerUnit: 1_000_001,
            accruedInterestPerUnit: 139_999,
            settlementDate: 20_260_812,
            sourceHash: bytes32(uint256(0xB011))
        });
        SettlementParams memory params = _activateAndBuildAssetSettlement(
            AssetClass.BOND,
            bondCalculator,
            bondToken,
            adapterConfig,
            TokenStandard.ERC20,
            RestrictionMode.UNRESTRICTED,
            abi.encode(terms),
            HTPHashing.hashBondPriceTerms(terms),
            3
        );

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.MarketRulePriceTickViolation.selector);
        assertEq(params.snapshot.cashPrincipal, 11_400_000);
    }
}
