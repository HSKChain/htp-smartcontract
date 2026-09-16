// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "../types/HTPErrors.sol";

/// @notice YYYYMMDD calendar date validation for bond and fee inputs.
library CalendarDate {
    /// @notice Return whether `date` is a valid Gregorian calendar date.
    function isValid(uint32 date) internal pure returns (bool) {
        uint32 year = date / 10_000;
        uint32 month = (date / 100) % 100;
        uint32 day = date % 100;

        if (year == 0 || year > 9999 || month == 0 || month > 12 || day == 0) {
            return false;
        }

        uint32 daysInMonth;
        if (month == 2) {
            bool leapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            daysInMonth = leapYear ? 29 : 28;
        } else if (month == 4 || month == 6 || month == 9 || month == 11) {
            daysInMonth = 30;
        } else {
            daysInMonth = 31;
        }

        return day <= daysInMonth;
    }

    /// @notice Revert with InvalidCalendarDate when `date` is not valid.
    function requireValid(uint32 date) internal pure {
        if (!isValid(date)) {
            revert HTPErrors.InvalidCalendarDate(date);
        }
    }
}
