// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HTPTypes} from "src/types/HTPTypes.sol";

contract SchemaVersionTest is Test {
    function testSchemaVersionIsOne() public pure {
        assertEq(HTPTypes.SCHEMA_VERSION, 1);
    }
}
