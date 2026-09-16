// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AssetClass, TokenDeploymentKind, TokenStandard} from "src/types/HTPTypes.sol";

contract EnumValuesTest is Test {
    function testAssetClassValues() public pure {
        assertEq(uint8(AssetClass.NONE), 0);
        assertEq(uint8(AssetClass.STOCK), 1);
        assertEq(uint8(AssetClass.FUND), 2);
        assertEq(uint8(AssetClass.BOND), 3);
    }

    function testTokenStandardValues() public pure {
        assertEq(uint8(TokenStandard.NONE), 0);
        assertEq(uint8(TokenStandard.ERC20), 1);
        assertEq(uint8(TokenStandard.ERC1404), 2);
    }

    function testTokenDeploymentKindValues() public pure {
        assertEq(uint8(TokenDeploymentKind.NONE), 0);
        assertEq(uint8(TokenDeploymentKind.DIRECT), 1);
        assertEq(uint8(TokenDeploymentKind.ERC1967_PROXY), 2);
    }
}
