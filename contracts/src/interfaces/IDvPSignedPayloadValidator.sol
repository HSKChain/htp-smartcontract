// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Decision, NonceCancellation, SettlementParams} from "../types/HTPTypes.sol";

/// @notice EIP-712 settlement and nonce-cancellation validation for DvP.
interface IDvPSignedPayloadValidator {
    /// @notice Signature-free pre-check of settlement params and signer binding.
    function preCheck(SettlementParams calldata params) external view returns (Decision decision, bytes4 reason);

    /// @notice Full signed settlement validation; reverts on failure.
    function validateForSettlement(SettlementParams calldata params) external view;

    /// @notice Validate a signed nonce cancellation payload.
    function validateNonceCancellation(NonceCancellation calldata cancellation, bytes calldata signature) external view;
}
