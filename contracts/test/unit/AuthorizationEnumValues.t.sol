// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Decision, NonceStatus, NonceType, PermitCapability, RoundingMode} from "src/types/HTPTypes.sol";

contract AuthorizationEnumValuesTest is Test {
    function testDecisionValues() public pure {
        assertEq(uint8(Decision.NONE), 0);
        assertEq(uint8(Decision.PASS), 1);
        assertEq(uint8(Decision.BLOCK), 2);
        assertEq(uint8(Decision.UNKNOWN), 3);
    }

    function testNonceTypeValues() public pure {
        assertEq(uint8(NonceType.NONE), 0);
        assertEq(uint8(NonceType.MAKER_QUOTE), 1);
        assertEq(uint8(NonceType.REQUESTER_TRADE), 2);
    }

    function testNonceStatusValues() public pure {
        assertEq(uint8(NonceStatus.NONE), 0);
        assertEq(uint8(NonceStatus.UNUSED), 1);
        assertEq(uint8(NonceStatus.USED), 2);
        assertEq(uint8(NonceStatus.CANCELLED), 3);
    }

    function testPermitCapabilityValues() public pure {
        assertEq(uint8(PermitCapability.NONE), 0);
        assertEq(uint8(PermitCapability.UNSUPPORTED), 1);
        assertEq(uint8(PermitCapability.EIP2612), 2);
    }

    function testRoundingModeValues() public pure {
        assertEq(uint8(RoundingMode.NONE), 0);
        assertEq(uint8(RoundingMode.DOWN), 1);
    }
}
