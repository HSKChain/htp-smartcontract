// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract AssetAdapterAbiHarness is IAssetAdapter {
    function interfaceVersion() external pure returns (bytes32) {
        return bytes32(uint256(0x1234));
    }

    function capabilities() external pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            precheckMethod: PrecheckMethod.NO_PRECHECK,
            transferLegMask: 14
        });
    }

    function capabilityHash() external pure returns (bytes32) {
        return bytes32(uint256(0xCAFE));
    }

    function providerHash() external pure returns (bytes32) {
        return bytes32(uint256(0xBEEF));
    }

    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        pure
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        return (Decision.PASS, 7, bytes32(uint256(0xD00D)));
    }
}

contract IAssetAdapterAbiTest is Test {
    IAssetAdapter private immutable ADAPTER = new AssetAdapterAbiHarness();

    function testPublicAbiMatchesReviewedSelectorsAndFixedReturnShapes() public view {
        assertEq(IAssetAdapter.interfaceVersion.selector, bytes4(0x1d8ffa4d));
        assertEq(IAssetAdapter.capabilities.selector, bytes4(0x34a18fc3));
        assertEq(IAssetAdapter.capabilityHash.selector, bytes4(0xb61a1820));
        assertEq(IAssetAdapter.providerHash.selector, bytes4(0x8898b13f));
        assertEq(IAssetAdapter.preCheck.selector, bytes4(0x4b5cf187));

        bytes memory callData = abi.encodeCall(
            IAssetAdapter.preCheck,
            (address(0x1000), address(0x2000), address(0x3000), 1, TransferLeg.ASSET, bytes32(uint256(0x4000)))
        );
        assertEq(abiSelector(callData), bytes4(0x4b5cf187));

        (bool capabilitiesSuccess, bytes memory capabilitiesData) =
            address(ADAPTER).staticcall(abi.encodeCall(IAssetAdapter.capabilities, ()));
        assertTrue(capabilitiesSuccess);
        assertEq(capabilitiesData.length, 128);
        AdapterCapabilities memory value = abi.decode(capabilitiesData, (AdapterCapabilities));
        assertEq(uint8(value.tokenStandard), uint8(TokenStandard.ERC20));
        assertEq(uint8(value.restrictionMode), uint8(RestrictionMode.UNRESTRICTED));
        assertEq(uint8(value.precheckMethod), uint8(PrecheckMethod.NO_PRECHECK));
        assertEq(value.transferLegMask, 14);

        (bool preCheckSuccess, bytes memory preCheckData) = address(ADAPTER).staticcall(callData);
        assertTrue(preCheckSuccess);
        assertEq(preCheckData.length, 96);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            abi.decode(preCheckData, (Decision, uint256, bytes32));
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 7);
        assertEq(reasonHash, bytes32(uint256(0xD00D)));
    }
}
