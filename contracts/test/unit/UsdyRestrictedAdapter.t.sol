// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IBlocklist, IUsdyRestrictionToken, UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {AddressListMock, UsdyTokenMock} from "test/fixtures/AdapterMocks.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";

contract UsdyRestrictedAdapterTest is Test {
    address private constant DVP = address(0xD0);
    address private constant FROM = address(0x2000);
    address private constant TO = address(0x3000);
    uint256 private constant PROVIDER_CALL_GAS = 100_000;

    UsdyTokenMock private immutable TOKEN = new UsdyTokenMock();
    AddressListMock private immutable BLOCKLIST = new AddressListMock();
    AddressListMock private immutable ALLOWLIST = new AddressListMock();
    AddressListMock private immutable SANCTIONS = new AddressListMock();
    IAssetAdapter private immutable ADAPTER = IAssetAdapter(
        address(
            new UsdyRestrictedAdapter(
                DVP,
                address(TOKEN),
                address(TOKEN).codehash,
                address(BLOCKLIST),
                address(BLOCKLIST).codehash,
                address(ALLOWLIST),
                address(ALLOWLIST).codehash,
                address(SANCTIONS),
                address(SANCTIONS).codehash,
                PROVIDER_CALL_GAS
            )
        )
    );

    function setUp() public {
        TOKEN.configure(address(BLOCKLIST), address(ALLOWLIST), address(SANCTIONS));
        ALLOWLIST.setAllowed(FROM, true);
        ALLOWLIST.setAllowed(TO, true);
        ALLOWLIST.setAllowed(DVP, true);
    }

    function testAllApprovedUsdyRestrictionsPass() public {
        vm.prank(DVP);
        uint256 gasBefore = gasleft();
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_usdy_three_list_precheck_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 75_000);

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, bytes32(0));
    }

    function testConstructorRejectsProviderGasAboveFrozenMaximum() public {
        vm.expectRevert();
        new UsdyRestrictedAdapter(
            DVP,
            address(TOKEN),
            address(TOKEN).codehash,
            address(BLOCKLIST),
            address(BLOCKLIST).codehash,
            address(ALLOWLIST),
            address(ALLOWLIST).codehash,
            address(SANCTIONS),
            address(SANCTIONS).codehash,
            PROVIDER_CALL_GAS + 1
        );
    }

    function testPausedTokenBlocks() public {
        TOKEN.setPaused(true);

        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheck();

        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 10);
        assertEq(reasonHash, 0x59306319ea0e72f9a3d2e2a1ff908f8cf3212877967e293f073564a10bc4407d);
    }

    function testRestrictedFromAddressBlocksForEachList() public {
        BLOCKLIST.setBlocked(FROM, true);
        _assertBlock(11, 0x0e31dc34f1a2fa86619db4728da0013c8e95d02052650836e2d635ebfb99d8d7);
        BLOCKLIST.setBlocked(FROM, false);

        ALLOWLIST.setAllowed(FROM, false);
        _assertBlock(12, 0x77a84e8f5034912d93284140b63aa1895064678c51606830acede5a46d848fea);
        ALLOWLIST.setAllowed(FROM, true);

        SANCTIONS.setSanctioned(FROM, true);
        _assertBlock(13, 0x1c3f68e105df554212e4e8824c0f71ccee8a3b8dd93cc219f3e03e63b99af2e7);
    }

    function testRestrictedToAddressBlocksForEachList() public {
        BLOCKLIST.setBlocked(TO, true);
        _assertBlock(14, 0xd9f554e314f8727efdb6a98b5dec83679b9e3639cf4bca078205aad760106e49);
        BLOCKLIST.setBlocked(TO, false);

        ALLOWLIST.setAllowed(TO, false);
        _assertBlock(15, 0x8fcc5d4356383bfe0cf57bd8cb45a1f50112ed52d55e09bd55195fd603bdf555);
        ALLOWLIST.setAllowed(TO, true);

        SANCTIONS.setSanctioned(TO, true);
        _assertBlock(16, 0x348e9171ab0aae63087695f14023d465ff6a613437bb5080292df80e692b5782);
    }

    function testRestrictedDvpOperatorBlocksForEachList() public {
        BLOCKLIST.setBlocked(DVP, true);
        _assertBlock(17, 0xcaa09a22b0aa8a19b8f1a68ce2be381cf0f2651e04cede1ae921aae4d5be5aa2);
        BLOCKLIST.setBlocked(DVP, false);

        ALLOWLIST.setAllowed(DVP, false);
        _assertBlock(18, 0x187c86f9c335cf15f1d6eed9355127050ea1843afbc131250df6f4784f78c03d);
        ALLOWLIST.setAllowed(DVP, true);

        SANCTIONS.setSanctioned(DVP, true);
        _assertBlock(19, 0x3ce26ed8a9bcd745c6e85d7b6c66405171c278eaed6c25375987c2304713c347);
    }

    function testProviderAddressDriftIsUnknown() public {
        bytes32 approvedProviderHash = ADAPTER.providerHash();
        AddressListMock replacement = new AddressListMock();

        TOKEN.configure(address(replacement), address(ALLOWLIST), address(SANCTIONS));
        _assertUnknown(0x84fde0ed59f13bfbb0dff3267695d56b2b91c7f0c0debdbb46edc492fcbceeb2);

        TOKEN.configure(address(BLOCKLIST), address(replacement), address(SANCTIONS));
        _assertUnknown(0x84fde0ed59f13bfbb0dff3267695d56b2b91c7f0c0debdbb46edc492fcbceeb2);

        TOKEN.configure(address(BLOCKLIST), address(ALLOWLIST), address(replacement));
        _assertUnknown(0x84fde0ed59f13bfbb0dff3267695d56b2b91c7f0c0debdbb46edc492fcbceeb2);

        assertEq(ADAPTER.providerHash(), approvedProviderHash);
    }

    function testMalformedGetterAndProviderResponsesAreUnknown() public {
        bytes32 externalFailure = 0xdf9637626ed477c6d3f67c818f15cc3e8040e5097cf04e32194bb20ce9b25da3;
        bytes memory pausedCall = abi.encodeCall(IUsdyRestrictionToken.paused, ());

        vm.mockCallRevert(address(TOKEN), pausedCall, hex"dead");
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(TOKEN), pausedCall, hex"00");
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(TOKEN), pausedCall, bytes.concat(abi.encode(false), hex"00"));
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(TOKEN), pausedCall, abi.encode(uint256(2)));
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        bytes memory blockedCall = abi.encodeCall(IBlocklist.isBlocked, (FROM));
        vm.mockCallRevert(address(BLOCKLIST), blockedCall, hex"dead");
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(BLOCKLIST), blockedCall, hex"00");
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(BLOCKLIST), blockedCall, bytes.concat(abi.encode(false), hex"00"));
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.mockCall(address(BLOCKLIST), blockedCall, abi.encode(uint256(2)));
        _assertUnknown(externalFailure);
        vm.clearMockedCalls();

        vm.etch(address(BLOCKLIST), hex"");
        _assertUnknown(0x84fde0ed59f13bfbb0dff3267695d56b2b91c7f0c0debdbb46edc492fcbceeb2);
    }

    function testCapabilitiesDeclareOnlyTokenSpecificErc20AssetChecks() public view {
        AdapterCapabilities memory capabilities = ADAPTER.capabilities();
        assertEq(ADAPTER.interfaceVersion(), InterfaceVersions.ASSET_ADAPTER_V1);
        assertEq(uint8(capabilities.tokenStandard), uint8(TokenStandard.ERC20));
        assertEq(uint8(capabilities.restrictionMode), uint8(RestrictionMode.TOKEN_ENFORCED));
        assertEq(uint8(capabilities.precheckMethod), uint8(PrecheckMethod.TOKEN_SPECIFIC_CHECK));
        assertEq(capabilities.transferLegMask, uint256(1) << uint8(TransferLeg.ASSET));
        assertEq(ADAPTER.capabilityHash(), 0x63df51d7ce7afbc051e26124274639b57b65a7c685c4f186fda9027d53ca630d);
        assertEq(ADAPTER.providerHash(), 0xcdcb1705ba98354a6440eb361a1bb138e943092c87e03a12e05d9e39cb41397f);
    }

    function testUnapprovedCallerIsRejectedBeforeProviderCalls() public view {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 2);
        assertEq(reasonHash, 0x6c8c48159f980e0cadca17cca18015ebceeb2b47fb10c4d81793e40a563929c1);
    }

    function _assertBlock(uint256 expectedCode, bytes32 expectedReason) private {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheck();
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, expectedCode);
        assertEq(reasonHash, expectedReason);
    }

    function _assertUnknown(bytes32 expectedReason) private {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = _preCheck();
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, expectedReason);
    }

    function _preCheck() private returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash) {
        vm.prank(DVP);
        return ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, TransferLeg.ASSET, bytes32(uint256(0x4000)));
    }
}
