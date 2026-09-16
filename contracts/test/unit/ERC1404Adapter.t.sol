// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1404Adapter} from "src/adapters/ERC1404Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ERC1404TokenMock, GasFloorERC1404Token, MalformedERC1404Token} from "test/fixtures/AdapterMocks.sol";
import {ConfigurablePermissiveERC1404Token, PermissiveFallbackERC1404Token} from "test/fixtures/Erc1404ProbeMocks.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";

contract ERC1404AdapterTest is Test {
    address private constant DVP = address(0xD0);
    uint256 private constant PROVIDER_CALL_GAS = 100_000;
    // bytes4(keccak256("htpErc1404InterfaceProbe(address,address,uint256)"))
    bytes4 private constant PROBE_SELECTOR = 0xb9b484bb;
    // keccak256("HTP_ADAPTER_PROVIDER_INTERFACE_MISSING")
    bytes32 private constant PROVIDER_INTERFACE_MISSING_REASON =
        0x600ca0935cbb6b23aa9a019cb7f1db5c158c798ee0add38e1965e5d306e05259;

    ERC1404TokenMock private immutable TOKEN = new ERC1404TokenMock();
    IAssetAdapter private immutable ADAPTER =
        IAssetAdapter(address(new ERC1404Adapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS)));

    function testRestrictionCodeZeroPasses() public {
        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = ADAPTER.preCheck(
            address(TOKEN), address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, bytes32(0));
    }

    function testCapabilitiesAndProviderHashMatchReviewedRules() public view {
        AdapterCapabilities memory capabilities = ADAPTER.capabilities();
        assertEq(ADAPTER.interfaceVersion(), InterfaceVersions.ASSET_ADAPTER_V1);
        assertEq(uint8(capabilities.tokenStandard), uint8(TokenStandard.ERC1404));
        assertEq(uint8(capabilities.restrictionMode), uint8(RestrictionMode.ISSUER_EXTERNAL));
        assertEq(uint8(capabilities.precheckMethod), uint8(PrecheckMethod.ERC1404_CHECK));
        assertEq(capabilities.transferLegMask, uint256(1) << uint8(TransferLeg.ASSET));
        assertEq(ADAPTER.capabilityHash(), 0x9f60c45a35f62e4ae67cc291a084d835e7648456864f8656efee66677d9ee54d);

        assertEq(ADAPTER.providerHash(), 0xbc01a7448a629e6d525062e67c0b769b358ab9983b94d147057f22a41df1d1df);
    }

    function testNonzeroRestrictionCodeBlocksWithDeterministicReason() public {
        TOKEN.setRestrictionCode(7);

        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = ADAPTER.preCheck(
            address(TOKEN), address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );

        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 7);
        assertEq(reasonHash, 0x57aac7c707fadeb6fede18f26a42604d403344897f892188de0e15d6f5fb4774);
    }

    function testExternalFailuresAndMalformedReturnsAreUnknown() public {
        MalformedERC1404Token malformed = new MalformedERC1404Token();
        IAssetAdapter adapter = IAssetAdapter(
            address(new ERC1404Adapter(DVP, address(malformed), address(malformed).codehash, PROVIDER_CALL_GAS))
        );

        malformed.configure(MalformedERC1404Token.Mode.REVERT_CALL, 0);
        _assertUnknown(adapter, address(malformed));
        malformed.configure(MalformedERC1404Token.Mode.SHORT_RETURN, 0);
        _assertUnknown(adapter, address(malformed));
        malformed.configure(MalformedERC1404Token.Mode.LONG_RETURN, 0);
        _assertUnknown(adapter, address(malformed));
        malformed.configure(MalformedERC1404Token.Mode.NORMAL, 256);
        _assertUnknown(adapter, address(malformed));
        malformed.configure(MalformedERC1404Token.Mode.EXHAUST_GAS, 0);
        _assertUnknown(adapter, address(malformed));

        address noCode = address(0xBEEF);
        IAssetAdapter noCodeAdapter =
            IAssetAdapter(address(new ERC1404Adapter(DVP, noCode, noCode.codehash, PROVIDER_CALL_GAS)));
        _assertUnknown(noCodeAdapter, noCode);
    }

    function testUnapprovedCallerIsRejectedBeforeTokenCall() public view {
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = ADAPTER.preCheck(
            address(TOKEN), address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 2);
        assertEq(reasonHash, 0x6c8c48159f980e0cadca17cca18015ebceeb2b47fb10c4d81793e40a563929c1);
    }

    function testConfiguredGasCapPassesBelowAndFailsClosedAtOrAboveBoundary() public {
        GasFloorERC1404Token gasFloorToken = new GasFloorERC1404Token();
        IAssetAdapter adapter = IAssetAdapter(
            address(new ERC1404Adapter(DVP, address(gasFloorToken), address(gasFloorToken).codehash, PROVIDER_CALL_GAS))
        );

        gasFloorToken.setMinimumGas(90_000);
        vm.prank(DVP);
        (Decision belowCap,,) = adapter.preCheck(
            address(gasFloorToken), address(0x2000), address(0x3000), 1, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );
        assertEq(uint8(belowCap), uint8(Decision.PASS));

        gasFloorToken.setMinimumGas(PROVIDER_CALL_GAS);
        _assertUnknown(adapter, address(gasFloorToken));
        gasFloorToken.setMinimumGas(PROVIDER_CALL_GAS + 1);
        _assertUnknown(adapter, address(gasFloorToken));
    }

    function testConstructorRejectsProviderGasAboveFrozenMaximum() public {
        vm.expectRevert();
        new ERC1404Adapter(DVP, address(TOKEN), address(TOKEN).codehash, PROVIDER_CALL_GAS + 1);
    }

    // M-06 回归：没有 detectTransferRestriction、靠 fallback 回 32 字节零的 Token
    // 曾经能拿到假 PASS。现在 Adapter 根本部署不到它上面。
    function testConstructorRejectsTokenWithPermissiveFallback() public {
        PermissiveFallbackERC1404Token fake = new PermissiveFallbackERC1404Token();

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AdapterProviderInterfaceMissing.selector, address(fake), PROBE_SELECTOR)
        );
        new ERC1404Adapter(DVP, address(fake), address(fake).codehash, PROVIDER_CALL_GAS);
    }

    // M-06 回归的另一半：构造期干净、事后才变宽容的 Token（代理换实现的形状，
    // codehash 全程不变所以躲得过 codeHash 分支）在运行期被哨兵探测拦下。
    function testTokenTurningPermissiveAfterDeploymentIsUnknown() public {
        ConfigurablePermissiveERC1404Token token = new ConfigurablePermissiveERC1404Token();
        IAssetAdapter adapter =
            IAssetAdapter(address(new ERC1404Adapter(DVP, address(token), address(token).codehash, PROVIDER_CALL_GAS)));
        bytes32 pinnedCodeHash = address(token).codehash;

        vm.prank(DVP);
        (Decision clean,,) = adapter.preCheck(
            address(token), address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );
        assertEq(uint8(clean), uint8(Decision.PASS));

        token.setPermissive(true);
        assertEq(
            address(token).codehash,
            pinnedCodeHash,
            unicode"翻开关不应改变 runtime，否则测的是 codeHash 分支"
        );

        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = adapter.preCheck(
            address(token), address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, PROVIDER_INTERFACE_MISSING_REASON);
    }

    // 哨兵探测不能把「Token 还没部署」这条既有的 fail-closed 路径压成部署期失败：
    // 无代码地址仍要能构造，并在 preCheck 里照常返回 UNKNOWN。
    function testNoCodeTokenStillConstructsAndFailsClosedAtPreCheck() public {
        address noCode = address(0xBEEF);
        IAssetAdapter adapter =
            IAssetAdapter(address(new ERC1404Adapter(DVP, noCode, noCode.codehash, PROVIDER_CALL_GAS)));
        _assertUnknown(adapter, noCode);
    }

    function _assertUnknown(IAssetAdapter adapter, address token) private {
        vm.prank(DVP);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) = adapter.preCheck(
            token, address(0x2000), address(0x3000), 25 ether, TransferLeg.ASSET, bytes32(uint256(0x4000))
        );
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, 0xdf9637626ed477c6d3f67c818f15cc3e8040e5097cf04e32194bb20ce9b25da3);
    }
}
