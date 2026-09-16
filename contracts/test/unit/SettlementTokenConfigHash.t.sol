// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {PermitCapability, SettlementTokenConfig, TokenDeploymentKind} from "src/types/HTPTypes.sol";

contract SettlementTokenConfigHashHarness {
    function hash(SettlementTokenConfig calldata config) external pure returns (bytes32) {
        return HTPHashing.hashSettlementTokenConfig(config);
    }
}

contract SettlementTokenConfigHashTest is Test {
    bytes32 private constant EXPECTED = 0x8081973707c52c088f1e79243b119ee528646da59d75df2d908afbc534479470;
    SettlementTokenConfigHashHarness private immutable HARNESS = new SettlementTokenConfigHashHarness();

    function testConfigHashMatchesBootstrapAndExcludesSelf() public view {
        SettlementTokenConfig memory config = SchemaFixtures.settlementTokenConfig();
        assertEq(HARNESS.hash(config), EXPECTED);
        config.configHash = bytes32(uint256(1));
        assertEq(HARNESS.hash(config), EXPECTED);
    }

    function testDeploymentAdapterPermitAndReplacementFieldsAreCommitted() public view {
        SettlementTokenConfig memory config = SchemaFixtures.settlementTokenConfig();
        config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.tokenCodeHash = _flip(config.tokenCodeHash);
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.implementation = address(0xc003);
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.implementationCodeHash = _flip(config.implementationCodeHash);
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.adapterConfigId = _flip(config.adapterConfigId);
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.adapterConfigHash = _flip(config.adapterConfigHash);
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.permitCapability = PermitCapability.UNSUPPORTED;
        _assertChanged(config);
        config = SchemaFixtures.settlementTokenConfig();
        config.replacesConfigId = bytes32(uint256(1));
        _assertChanged(config);
    }

    function _assertChanged(SettlementTokenConfig memory config) private view {
        assertNotEq(HARNESS.hash(config), EXPECTED);
    }

    function _flip(bytes32 value) private pure returns (bytes32) {
        return bytes32(uint256(value) ^ 1);
    }
}
