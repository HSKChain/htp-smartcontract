// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Access-control role identifiers shared across HTP registries and DvP.
library Roles {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant GOVERNANCE_ROLE = keccak256(bytes("GOVERNANCE_ROLE"));
    bytes32 internal constant UPGRADER_ROLE = keccak256(bytes("UPGRADER_ROLE"));
    bytes32 internal constant PAUSER_ROLE = keccak256(bytes("PAUSER_ROLE"));
    bytes32 internal constant EXECUTOR_ROLE = keccak256(bytes("EXECUTOR_ROLE"));
    bytes32 internal constant CONFIGURER_ROLE = keccak256(bytes("CONFIGURER_ROLE"));
}
