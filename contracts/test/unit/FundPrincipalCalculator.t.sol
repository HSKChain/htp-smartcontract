// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetClass, FundPriceTerms} from "src/types/HTPTypes.sol";

contract FundPrincipalCalculatorTest is Test {
    FundPrincipalCalculator private immutable CALCULATOR = new FundPrincipalCalculator();

    function testCalculatesReviewedUsd100Literal() public view {
        bytes memory priceData = abi.encode(
            FundPriceTerms({navPerUnit: 1_140_000, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))})
        );

        (bytes32 priceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) =
            CALCULATOR.calculate(priceData, 100 ether, 18);
        assertEq(quotedPrice, 1_140_000);

        assertEq(priceTermsHash, 0x43dd8313df1b71f18f367e8a41d0af124cb97d0297aae168e2d9a0132a7dd439);
        assertEq(unitCashPrice, 1_140_000);
        assertEq(cashPrincipal, 114_000_000);
    }

    function testRejectsMalformedFundPriceData() public {
        bytes memory valid = abi.encode(
            FundPriceTerms({navPerUnit: 1_140_000, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))})
        );

        _expectMalformed(hex"");
        _expectMalformed(new bytes(95));
        _expectMalformed(bytes.concat(valid, hex"00"));
        _expectMalformed(abi.encode(uint256(1_140_000), type(uint256).max, bytes32(uint256(0x201))));
    }

    function testMalformedErrorSelectorMatchesReviewedLiteral() public pure {
        assertEq(HTPErrors.PriceDataMalformed.selector, bytes4(0xab1fb6d2));
    }

    function testRejectsMissingFundFieldsAndInvalidGregorianDate() public {
        _expectMalformed(
            abi.encode(FundPriceTerms({navPerUnit: 0, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))}))
        );
        _expectMalformed(
            abi.encode(FundPriceTerms({navPerUnit: 1_140_000, navDate: 20_260_810, navSourceHash: bytes32(0)}))
        );

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidCalendarDate.selector, uint32(19_000_229)));
        CALCULATOR.calculate(
            abi.encode(
                FundPriceTerms({navPerUnit: 1_140_000, navDate: 19_000_229, navSourceHash: bytes32(uint256(0x201))})
            ),
            100 ether,
            18
        );
    }

    function testUsesFullPrecisionMulDivAndRoundsDown() public view {
        (,, uint256 unitAtZeroDecimals, uint256 principalAtZeroDecimals) = CALCULATOR.calculate(_fundPriceData(3), 5, 0);
        assertEq(unitAtZeroDecimals, 3);
        assertEq(principalAtZeroDecimals, 15);

        (,,, uint256 roundedPrincipal) = CALCULATOR.calculate(_fundPriceData(3), 5, 1);
        assertEq(roundedPrincipal, 1);

        (,,, uint256 fullPrecisionPrincipal) = CALCULATOR.calculate(_fundPriceData(10 ** 36), type(uint256).max, 36);
        assertEq(fullPrecisionPrincipal, type(uint256).max);
    }

    function testRejectsZeroPrincipalAndAssetDecimalsAbove36() public {
        assertEq(HTPErrors.CashPrincipalZero.selector, bytes4(0x643dbbf1));
        vm.expectRevert(bytes4(0x643dbbf1));
        CALCULATOR.calculate(_fundPriceData(1), 1, 1);

        assertEq(HTPErrors.AssetDecimalsOutOfRange.selector, bytes4(0xf53c1b2b));
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xf53c1b2b), uint8(37)));
        CALCULATOR.calculate(_fundPriceData(1), 1, 37);
    }

    function _expectMalformed(bytes memory priceData) private {
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xab1fb6d2), AssetClass.FUND));
        CALCULATOR.calculate(priceData, 100 ether, 18);
    }

    function _fundPriceData(uint256 navPerUnit) private pure returns (bytes memory) {
        return abi.encode(
            FundPriceTerms({navPerUnit: navPerUnit, navDate: 20_000_229, navSourceHash: bytes32(uint256(0x204))})
        );
    }
}
