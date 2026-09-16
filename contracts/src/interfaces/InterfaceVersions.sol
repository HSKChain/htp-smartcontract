// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Canonical interface version tags for registry compatibility checks.
library InterfaceVersions {
    bytes32 internal constant ASSET_ADAPTER_V1 = keccak256(bytes("HTP_IASSET_ADAPTER_V1"));
    bytes32 internal constant PRINCIPAL_CALCULATOR_V1 = keccak256(bytes("HTP_IPRINCIPAL_CALCULATOR_V1"));
}
