// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Read-only DvP emergency and deployment identity flags.
interface IDvPGovernanceView {
    function globalPaused() external view returns (bool);
    function retired() external view returns (bool);
    function deploymentVersionHash() external view returns (bytes32);
}
