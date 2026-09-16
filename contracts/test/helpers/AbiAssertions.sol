// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

function abiSelector(bytes memory encoded) pure returns (bytes4 value) {
    assembly ("memory-safe") {
        value := mload(add(encoded, 0x20))
    }
}

abstract contract AbiAssertions is Test {
    function _word(bytes memory encoded, uint256 offset) internal pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(encoded, 0x20), offset))
        }
    }
}
