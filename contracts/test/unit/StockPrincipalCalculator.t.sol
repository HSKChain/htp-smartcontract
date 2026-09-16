// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetClass, StockPriceTerms} from "src/types/HTPTypes.sol";

contract StockPrincipalCalculatorTest is Test {
    StockPrincipalCalculator private immutable CALCULATOR = new StockPrincipalCalculator();

    function testCalculatesReviewedStockLiteral() public view {
        bytes memory priceData = abi.encode(
            StockPriceTerms({
                unitPrice: 2_345_678,
                priceAsOf: 1_780_000_000,
                referenceMarketHash: bytes32(uint256(0x701)),
                priceSourceHash: bytes32(uint256(0x702))
            })
        );

        (bytes32 priceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) =
            CALCULATOR.calculate(priceData, 25_000_000, 6);
        assertEq(quotedPrice, 2_345_678);

        assertEq(priceTermsHash, 0x5cb821f6c2dccfaae82edcd379059433b9985de79ccbd1dc5da0e21bbd2a767d);
        assertEq(unitCashPrice, 2_345_678);
        assertEq(cashPrincipal, 58_641_950);
    }

    function testRejectsMalformedStockDataAndMissingFields() public {
        bytes memory valid = _stockPriceData(2_345_678, 1_780_000_000, bytes32(uint256(0x701)), bytes32(uint256(0x702)));
        _expectMalformed(hex"");
        _expectMalformed(new bytes(127));
        _expectMalformed(bytes.concat(valid, hex"00"));
        _expectMalformed(
            abi.encode(uint256(2_345_678), type(uint256).max, bytes32(uint256(0x701)), bytes32(uint256(0x702)))
        );
        _expectMalformed(_stockPriceData(0, 1_780_000_000, bytes32(uint256(0x701)), bytes32(uint256(0x702))));
        _expectMalformed(_stockPriceData(2_345_678, 0, bytes32(uint256(0x701)), bytes32(uint256(0x702))));
        _expectMalformed(_stockPriceData(2_345_678, 1_780_000_000, bytes32(0), bytes32(uint256(0x702))));
        _expectMalformed(_stockPriceData(2_345_678, 1_780_000_000, bytes32(uint256(0x701)), bytes32(0)));
    }

    function testDoesNotApplyMarketFreshnessOrBlockTimeRules() public {
        bytes memory priceData = _stockPriceData(2_345_678, 1, bytes32(uint256(0x701)), bytes32(uint256(0x702)));

        vm.warp(1);
        (bytes32 hashAtFirstBlock,,, uint256 principalAtFirstBlock) = CALCULATOR.calculate(priceData, 25_000_000, 6);
        vm.warp(type(uint64).max);
        (bytes32 hashAtLaterBlock,,, uint256 principalAtLaterBlock) = CALCULATOR.calculate(priceData, 25_000_000, 6);

        assertEq(hashAtFirstBlock, hashAtLaterBlock);
        assertEq(principalAtFirstBlock, principalAtLaterBlock);
    }

    function _expectMalformed(bytes memory priceData) private {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.PriceDataMalformed.selector, AssetClass.STOCK));
        CALCULATOR.calculate(priceData, 25_000_000, 6);
    }

    function _stockPriceData(uint256 unitPrice, uint64 priceAsOf, bytes32 referenceMarketHash, bytes32 priceSourceHash)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            StockPriceTerms({
                unitPrice: unitPrice,
                priceAsOf: priceAsOf,
                referenceMarketHash: referenceMarketHash,
                priceSourceHash: priceSourceHash
            })
        );
    }
}
