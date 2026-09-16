// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AdapterRecord,
    PrecheckMethod,
    RestrictionMode,
    RestrictionProvider,
    RestrictionProviderSet,
    ReasonCode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract AdapterConfigAbiTest is Test {
    function testAdapterRegistryPublicSelectorsMatchReviewedLiterals() public pure {
        assertEq(IAdapterRegistry.registerAdapter.selector, bytes4(0x4095a4f3));
        assertEq(IAdapterRegistry.activateAdapter.selector, bytes4(0x4138cff9));
        assertEq(IAdapterRegistry.pauseAdapter.selector, bytes4(0x851dc0ea));
        assertEq(IAdapterRegistry.unpauseAdapter.selector, bytes4(0xba01f144));
        assertEq(IAdapterRegistry.deprecateAdapter.selector, bytes4(0x2c222b45));
        assertEq(IAdapterRegistry.getAdapter.selector, bytes4(0x8272e138));
        assertEq(IAdapterRegistry.getCurrentAdapter.selector, bytes4(0x812752ed));
        assertEq(IAdapterRegistry.isAdapterActive.selector, bytes4(0x3b832410));
        assertEq(IAdapterRegistry.registerDependentDvp.selector, bytes4(0x03f8d147));
        assertEq(IAdapterRegistry.exemptRetiredDependentDvp.selector, bytes4(0xd74df627));
        assertEq(IAdapterRegistry.getDependentDvpCount.selector, bytes4(0xbafdbeba));
        assertEq(IAdapterRegistry.getDependentDvp.selector, bytes4(0x9816d4b9));
        assertEq(IAdapterRegistry.upgradeToAndCall.selector, bytes4(0x4f1ef286));

        bytes memory callData = abi.encodeCall(
            IAdapterRegistry.unpauseAdapter,
            (bytes32(uint256(1)), bytes32(uint256(2)), ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(3)))
        );
        assertEq(abiSelector(callData), bytes4(0xba01f144));
    }

    function testAdapterCapabilitiesUseEnumIndexedMask() public pure {
        uint256 mask =
            (uint256(1) << uint8(TransferLeg.ASSET)) | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_SELLER));
        AdapterCapabilities memory capabilities = AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.TOKEN_ENFORCED,
            precheckMethod: PrecheckMethod.TOKEN_SPECIFIC_CHECK,
            transferLegMask: mask
        });
        assertEq(mask & 1, 0);
        assertEq(capabilities.transferLegMask, 6);
        assertEq(abi.encode(capabilities).length, 4 * 32);
    }

    function testRestrictionProvidersCanUseCanonicalLexicographicOrder() public pure {
        RestrictionProvider[] memory providers = new RestrictionProvider[](2);
        providers[0] =
            RestrictionProvider({provider: address(1), selector: bytes4(0x01020304), codeHash: bytes32(uint256(1))});
        providers[1] =
            RestrictionProvider({provider: address(2), selector: bytes4(0x01020304), codeHash: bytes32(uint256(1))});
        RestrictionProviderSet memory providerSet = RestrictionProviderSet({providers: providers});
        assertEq(providerSet.providers.length, 2);
        assertLt(uint160(providerSet.providers[0].provider), uint160(providerSet.providers[1].provider));
    }

    function testAdapterConfigOwnsCapabilitiesAndProviderHash() public pure {
        AdapterConfig memory config;
        config.schemaVersion = 1;
        config.capabilityHash = bytes32(uint256(13));
        config.providerHash = bytes32(uint256(14));
        bytes memory callData = abi.encodeCall(IAdapterRegistry.registerAdapter, (config));
        assertEq(abiSelector(callData), IAdapterRegistry.registerAdapter.selector);
        assertEq(callData.length, 4 + 15 * 32);
        AdapterRecord memory record;
        record.config = config;
        record.exists = true;
        assertEq(record.config.capabilityHash, bytes32(uint256(13)));
        assertEq(record.config.providerHash, bytes32(uint256(14)));
    }
}
