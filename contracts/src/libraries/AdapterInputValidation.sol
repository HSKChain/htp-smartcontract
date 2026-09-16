// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {TransferLeg} from "../types/HTPTypes.sol";

/// @notice Shared adapter preCheck input guards.
library AdapterInputValidation {
    /// @notice True when addresses, leg, context, or transferLegMask reject the call.
    function isInvalid(
        address token,
        address from,
        address to,
        TransferLeg leg,
        bytes32 contextHash,
        uint256 transferLegMask
    ) internal pure returns (bool) {
        if (
            token == address(0) || from == address(0) || to == address(0) || from == to || leg == TransferLeg.NONE
                || contextHash == bytes32(0)
        ) {
            return true;
        }

        return transferLegMask & (uint256(1) << uint8(leg)) == 0;
    }
}
