// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetClass, BondPriceTerms} from "src/types/HTPTypes.sol";

contract BondPrincipalCalculatorTest is Test {
    BondPrincipalCalculator private immutable CALCULATOR = new BondPrincipalCalculator();

    function testCalculatesReviewedBondLiteral() public view {
        bytes memory priceData = abi.encode(
            BondPriceTerms({
                cleanPricePerUnit: 980_000,
                accruedInterestPerUnit: 12_500,
                settlementDate: 20_260_812,
                sourceHash: bytes32(uint256(0x703))
            })
        );

        (bytes32 priceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) =
            CALCULATOR.calculate(priceData, 300_000_000, 8);
        assertEq(quotedPrice, 980_000);

        assertEq(priceTermsHash, 0xd0ef1df61af5833f5bf30eab0e447a60118f6b8525cf0c63954a1ad5cd2182cb);
        assertEq(unitCashPrice, 992_500);
        assertEq(cashPrincipal, 2_977_500);
    }

    function testRequiresCanonicalBondDataAndPositiveCleanPrice() public {
        bytes memory valid = _bondPriceData(980_000, 0, 20_260_812, bytes32(uint256(0x703)));
        (bytes32 priceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) =
            CALCULATOR.calculate(valid, 300_000_000, 8);
        assertEq(quotedPrice, 980_000);
        assertEq(priceTermsHash, 0xf95e0d077c63d5a1aa6f48aa99ef77704fc2b393fcf67c408de25b7d23348a7a);
        assertEq(unitCashPrice, 980_000);
        assertEq(cashPrincipal, 2_940_000);

        _expectMalformed(hex"");
        _expectMalformed(new bytes(127));
        _expectMalformed(bytes.concat(valid, hex"00"));
        _expectMalformed(abi.encode(uint256(980_000), uint256(0), type(uint256).max, bytes32(uint256(0x703))));
        _expectMalformed(_bondPriceData(0, 12_500, 20_260_812, bytes32(uint256(0x703))));
    }

    function testRejectsFullPriceOverflowInvalidDateAndMissingSource() public {
        assertEq(HTPErrors.BondFullPriceOverflow.selector, bytes4(0x6fa55cf5));
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x6fa55cf5), type(uint256).max, uint256(1)));
        CALCULATOR.calculate(_bondPriceData(type(uint256).max, 1, 20_260_812, bytes32(uint256(0x703))), 1, 0);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidCalendarDate.selector, uint32(19_000_229)));
        CALCULATOR.calculate(_bondPriceData(980_000, 0, 19_000_229, bytes32(uint256(0x703))), 1, 0);

        _expectMalformed(_bondPriceData(980_000, 0, 20_260_812, bytes32(0)));
    }

    function _expectMalformed(bytes memory priceData) private {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.PriceDataMalformed.selector, AssetClass.BOND));
        CALCULATOR.calculate(priceData, 300_000_000, 8);
    }

    function _bondPriceData(
        uint256 cleanPricePerUnit,
        uint256 accruedInterestPerUnit,
        uint32 settlementDate,
        bytes32 sourceHash
    ) private pure returns (bytes memory) {
        return abi.encode(
            BondPriceTerms({
                cleanPricePerUnit: cleanPricePerUnit,
                accruedInterestPerUnit: accruedInterestPerUnit,
                settlementDate: settlementDate,
                sourceHash: sourceHash
            })
        );
    }
}
