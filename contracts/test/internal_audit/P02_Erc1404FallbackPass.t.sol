// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1404Adapter} from "src/adapters/ERC1404Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, TransferLeg} from "src/types/HTPTypes.sol";
import {ConfigurablePermissiveERC1404Token, PermissiveFallbackERC1404Token} from "test/fixtures/Erc1404ProbeMocks.sol";

/*
 * P02：ERC-1404 宽容 fallback 可得假 PASS —— 已修复，断言已反转
 *
 * 原缺陷：
 * - AdapterRegistry 登记时不探测 Token 是否真实实现 `detectTransferRestriction`
 * - `ERC1404Adapter.preCheck` 对任意成功返回的 32 字节值，只要 `≤ uint8.max` 且等于 0，就判 PASS
 * - 无该选择器、仅靠 fallback 回 `uint256(0)` 的 Token，会被当成「发行方已放行」
 * - 后果：预检绿灯具有误导性；后续结算资产腿仍走标准 `transferFrom`，不再经过 ERC-1404 限制语义
 *
 * 修复：
 * - `ERC1404Adapter` 用一个真 Token 不可能实现的哨兵 selector 再问一次；对方连它也回
 *   32 字节字，就说明没有可信的 ERC-1404 限制面
 * - 构造期命中即 revert `AdapterProviderInterfaceMissing`，伪 Token 上根本部署不出 Adapter
 * - 运行期在主调用之前再探一次，覆盖代理型 Token 登记后被换实现的情形，判 UNKNOWN
 *
 * 射程之外（仍靠治理登记的尽调）：
 * 一个实现了 `detectTransferRestriction`、只对该 selector 撒谎回 0、对其他 selector 干净
 * revert 的 Token，在链上与真实 ERC-1404 完全不可区分。
 */
contract P02_Erc1404FallbackPassTest is Test {
    bytes32 private constant CONTEXT = bytes32(uint256(0xC0));
    // bytes4(keccak256("htpErc1404InterfaceProbe(address,address,uint256)"))
    bytes4 private constant PROBE_SELECTOR = 0xb9b484bb;
    // keccak256("HTP_ADAPTER_PROVIDER_INTERFACE_MISSING")
    bytes32 private constant PROVIDER_INTERFACE_MISSING_REASON =
        0x600ca0935cbb6b23aa9a019cb7f1db5c158c798ee0add38e1965e5d306e05259;

    /// @notice 原 PoC 反转：无 ERC-1404 表面的 Token 上已经部署不出 Adapter
    function test_fallbackZeroTokenIsRejectedAtAdapterConstruction() public {
        // 1) 部署无限制选择器、fallback 恒回 0 的伪 Token
        PermissiveFallbackERC1404Token token = new PermissiveFallbackERC1404Token();
        address fakeDvp = address(0xD0D0);

        // 2) 构造期哨兵探测命中，整条「伪 Token → 登记 → 激活 → 假 PASS」的链路在第一步断掉
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AdapterProviderInterfaceMissing.selector, address(token), PROBE_SELECTOR)
        );
        new ERC1404Adapter(fakeDvp, address(token), address(token).codehash, 50_000);
    }

    /// @notice 构造期躲过去的那一半：Token 事后才变宽容（代理换实现的形状），预检判 UNKNOWN
    function test_tokenTurningPermissiveAfterRegistrationIsUnknownNotPass() public {
        ConfigurablePermissiveERC1404Token token = new ConfigurablePermissiveERC1404Token();
        address fakeDvp = address(0xD0D0);
        IAssetAdapter adapter =
            IAssetAdapter(address(new ERC1404Adapter(fakeDvp, address(token), address(token).codehash, 50_000)));
        bytes32 pinnedCodeHash = address(token).codehash;

        // 翻开关不改 runtime，codehash 分支拦不住，只能靠哨兵探测
        token.setPermissive(true);
        assertEq(address(token).codehash, pinnedCodeHash);

        vm.prank(fakeDvp);
        (Decision decision, uint256 restrictionCode, bytes32 reasonHash) =
            adapter.preCheck(address(token), address(0x2000), address(0x3000), 1 ether, TransferLeg.ASSET, CONTEXT);

        assertEq(
            uint8(decision),
            uint8(Decision.UNKNOWN),
            unicode"无 ERC-1404 表面的 Token 不应被当成已过限制检查"
        );
        assertEq(restrictionCode, 0);
        assertEq(reasonHash, PROVIDER_INTERFACE_MISSING_REASON);
    }
}
