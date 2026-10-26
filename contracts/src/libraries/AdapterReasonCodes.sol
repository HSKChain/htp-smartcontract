// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Numeric restriction codes and canonical reason hashes for asset adapters.
library AdapterReasonCodes {
    uint256 internal constant INVALID_INPUT = 1;
    uint256 internal constant UNAPPROVED_CALLER = 2;

    uint256 internal constant USDY_TOKEN_PAUSED = 10;
    uint256 internal constant USDY_FROM_BLOCKED = 11;
    uint256 internal constant USDY_FROM_NOT_ALLOWED = 12;
    uint256 internal constant USDY_FROM_SANCTIONED = 13;
    uint256 internal constant USDY_TO_BLOCKED = 14;
    uint256 internal constant USDY_TO_NOT_ALLOWED = 15;
    uint256 internal constant USDY_TO_SANCTIONED = 16;
    uint256 internal constant USDY_CALLER_BLOCKED = 17;
    uint256 internal constant USDY_CALLER_NOT_ALLOWED = 18;
    uint256 internal constant USDY_CALLER_SANCTIONED = 19;

    uint256 internal constant ONDO_GM_TOKEN_PAUSED = 20;
    uint256 internal constant ONDO_GM_FROM_BLOCKED = 21;
    uint256 internal constant ONDO_GM_FROM_SANCTIONED = 22;
    uint256 internal constant ONDO_GM_TO_BLOCKED = 23;
    uint256 internal constant ONDO_GM_TO_SANCTIONED = 24;
    uint256 internal constant ONDO_GM_CALLER_BLOCKED = 25;
    uint256 internal constant ONDO_GM_CALLER_SANCTIONED = 26;

    bytes32 internal constant INVALID_INPUT_REASON = keccak256("HTP_ADAPTER_INVALID_INPUT");
    bytes32 internal constant UNAPPROVED_CALLER_REASON = keccak256("HTP_ADAPTER_UNAPPROVED_CALLER");
    bytes32 internal constant EXTERNAL_CALL_FAILED_REASON = keccak256("HTP_ADAPTER_EXTERNAL_CALL_FAILED");
    bytes32 internal constant PROVIDER_MISMATCH_REASON = keccak256("HTP_ADAPTER_PROVIDER_MISMATCH");
    bytes32 internal constant PROVIDER_INTERFACE_MISSING_REASON = keccak256("HTP_ADAPTER_PROVIDER_INTERFACE_MISSING");

    bytes32 internal constant ERC1404_RESTRICTION_DOMAIN = keccak256("HTP_ERC1404_RESTRICTION");
    bytes32 internal constant USDY_TOKEN_PAUSED_REASON = keccak256("HTP_USDY_TOKEN_PAUSED");
    bytes32 internal constant USDY_FROM_BLOCKED_REASON = keccak256("HTP_USDY_FROM_BLOCKED");
    bytes32 internal constant USDY_FROM_NOT_ALLOWED_REASON = keccak256("HTP_USDY_FROM_NOT_ALLOWED");
    bytes32 internal constant USDY_FROM_SANCTIONED_REASON = keccak256("HTP_USDY_FROM_SANCTIONED");
    bytes32 internal constant USDY_TO_BLOCKED_REASON = keccak256("HTP_USDY_TO_BLOCKED");
    bytes32 internal constant USDY_TO_NOT_ALLOWED_REASON = keccak256("HTP_USDY_TO_NOT_ALLOWED");
    bytes32 internal constant USDY_TO_SANCTIONED_REASON = keccak256("HTP_USDY_TO_SANCTIONED");
    bytes32 internal constant USDY_CALLER_BLOCKED_REASON = keccak256("HTP_USDY_CALLER_BLOCKED");
    bytes32 internal constant USDY_CALLER_NOT_ALLOWED_REASON = keccak256("HTP_USDY_CALLER_NOT_ALLOWED");
    bytes32 internal constant USDY_CALLER_SANCTIONED_REASON = keccak256("HTP_USDY_CALLER_SANCTIONED");

    bytes32 internal constant ONDO_GM_TOKEN_PAUSED_REASON = keccak256("HTP_ONDO_GM_TOKEN_PAUSED");
    bytes32 internal constant ONDO_GM_FROM_BLOCKED_REASON = keccak256("HTP_ONDO_GM_FROM_BLOCKED");
    bytes32 internal constant ONDO_GM_FROM_SANCTIONED_REASON = keccak256("HTP_ONDO_GM_FROM_SANCTIONED");
    bytes32 internal constant ONDO_GM_TO_BLOCKED_REASON = keccak256("HTP_ONDO_GM_TO_BLOCKED");
    bytes32 internal constant ONDO_GM_TO_SANCTIONED_REASON = keccak256("HTP_ONDO_GM_TO_SANCTIONED");
    bytes32 internal constant ONDO_GM_CALLER_BLOCKED_REASON = keccak256("HTP_ONDO_GM_CALLER_BLOCKED");
    bytes32 internal constant ONDO_GM_CALLER_SANCTIONED_REASON = keccak256("HTP_ONDO_GM_CALLER_SANCTIONED");

    /// @notice Map an ERC-1404-style numeric code to a stable reason hash.
    function erc1404RestrictionReason(uint256 restrictionCode) internal pure returns (bytes32) {
        return keccak256(abi.encode(ERC1404_RESTRICTION_DOMAIN, restrictionCode));
    }
}
