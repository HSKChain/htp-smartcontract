// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {BondPriceTerms, FundPriceTerms, StockPriceTerms} from "src/types/HTPTypes.sol";

contract PriceTermsHashHarness {
    function stock(StockPriceTerms calldata terms) external pure returns (bytes32) {
        return HTPHashing.hashStockPriceTerms(terms);
    }

    function fund(FundPriceTerms calldata terms) external pure returns (bytes32) {
        return HTPHashing.hashFundPriceTerms(terms);
    }

    function bond(BondPriceTerms calldata terms) external pure returns (bytes32) {
        return HTPHashing.hashBondPriceTerms(terms);
    }
}

contract PriceTermsHashTest is Test {
    PriceTermsHashHarness private immutable HARNESS = new PriceTermsHashHarness();

    function testStockPriceTermsHashMatchesBootstrapLiteral() public view {
        StockPriceTerms memory terms = StockPriceTerms({
            unitPrice: 2_345_678,
            priceAsOf: 1_780_000_000,
            referenceMarketHash: bytes32(uint256(0x701)),
            priceSourceHash: bytes32(uint256(0x702))
        });
        assertEq(HARNESS.stock(terms), 0x5cb821f6c2dccfaae82edcd379059433b9985de79ccbd1dc5da0e21bbd2a767d);
    }

    function testFundPriceTermsHashMatchesBootstrapLiteral() public view {
        FundPriceTerms memory terms =
            FundPriceTerms({navPerUnit: 1_140_000, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))});
        assertEq(HARNESS.fund(terms), 0x43dd8313df1b71f18f367e8a41d0af124cb97d0297aae168e2d9a0132a7dd439);
    }

    function testBondPriceTermsHashMatchesBootstrapLiteral() public view {
        BondPriceTerms memory terms = BondPriceTerms({
            cleanPricePerUnit: 980_000,
            accruedInterestPerUnit: 12_500,
            settlementDate: 20_260_812,
            sourceHash: bytes32(uint256(0x703))
        });
        assertEq(HARNESS.bond(terms), 0xd0ef1df61af5833f5bf30eab0e447a60118f6b8525cf0c63954a1ad5cd2182cb);
    }
}
