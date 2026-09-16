// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {AssetClass, PrincipalCalculatorConfig, PrincipalCalculatorRecord, ReasonCode} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract PrincipalCalculatorConfigAbiTest is Test {
    function testPrincipalCalculatorRegistryPublicSelectorsMatchReviewedLiterals() public pure {
        assertEq(IPrincipalCalculatorRegistry.registerPrincipalCalculator.selector, bytes4(0x4f8b338b));
        assertEq(IPrincipalCalculatorRegistry.activatePrincipalCalculator.selector, bytes4(0xd4293471));
        assertEq(IPrincipalCalculatorRegistry.pausePrincipalCalculator.selector, bytes4(0x5af644fb));
        assertEq(IPrincipalCalculatorRegistry.unpausePrincipalCalculator.selector, bytes4(0xe410eacb));
        assertEq(IPrincipalCalculatorRegistry.deprecatePrincipalCalculator.selector, bytes4(0x31aa8f62));
        assertEq(IPrincipalCalculatorRegistry.getPrincipalCalculator.selector, bytes4(0xa30114ff));
        assertEq(IPrincipalCalculatorRegistry.getCurrentPrincipalCalculator.selector, bytes4(0x4be56610));
        assertEq(IPrincipalCalculatorRegistry.isPrincipalCalculatorConfigActive.selector, bytes4(0xd75ce14a));
        assertEq(IPrincipalCalculatorRegistry.registerDependentDvp.selector, bytes4(0x03f8d147));
        assertEq(IPrincipalCalculatorRegistry.exemptRetiredDependentDvp.selector, bytes4(0xd74df627));
        assertEq(IPrincipalCalculatorRegistry.getDependentDvpCount.selector, bytes4(0xbafdbeba));
        assertEq(IPrincipalCalculatorRegistry.getDependentDvp.selector, bytes4(0x9816d4b9));
        assertEq(IPrincipalCalculatorRegistry.upgradeToAndCall.selector, bytes4(0x4f1ef286));

        bytes memory callData = abi.encodeCall(
            IPrincipalCalculatorRegistry.unpausePrincipalCalculator,
            (bytes32(uint256(1)), bytes32(uint256(2)), ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(3)))
        );
        assertEq(abiSelector(callData), bytes4(0xe410eacb));
    }

    function testPrincipalCalculatorConfigUsesAssetClassSubject() public pure {
        PrincipalCalculatorConfig memory config;
        config.schemaVersion = 1;
        config.assetClass = AssetClass.FUND;
        config.calculator = address(0xCA1C);
        config.revision = 4;
        assertEq(abi.encode(config).length, 10 * 32);
        bytes memory callData = abi.encodeCall(IPrincipalCalculatorRegistry.registerPrincipalCalculator, (config));
        assertEq(abiSelector(callData), IPrincipalCalculatorRegistry.registerPrincipalCalculator.selector);
        assertEq(callData.length, 4 + 10 * 32);
        assertEq(uint8(config.assetClass), uint8(AssetClass.FUND));
        assertEq(config.revision, 4);
    }

    function testPrincipalCalculatorRecordOwnsStatusAndExistence() public pure {
        PrincipalCalculatorRecord memory record;
        record.exists = true;
        assertEq(abi.encode(record).length, 12 * 32);
    }
}
