// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPCurrentStateValidator} from "./IDvPCurrentStateValidator.sol";

interface IDvPCurrentStateValidatorFactory {
    /// @notice Deploy a validator bound to the given DvP contract address.
    function deployValidator(address dvp) external returns (IDvPCurrentStateValidator validator);
}
