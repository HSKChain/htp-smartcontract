// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "./HTPHashing.sol";
import {RestrictionProvider, RestrictionProviderSet} from "../types/HTPTypes.sol";

/// @notice Canonical ordering and hashing of restriction provider sets.
library RestrictionProviderLib {
    /// @notice Sort providers in-place and return the canonical set hash.
    function canonicalHash(RestrictionProvider[] memory providers) internal pure returns (bytes32) {
        for (uint256 index = 1; index < providers.length; ++index) {
            RestrictionProvider memory current = providers[index];
            uint256 cursor = index;
            while (cursor != 0 && _less(current, providers[cursor - 1])) {
                providers[cursor] = providers[cursor - 1];
                unchecked {
                    --cursor;
                }
            }
            providers[cursor] = current;
        }
        return HTPHashing.hashRestrictionProviderSet(RestrictionProviderSet({providers: providers}));
    }

    function _less(RestrictionProvider memory left, RestrictionProvider memory right) private pure returns (bool) {
        if (left.provider != right.provider) {
            return uint160(left.provider) < uint160(right.provider);
        }
        if (left.selector != right.selector) {
            return uint32(left.selector) < uint32(right.selector);
        }
        return uint256(left.codeHash) < uint256(right.codeHash);
    }
}
