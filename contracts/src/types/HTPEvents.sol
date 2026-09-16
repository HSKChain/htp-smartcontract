// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Namespace reserved for task-driven project audit events.
/// @dev Events are added only by the state behavior task whose public Red requires them.
library HTPEvents {
    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
}
