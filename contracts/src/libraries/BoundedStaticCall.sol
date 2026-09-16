// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Gas-bounded staticcalls with fixed return-word size checks.
library BoundedStaticCall {
    /// @notice Staticcall expecting exactly one 32-byte return word.
    function staticCallWord(address target, bytes memory callData, uint256 gasLimit)
        internal
        view
        returns (bool success, bytes32 result)
    {
        (bool callSucceeded, bool returnWellFormed, bytes32 value) = staticCallWordStatus(target, callData, gasLimit);
        success = callSucceeded && returnWellFormed;
        result = value;
    }

    /// @notice Like staticCallWord but exposes call and return-shape status separately.
    function staticCallWordStatus(address target, bytes memory callData, uint256 gasLimit)
        internal
        view
        returns (bool callSucceeded, bool returnWellFormed, bytes32 result)
    {
        if (target.code.length == 0) {
            return (false, false, bytes32(0));
        }

        assembly ("memory-safe") {
            let output := mload(0x40)

            mstore(output, 0)
            callSucceeded := staticcall(gasLimit, target, add(callData, 0x20), mload(callData), output, 0x20)

            returnWellFormed := eq(returndatasize(), 0x20)
            result := mload(output)
        }
    }

    /// @notice Staticcall expecting exactly three consecutive 32-byte words.
    function staticCallThreeWordsStatus(address target, bytes memory callData, uint256 gasLimit)
        internal
        view
        returns (bool callSucceeded, bool returnWellFormed, bytes32 first, bytes32 second, bytes32 third)
    {
        if (target.code.length == 0) return (false, false, bytes32(0), bytes32(0), bytes32(0));

        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            mstore(add(output, 0x40), 0)
            callSucceeded := staticcall(gasLimit, target, add(callData, 0x20), mload(callData), output, 0x60)
            returnWellFormed := eq(returndatasize(), 0x60)
            first := mload(output)
            second := mload(add(output, 0x20))
            third := mload(add(output, 0x40))
        }
    }

    /// @notice Staticcall expecting exactly four consecutive 32-byte words.
    function staticCallFourWordsStatus(address target, bytes memory callData, uint256 gasLimit)
        internal
        view
        returns (
            bool callSucceeded,
            bool returnWellFormed,
            bytes32 first,
            bytes32 second,
            bytes32 third,
            bytes32 fourth
        )
    {
        if (target.code.length == 0) {
            return (false, false, bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        }

        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            mstore(add(output, 0x40), 0)
            mstore(add(output, 0x60), 0)
            callSucceeded := staticcall(gasLimit, target, add(callData, 0x20), mload(callData), output, 0x80)
            returnWellFormed := eq(returndatasize(), 0x80)
            first := mload(output)
            second := mload(add(output, 0x20))
            third := mload(add(output, 0x40))
            fourth := mload(add(output, 0x60))
        }
    }
}
