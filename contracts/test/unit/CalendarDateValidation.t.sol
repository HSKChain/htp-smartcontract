// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {CalendarDate} from "src/libraries/CalendarDate.sol";

contract CalendarDateHarness {
    function isValid(uint32 date) external pure returns (bool) {
        return CalendarDate.isValid(date);
    }

    function requireValid(uint32 date) external pure {
        CalendarDate.requireValid(date);
    }
}

contract CalendarDateValidationTest is Test {
    CalendarDateHarness private immutable HARNESS = new CalendarDateHarness();

    function testAcceptsRealGregorianDates() public view {
        assertTrue(HARNESS.isValid(20230810));
        assertTrue(HARNESS.isValid(20240229));
        assertTrue(HARNESS.isValid(20000229));
    }

    function testRejectsInvalidGregorianDates() public view {
        assertFalse(HARNESS.isValid(0));
        assertFalse(HARNESS.isValid(20230229));
        assertFalse(HARNESS.isValid(19000229));
        assertFalse(HARNESS.isValid(21000229));
        assertFalse(HARNESS.isValid(20231301));
        assertFalse(HARNESS.isValid(20230431));
        assertFalse(HARNESS.isValid(100_000_101));
    }

    function testRequireValidUsesStructuredError() public {
        vm.expectPartialRevert(bytes4(0x4f3037ec));
        HARNESS.requireValid(19000229);
    }
}
