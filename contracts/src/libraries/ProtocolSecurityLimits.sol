// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Protocol-wide gas and time bounds for external calls and quotes.
library ProtocolSecurityLimits {
    uint256 internal constant ADAPTER_PROVIDER_CALL_GAS_MAX = 100_000;
    uint256 internal constant ERC1271_CALL_GAS = 200_000;
    uint64 internal constant MAX_QUOTE_LIFETIME = 1 hours;

    error AdapterProviderCallGasOutOfRange(uint256 provided, uint256 maximum);

    /// @notice Revert unless adapter provider static-call gas is within protocol bounds.
    function requireValidAdapterProviderCallGas(uint256 provided) internal pure {
        if (provided == 0 || provided > ADAPTER_PROVIDER_CALL_GAS_MAX) {
            revert AdapterProviderCallGasOutOfRange(provided, ADAPTER_PROVIDER_CALL_GAS_MAX);
        }
    }
}
