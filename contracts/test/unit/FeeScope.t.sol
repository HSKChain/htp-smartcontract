// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {AssetClass, ScopeType} from "src/types/HTPTypes.sol";

contract FeeScopeHarness {
    function key(ScopeType scopeType) external pure returns (bytes32) {
        return FeeScope.key(scopeType, bytes32(uint256(0x33)), bytes32(uint256(0x22)), AssetClass.FUND, 1);
    }

    function matchedHash(uint64 feePolicyEpoch, ScopeType scopeType, bytes32 scopeKeyHash)
        external
        pure
        returns (bytes32)
    {
        return FeeScope.matchedHash(feePolicyEpoch, scopeType, scopeKeyHash);
    }

    function priority() external pure returns (ScopeType[5] memory) {
        return FeeScope.priority();
    }
}

contract FeeScopeTest is Test {
    bytes32 private constant ASSET_VERSION_ID = bytes32(uint256(0x33));
    bytes32 private constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0x22));

    FeeScopeHarness private immutable HARNESS = new FeeScopeHarness();

    function testDerivesFiveCanonicalScopeKeys() public view {
        assertEq(HARNESS.key(ScopeType.ASSET_VERSION), ASSET_VERSION_ID);
        assertEq(HARNESS.key(ScopeType.INSTRUMENT), ECONOMIC_ASSET_ID_HASH);
        assertEq(HARNESS.key(ScopeType.ASSET_CLASS), bytes32(uint256(2)));
        assertEq(HARNESS.key(ScopeType.CHAIN), bytes32(uint256(1)));
        assertEq(HARNESS.key(ScopeType.GLOBAL), bytes32(0));
    }

    function testMatchedScopeHashesMatchReviewedLiterals() public view {
        assertEq(
            HARNESS.matchedHash(7, ScopeType.GLOBAL, bytes32(0)),
            0xffca2031947e302e5369292b5924cb916f8c61acedfb2ebe06fe669babcc29f8
        );
        assertEq(
            HARNESS.matchedHash(7, ScopeType.CHAIN, bytes32(uint256(1))),
            0x0eee0d88d938a0371a2d2e2ca4372e24242757cf75a157175b62b05d94713b28
        );
        assertEq(
            HARNESS.matchedHash(7, ScopeType.ASSET_CLASS, bytes32(uint256(2))),
            0x3f298c5625295e988ed9d6c3ebe8c527af6fd1cdd3caf42a2eb0cee0850fe977
        );
        assertEq(
            HARNESS.matchedHash(7, ScopeType.INSTRUMENT, ECONOMIC_ASSET_ID_HASH),
            0x1a4797c4b55bab5ca6b58ddbb0d04806e4a9ae9855fa52b7110f4c6acd8905f4
        );
        assertEq(
            HARNESS.matchedHash(7, ScopeType.ASSET_VERSION, ASSET_VERSION_ID),
            0x12d7d363eb7d209d2b7b559bb38b8fe081666c4fb29182676da67c204675820a
        );
    }

    function testPriorityIsExplicitAndNotEnumOrder() public view {
        ScopeType[5] memory priority = HARNESS.priority();
        assertEq(uint8(priority[0]), uint8(ScopeType.ASSET_VERSION));
        assertEq(uint8(priority[1]), uint8(ScopeType.INSTRUMENT));
        assertEq(uint8(priority[2]), uint8(ScopeType.ASSET_CLASS));
        assertEq(uint8(priority[3]), uint8(ScopeType.CHAIN));
        assertEq(uint8(priority[4]), uint8(ScopeType.GLOBAL));
    }

    function testRejectsNoneScope() public {
        vm.expectPartialRevert(bytes4(0x3598a30e));
        HARNESS.key(ScopeType.NONE);
    }
}
