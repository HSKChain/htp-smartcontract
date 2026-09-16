// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {RevertingTokenProbe} from "test/fixtures/AdapterMocks.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";

contract UnrestrictedERC20AdapterTest is Test {
    address private constant DVP = address(0xD0);
    IAssetAdapter private immutable ADAPTER = IAssetAdapter(address(new UnrestrictedERC20Adapter(DVP)));

    function testCapabilitiesAndHashesMatchReviewedConfigHashLiterals() public view {
        AdapterCapabilities memory capabilities = ADAPTER.capabilities();

        assertEq(ADAPTER.interfaceVersion(), InterfaceVersions.ASSET_ADAPTER_V1);
        assertEq(uint8(capabilities.tokenStandard), uint8(TokenStandard.ERC20));
        assertEq(uint8(capabilities.restrictionMode), uint8(RestrictionMode.UNRESTRICTED));
        assertEq(uint8(capabilities.precheckMethod), uint8(PrecheckMethod.NO_PRECHECK));
        assertEq(
            capabilities.transferLegMask,
            (uint256(1) << uint8(TransferLeg.ASSET)) | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_SELLER))
                | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_COLLECTOR))
        );
        assertEq(ADAPTER.capabilityHash(), 0xe63e20fd283a6735b65aa90a59bb73b594ba63ed614137a5ccbcfd6050c9aec2);
        assertEq(ADAPTER.providerHash(), 0xeb1c53f7684c973de32da395ac7355828b21fd160bc85ce1319907002e5b4fa4);
    }

    function testApprovedStandardErc20LegPasses() public {
        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = ADAPTER.preCheck(
            address(0x1000), address(0x2000), address(0x3000), 50 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, bytes32(0));
    }

    function testInvalidLegAddressesAndContextAreRejected() public {
        address token = address(0x1000);
        address from = address(0x2000);
        address to = address(0x3000);
        bytes32 contextHash = bytes32(uint256(0x4000));

        _assertInvalid(address(0), from, to, TransferLeg.ASSET, contextHash);
        _assertInvalid(token, address(0), to, TransferLeg.ASSET, contextHash);
        _assertInvalid(token, from, address(0), TransferLeg.ASSET, contextHash);
        _assertInvalid(token, from, from, TransferLeg.ASSET, contextHash);
        _assertInvalid(token, from, to, TransferLeg.NONE, contextHash);
        _assertInvalid(token, from, to, TransferLeg.ASSET, bytes32(0));

        bytes memory unknownLegCall =
            abi.encodeWithSelector(IAssetAdapter.preCheck.selector, token, from, to, 1, uint256(4), contextHash);
        vm.prank(DVP);
        (bool success,) = address(ADAPTER).staticcall(unknownLegCall);
        assertFalse(success);
    }

    function testUnapprovedCallerIsRejected() public view {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = ADAPTER.preCheck(
            address(0x1000),
            address(0x2000),
            address(0x3000),
            1,
            TransferLeg.SETTLEMENT_TO_SELLER,
            bytes32(uint256(0x4000))
        );
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 2);
        assertEq(reasonHash, 0x6c8c48159f980e0cadca17cca18015ebceeb2b47fb10c4d81793e40a563929c1);
    }

    function testPreCheckDoesNotCallToken() public {
        RevertingTokenProbe token = new RevertingTokenProbe();
        vm.prank(DVP);
        (Decision decision,,) = ADAPTER.preCheck(
            address(token),
            address(0x2000),
            address(0x3000),
            1,
            TransferLeg.SETTLEMENT_TO_COLLECTOR,
            bytes32(uint256(0x4000))
        );
        assertEq(uint8(decision), uint8(Decision.PASS));
    }

    function _assertInvalid(address token, address from, address to, TransferLeg leg, bytes32 contextHash) private {
        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            ADAPTER.preCheck(token, from, to, 1, leg, contextHash);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 1);
        assertEq(reasonHash, 0x6ac07d7d2d3194b4beb93b8ad3194b1fe5e0a6eeeb46891b089005461b740e58);
    }
}
