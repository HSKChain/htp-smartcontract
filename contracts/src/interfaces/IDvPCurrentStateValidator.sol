// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Decision, SettlementParams} from "../types/HTPTypes.sol";

/// @notice Off-chain helper view of live registry state for settlement gating.
interface IDvPCurrentStateValidator {
    /// @notice Non-mutating pre-check using current on-chain registry snapshots.
    function preCheck(SettlementParams calldata params)
        external
        view
        returns (Decision decision, bytes4 reason, address assetAdapter, address settlementAdapter);

    /// @notice Resolve adapters and settlement config id for an executable settlement.
    function validateForSettlement(SettlementParams calldata params)
        external
        view
        returns (address assetAdapter, address settlementAdapter, bytes32 settlementAdapterConfigId);
}
