// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {AssetClass, PrincipalCalculatorConfig} from "src/types/HTPTypes.sol";

contract PrincipalCalculatorConfigHashHarness {
    function hash(PrincipalCalculatorConfig calldata config) external pure returns (bytes32) {
        return HTPHashing.hashPrincipalCalculatorConfig(config);
    }
}

contract PrincipalCalculatorConfigHashTest is Test {
    PrincipalCalculatorConfigHashHarness private immutable HARNESS = new PrincipalCalculatorConfigHashHarness();

    function testConfigHashMatchesBootstrapAndExcludesSelf() public view {
        PrincipalCalculatorConfig memory config = SchemaFixtures.principalConfig();
        assertEq(HARNESS.hash(config), 0x0d48648641518cff54ae8fd6b8041502587b3102d9fa56c96e63e4ba121d49aa);
        config.configHash = bytes32(uint256(1));
        assertEq(HARNESS.hash(config), 0x0d48648641518cff54ae8fd6b8041502587b3102d9fa56c96e63e4ba121d49aa);
    }

    function testAssetClassIsSubjectWhileCalculatorRemainsCommitted() public view {
        PrincipalCalculatorConfig memory config = SchemaFixtures.principalConfig();
        config.assetClass = AssetClass.BOND;
        assertEq(HARNESS.hash(config), 0xe2a3064cb44b4ce3a2b8314f789e03c9a2ed9e974f507f3c276b163f6b0214e5);
        config = SchemaFixtures.principalConfig();
        config.calculator = address(0xf002);
        assertEq(HARNESS.hash(config), 0x26fe8408fe5bd013b33c53efa947e98de2d311d8de72cd477735fe67dcd53e09);
    }
}
