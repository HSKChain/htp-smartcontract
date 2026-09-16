// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";

contract ConfigIdHarness {
    function feeNamespace() external pure returns (bytes32) {
        return ConfigId.FEE_NAMESPACE;
    }

    function adapterNamespace() external pure returns (bytes32) {
        return ConfigId.ADAPTER_NAMESPACE;
    }

    function derive(bytes32 namespaceHash, uint32 schemaVersion, uint256 chainId, bytes32 subjectKey, uint32 revision)
        external
        pure
        returns (bytes32)
    {
        return ConfigId.derive(namespaceHash, schemaVersion, chainId, subjectKey, revision);
    }

    function assetVersion(
        uint32 schemaVersion,
        bytes32 economicAssetIdHash,
        uint256 chainId,
        address assetToken,
        uint32 versionNo
    ) external pure returns (bytes32) {
        return ConfigId.assetVersion(schemaVersion, economicAssetIdHash, chainId, assetToken, versionNo);
    }
}

contract ConfigIdTest is Test {
    bytes32 private constant SUBJECT = bytes32(uint256(0x11));
    bytes32 private constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0x22));
    ConfigIdHarness private immutable HARNESS = new ConfigIdHarness();

    function testGenericConfigIdMatchesReviewedAbiEncodeLiteral() public view {
        assertEq(
            HARNESS.derive(HARNESS.feeNamespace(), 1, 1, SUBJECT, 1),
            0x102501988795b4d3f2640ef1d4a0e5875583e7fe9ce3f2fd3bf5b063eaeded7d
        );
    }

    function testGenericConfigIdSeparatesIdentityInputs() public view {
        bytes32 expected = 0x102501988795b4d3f2640ef1d4a0e5875583e7fe9ce3f2fd3bf5b063eaeded7d;
        assertNotEq(expected, HARNESS.derive(HARNESS.adapterNamespace(), 1, 1, SUBJECT, 1));
        assertNotEq(expected, HARNESS.derive(HARNESS.feeNamespace(), 2, 1, SUBJECT, 1));
        assertNotEq(expected, HARNESS.derive(HARNESS.feeNamespace(), 1, 2, SUBJECT, 1));
        assertNotEq(expected, HARNESS.derive(HARNESS.feeNamespace(), 1, 1, bytes32(uint256(0x12)), 1));
        assertNotEq(expected, HARNESS.derive(HARNESS.feeNamespace(), 1, 1, SUBJECT, 2));
    }

    function testAssetVersionIdMatchesReviewedLiteral() public view {
        assertEq(
            HARNESS.assetVersion(1, ECONOMIC_ASSET_ID_HASH, 1, address(0x1001), 1),
            0xab7335fb797e5dc32b3e537d88543f02f81492eb62512b197b8119b1c5db1855
        );
    }

    function testAssetVersionIdChangesWithEveryIdentityInput() public view {
        bytes32 expected = 0xab7335fb797e5dc32b3e537d88543f02f81492eb62512b197b8119b1c5db1855;
        assertNotEq(expected, HARNESS.assetVersion(2, ECONOMIC_ASSET_ID_HASH, 1, address(0x1001), 1));
        assertNotEq(expected, HARNESS.assetVersion(1, bytes32(uint256(0x23)), 1, address(0x1001), 1));
        assertNotEq(expected, HARNESS.assetVersion(1, ECONOMIC_ASSET_ID_HASH, 2, address(0x1001), 1));
        assertNotEq(expected, HARNESS.assetVersion(1, ECONOMIC_ASSET_ID_HASH, 1, address(0x1002), 1));
        assertNotEq(expected, HARNESS.assetVersion(1, ECONOMIC_ASSET_ID_HASH, 1, address(0x1001), 2));
    }
}
