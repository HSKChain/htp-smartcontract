// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "../types/HTPErrors.sol";

/// @notice Reject proxy-shaped bytecode when registering implementation dependencies.
library RegistryImplementationValidation {
    uint256 internal constant VALIDATION_GAS_LIMIT = 200_000;

    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    bytes32 private constant EIP1167_PREFIX_MASK = 0xffffffffffffffffffff00000000000000000000000000000000000000000000;
    bytes32 private constant EIP1167_PREFIX = 0x363d3d373d3d3d363d7300000000000000000000000000000000000000000000;
    bytes32 private constant EIP1167_SUFFIX = 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000;

    /// @notice Require non-proxy contract code and return its codehash.
    function requireDirectCode(address implementation) internal view returns (bytes32 codeHash) {
        uint256 codeSize = implementation.code.length;

        if (implementation == address(0) || codeSize == 0) {
            revert HTPErrors.InvalidImplementation(implementation);
        }

        if (_containsProxyPattern(implementation, codeSize)) {
            revert HTPErrors.UpgradeableImplementationForbidden(implementation);
        }
        codeHash = implementation.codehash;
    }

    /// @notice True when account bytecode matches a known minimal or ERC-1967 proxy pattern.
    function hasProxyShape(address account) internal view returns (bool) {
        uint256 codeSize = account.code.length;
        if (codeSize == 0) return false;
        return _containsProxyPattern(account, codeSize);
    }

    function _containsProxyPattern(address implementation, uint256 codeSize) private view returns (bool) {
        bytes memory runtimeCode = new bytes(codeSize);
        assembly ("memory-safe") {
            extcodecopy(implementation, add(runtimeCode, 0x20), 0, codeSize)
        }
        if (codeSize == 45) {
            bytes32 prefixWord;
            bytes32 suffixWord;
            assembly ("memory-safe") {
                prefixWord := mload(add(runtimeCode, 0x20))
                suffixWord := mload(add(runtimeCode, 0x3e))
            }

            if ((prefixWord & EIP1167_PREFIX_MASK) == EIP1167_PREFIX && suffixWord == EIP1167_SUFFIX) {
                return true;
            }
        }
        if (codeSize < 32) return false;

        for (uint256 offset; offset <= codeSize - 32; ++offset) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(runtimeCode, 0x20), offset))
            }
            if (word == ERC1967_IMPLEMENTATION_SLOT || word == ERC1967_BEACON_SLOT) return true;
        }
        return false;
    }
}
