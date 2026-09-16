// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AssetClass, ScopeType} from "../types/HTPTypes.sol";
import {HTPErrors} from "../types/HTPErrors.sol";

/// @notice Fee scope keys, matched-scope hashes, and resolver priority order.
library FeeScope {
    bytes32 internal constant TYPEHASH =
        keccak256("FeeScope(uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash)");

    /// @notice Resolve scope key from scope type and binding fields; reverts on NONE.
    function key(
        ScopeType scopeType,
        bytes32 assetVersionId,
        bytes32 economicAssetIdHash,
        AssetClass assetClass,
        uint256 chainId
    ) internal pure returns (bytes32) {
        if (scopeType == ScopeType.ASSET_VERSION) {
            return assetVersionId;
        }
        if (scopeType == ScopeType.INSTRUMENT) {
            return economicAssetIdHash;
        }
        if (scopeType == ScopeType.ASSET_CLASS) {
            return bytes32(uint256(assetClass));
        }
        if (scopeType == ScopeType.CHAIN) {
            return bytes32(chainId);
        }
        if (scopeType == ScopeType.GLOBAL) {
            return bytes32(0);
        }

        revert HTPErrors.InvalidFeeScope(scopeType);
    }

    /// @notice EIP-712-style matched scope hash for a registered fee version.
    function matchedHash(uint64 feePolicyEpoch, ScopeType scopeType, bytes32 scopeKeyHash)
        internal
        pure
        returns (bytes32)
    {
        if (scopeType == ScopeType.NONE) {
            revert HTPErrors.InvalidFeeScope(scopeType);
        }
        return matchedHashWithoutValidation(feePolicyEpoch, scopeType, scopeKeyHash);
    }

    /// @dev Matched hash without rejecting ScopeType.NONE (internal composition only).
    function matchedHashWithoutValidation(uint64 feePolicyEpoch, ScopeType scopeType, bytes32 scopeKeyHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(TYPEHASH, feePolicyEpoch, scopeType, scopeKeyHash));
    }

    /// @notice Most-specific-first scope types used by fee resolution.
    function priority() internal pure returns (ScopeType[5] memory order) {
        order[0] = ScopeType.ASSET_VERSION;
        order[1] = ScopeType.INSTRUMENT;
        order[2] = ScopeType.ASSET_CLASS;
        order[3] = ScopeType.CHAIN;
        order[4] = ScopeType.GLOBAL;
    }
}
