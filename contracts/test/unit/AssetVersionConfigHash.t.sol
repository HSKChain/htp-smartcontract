// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    AssetClass,
    AssetVersionConfig,
    PermitCapability,
    RestrictionMode,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";

contract AssetVersionConfigHashHarness {
    function hash(AssetVersionConfig calldata config) external pure returns (bytes32) {
        return HTPHashing.hashAssetVersionConfig(config);
    }
}

contract AssetVersionConfigHashTest is Test {
    bytes32 private constant EXPECTED = 0xd385a9a11510751ff4f094ad8c6875aeb313eb3f5bfd4f524f311400958b456a;
    AssetVersionConfigHashHarness private immutable HARNESS = new AssetVersionConfigHashHarness();

    function testConfigHashMatchesBootstrapAndExcludesSelf() public view {
        AssetVersionConfig memory config = SchemaFixtures.assetVersionConfig();
        assertEq(HARNESS.hash(config), EXPECTED);
        config.configHash = bytes32(uint256(1));
        assertEq(HARNESS.hash(config), EXPECTED);
    }

    function testEveryImmutableFieldMutationChangesHash() public view {
        AssetVersionConfig memory config = SchemaFixtures.assetVersionConfig();
        config.schemaVersion += 1;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.economicAssetIdHash = _flip(config.economicAssetIdHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.assetVersionId = _flip(config.assetVersionId);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.chainId += 1;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.versionNo += 1;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.assetToken = address(0xa002);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.tokenStandard = TokenStandard.ERC1404;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.assetDecimals += 1;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.tokenCodeHash = _flip(config.tokenCodeHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.implementation = address(0xa003);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.implementationCodeHash = _flip(config.implementationCodeHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.assetPermitCapability = PermitCapability.UNSUPPORTED;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.assetClass = AssetClass.BOND;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.principalCalculatorConfigId = _flip(config.principalCalculatorConfigId);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.principalCalculatorConfigHash = _flip(config.principalCalculatorConfigHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.adapterConfigId = _flip(config.adapterConfigId);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.adapterConfigHash = _flip(config.adapterConfigHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.restrictionMode = RestrictionMode.ISSUER_EXTERNAL;
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.settlementToken = address(0xc002);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.settlementTokenConfigId = _flip(config.settlementTokenConfigId);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.settlementTokenConfigHash = _flip(config.settlementTokenConfigHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.dvpContract = address(0xd002);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.deploymentVersionHash = _flip(config.deploymentVersionHash);
        _assertChanged(config);
        config = SchemaFixtures.assetVersionConfig();
        config.replacesAssetVersionId = bytes32(uint256(1));
        _assertChanged(config);
    }

    function _assertChanged(AssetVersionConfig memory config) private view {
        assertNotEq(HARNESS.hash(config), EXPECTED);
    }

    function _flip(bytes32 value) private pure returns (bytes32) {
        return bytes32(uint256(value) ^ 1);
    }
}
