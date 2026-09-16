// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";

contract InterfaceVersionTest is Test {
    function testInterfaceVersionsMatchReviewedLiterals() public pure {
        assertEq(InterfaceVersions.ASSET_ADAPTER_V1, 0xcf9367d3ea4eeeafb16085ddb317f5531635ff94317ed7bf61d9dbb13cc3b152);
        assertEq(
            InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            0x79b97198c84fbb044cdda584716b22b5f0da3a199307ca0dea63b2e03e72f10f
        );
    }
}
