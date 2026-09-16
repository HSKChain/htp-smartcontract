// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    RestrictionProvider,
    RestrictionProviderSet,
    TokenStandard
} from "src/types/HTPTypes.sol";

contract AdapterHashHarness {
    function capabilities(AdapterCapabilities memory value) external pure returns (bytes32) {
        return HTPHashing.hashAdapterCapabilities(value);
    }

    function providerSet(RestrictionProviderSet memory providers) external pure returns (bytes32) {
        return HTPHashing.hashRestrictionProviderSet(providers);
    }

    function config(AdapterConfig memory value) external pure returns (bytes32) {
        return HTPHashing.hashAdapterConfig(value);
    }
}

contract AdapterHashesTest is Test {
    AdapterHashHarness private immutable HARNESS = new AdapterHashHarness();

    function testCapabilitiesProviderSetAndConfigMatchBootstrapLiterals() public view {
        AdapterCapabilities memory capabilities = SchemaFixtures.adapterCapabilities();
        RestrictionProviderSet memory providers = SchemaFixtures.providerSet();
        AdapterConfig memory config = SchemaFixtures.adapterConfig();
        assertEq(HARNESS.capabilities(capabilities), 0x152063e52bb5922fd31769b05858b799d3603b488d6a5c64f177daf11189aa22);
        assertEq(HARNESS.providerSet(providers), 0x96298c997293e6def5721fe524fa1d21ad5a4e65a3b7a93e8001494e23685d43);
        assertEq(HARNESS.config(config), 0xafd135ca78e477a323d956fc561cb6d7dbbbc134268766a998827e2e082ca00b);
        config.configHash = bytes32(uint256(1));
        assertEq(HARNESS.config(config), 0xafd135ca78e477a323d956fc561cb6d7dbbbc134268766a998827e2e082ca00b);
    }

    function testProviderAddressSelectorAndCodeHashAreCommitted() public view {
        RestrictionProviderSet memory providers = SchemaFixtures.providerSet();
        bytes32 expected = 0x96298c997293e6def5721fe524fa1d21ad5a4e65a3b7a93e8001494e23685d43;
        providers.providers[0].provider = address(0xe000);
        assertNotEq(HARNESS.providerSet(providers), expected);
        providers = SchemaFixtures.providerSet();
        providers.providers[0].selector = 0x01020303;
        assertNotEq(HARNESS.providerSet(providers), expected);
        providers = SchemaFixtures.providerSet();
        providers.providers[0].codeHash = bytes32(uint256(0x800));
        assertNotEq(HARNESS.providerSet(providers), expected);
    }

    function testCapabilitiesAreNestedAndExplicitlyBound() public view {
        AdapterConfig memory config = SchemaFixtures.adapterConfig();
        config.capabilities.tokenStandard = TokenStandard.ERC1404;
        assertEq(HARNESS.config(config), 0x3095e024d27edadd68d671e1780519be91de29d699c4b407474a4003e6044d13);
        config = SchemaFixtures.adapterConfig();
        config.capabilityHash = bytes32(uint256(config.capabilityHash) ^ 1);
        assertEq(HARNESS.config(config), 0x412f30d3dc5763a16437d0a8f3775f7b0244b967001efc80aa60bf6e6f5cb591);
    }

    function testRejectsUnsortedOrDuplicateProviderSet() public {
        RestrictionProviderSet memory providers = SchemaFixtures.providerSet();
        RestrictionProvider memory first = providers.providers[0];
        providers.providers[0] = providers.providers[1];
        providers.providers[1] = first;
        vm.expectPartialRevert(bytes4(0x69ae562b));
        HARNESS.providerSet(providers);

        providers = SchemaFixtures.providerSet();
        providers.providers[1] = providers.providers[0];
        vm.expectPartialRevert(bytes4(0x69ae562b));
        HARNESS.providerSet(providers);

        providers = SchemaFixtures.providerSet();
        providers.providers[0].provider = providers.providers[1].provider;
        providers.providers[0].selector = 0x06000000;
        vm.expectPartialRevert(bytes4(0x69ae562b));
        HARNESS.providerSet(providers);

        providers = SchemaFixtures.providerSet();
        providers.providers[0].provider = providers.providers[1].provider;
        providers.providers[0].selector = providers.providers[1].selector;
        providers.providers[0].codeHash = bytes32(uint256(0x803));
        vm.expectPartialRevert(bytes4(0x69ae562b));
        HARNESS.providerSet(providers);
    }
}
