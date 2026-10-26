// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetClass, PrincipalCalculatorConfig} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract SlowMistN6HeavyCalculator is IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    function calculate(bytes calldata, uint256, uint8)
        external
        view
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal)
    {
        uint256 gasAtEntry = gasleft();
        while (gasAtEntry - gasleft() < 120_000) {}
        return (bytes32(uint256(1)), 1, 1, 1);
    }
}

/// @notice SlowMist N6: calculator admission uses the same 100k gas budget as settlement.
contract SlowMistN6CalculatorGasBudgetAlignmentTest is DvPPreCheckTestBase {
    function test_N6_RegistryRejectsCalculatorThatOnlyFitsOldTwoHundredKProbe() public {
        SlowMistN6HeavyCalculator heavy = new SlowMistN6HeavyCalculator();
        bytes memory callData = abi.encodeCall(IPrincipalCalculator.calculate, (bytes("probe"), uint256(1), uint8(0)));
        (bool succeededAtTwoHundredK, bytes memory resultAtTwoHundredK) =
            address(heavy).staticcall{gas: 200_000}(callData);
        (bool succeededAtOneHundredK,) = address(heavy).staticcall{gas: 100_000}(callData);
        assertTrue(succeededAtTwoHundredK);
        assertEq(resultAtTwoHundredK.length, 4 * 32);
        assertFalse(succeededAtOneHundredK);

        PrincipalCalculatorConfig memory config = _config(heavy);
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.CalculatorStaticCallFailed.selector, config.calculatorConfigId)
        );
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(config);
        assertFalse(calculatorRegistry.getPrincipalCalculator(config.calculatorConfigId).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function _config(SlowMistN6HeavyCalculator heavy) private view returns (PrincipalCalculatorConfig memory config) {
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 2
            ),
            revision: 2,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(heavy),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(heavy).codehash,
            replacesId: calculatorConfig.calculatorConfigId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
    }
}
