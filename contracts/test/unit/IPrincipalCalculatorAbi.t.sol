// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {AssetClass, BondPriceTerms, FundPriceTerms, StockPriceTerms} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract PrincipalCalculatorAbiHarness is IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return bytes32(uint256(0x1234));
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    function calculate(bytes calldata, uint256, uint8)
        external
        pure
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal)
    {
        return (bytes32(uint256(0xCAFE)), 1_140_000, 1_140_000, 114_000_000);
    }
}

contract IPrincipalCalculatorAbiTest is Test {
    IPrincipalCalculator private immutable CALCULATOR = new PrincipalCalculatorAbiHarness();

    function testSelectorsMatchReviewedLiterals() public pure {
        assertEq(IPrincipalCalculator.interfaceVersion.selector, bytes4(0x1d8ffa4d));
        assertEq(IPrincipalCalculator.assetClass.selector, bytes4(0x86c9de05));
        assertEq(IPrincipalCalculator.calculate.selector, bytes4(0x50a466c1));

        bytes memory callData = abi.encodeCall(IPrincipalCalculator.calculate, (hex"", 100 ether, 18));
        assertEq(abiSelector(callData), bytes4(0x50a466c1));
    }

    function testCalculateReturnEncodingIsExactlyFourWords() public view {
        (bool success, bytes memory returnData) =
            address(CALCULATOR).staticcall(abi.encodeCall(IPrincipalCalculator.calculate, (hex"", 100 ether, 18)));

        assertTrue(success);
        assertEq(returnData.length, 128);
        (bytes32 priceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) =
            abi.decode(returnData, (bytes32, uint256, uint256, uint256));
        assertEq(priceTermsHash, bytes32(uint256(0xCAFE)));
        assertEq(quotedPrice, 1_140_000);
        assertEq(unitCashPrice, 1_140_000);
        assertEq(cashPrincipal, 114_000_000);
    }
}

contract PrincipalCalculatorImplementationsAbiTest is Test {
    IPrincipalCalculator private immutable FUND = IPrincipalCalculator(address(new FundPrincipalCalculator()));
    IPrincipalCalculator private immutable STOCK = IPrincipalCalculator(address(new StockPrincipalCalculator()));
    IPrincipalCalculator private immutable BOND = IPrincipalCalculator(address(new BondPrincipalCalculator()));

    function testImplementationsShareVersionedInterfaceAndFixedAssetClasses() public view {
        assertEq(FUND.interfaceVersion(), InterfaceVersions.PRINCIPAL_CALCULATOR_V1);
        assertEq(STOCK.interfaceVersion(), InterfaceVersions.PRINCIPAL_CALCULATOR_V1);
        assertEq(BOND.interfaceVersion(), InterfaceVersions.PRINCIPAL_CALCULATOR_V1);
        assertEq(uint8(FUND.assetClass()), uint8(AssetClass.FUND));
        assertEq(uint8(STOCK.assetClass()), uint8(AssetClass.STOCK));
        assertEq(uint8(BOND.assetClass()), uint8(AssetClass.BOND));
    }

    function testProductionCalculateReturnsExactly128BytesWithinFrozenGasLimit() public {
        uint256 maximumGasUsed = _assertThreeWordReturn(
            FUND,
            abi.encode(
                FundPriceTerms({navPerUnit: 1_140_000, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))})
            ),
            100 ether,
            18
        );
        uint256 stockGasUsed = _assertThreeWordReturn(
            STOCK,
            abi.encode(
                StockPriceTerms({
                    unitPrice: 2_345_678,
                    priceAsOf: 1_780_000_000,
                    referenceMarketHash: bytes32(uint256(0x701)),
                    priceSourceHash: bytes32(uint256(0x702))
                })
            ),
            25_000_000,
            6
        );
        if (stockGasUsed > maximumGasUsed) maximumGasUsed = stockGasUsed;
        uint256 bondGasUsed = _assertThreeWordReturn(
            BOND,
            abi.encode(
                BondPriceTerms({
                    cleanPricePerUnit: 980_000,
                    accruedInterestPerUnit: 12_500,
                    settlementDate: 20_260_812,
                    sourceHash: bytes32(uint256(0x703))
                })
            ),
            300_000_000,
            8
        );
        if (bondGasUsed > maximumGasUsed) maximumGasUsed = bondGasUsed;

        emit log_named_uint("phase19_max_calculator_staticcall_gas", maximumGasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(maximumGasUsed, 100_000);
    }

    function testImplementationsExposeNoUpgradeEntryPoint() public {
        bytes memory upgradeCall = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xBEEF), hex"");
        _assertCallRejected(FUND, upgradeCall);
        _assertCallRejected(STOCK, upgradeCall);
        _assertCallRejected(BOND, upgradeCall);
    }

    function _assertThreeWordReturn(
        IPrincipalCalculator calculator,
        bytes memory priceData,
        uint256 executedQuantity,
        uint8 assetDecimals
    ) private view returns (uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        (bool success, bytes memory returnData) = address(calculator)
            .staticcall(abi.encodeCall(IPrincipalCalculator.calculate, (priceData, executedQuantity, assetDecimals)));
        gasUsed = gasBefore - gasleft();
        assertTrue(success);
        assertEq(returnData.length, 128);
    }

    function _assertCallRejected(IPrincipalCalculator calculator, bytes memory callData) private {
        (bool success,) = address(calculator).call(callData);
        assertFalse(success);
    }
}
