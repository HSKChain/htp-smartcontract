// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AdapterCapabilities, Decision, TransferLeg} from "../types/HTPTypes.sol";

/// @notice Token transfer restriction adapter invoked during DvP settlement legs.
interface IAssetAdapter {
    function interfaceVersion() external pure returns (bytes32);
    function capabilities() external pure returns (AdapterCapabilities memory);
    function capabilityHash() external pure returns (bytes32);
    function providerHash() external view returns (bytes32);

    /// @notice Fail-closed transfer leg check; returns restriction code and reason hash on deny.
    function preCheck(address token, address from, address to, uint256 amount, TransferLeg leg, bytes32 contextHash)
        external
        view
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash);
}
