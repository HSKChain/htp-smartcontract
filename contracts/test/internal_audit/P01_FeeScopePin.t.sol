// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

/*
 * P01 回归：
 * - register 只推进 latest-registered 修订链，不改变 serving 指针
 * - activateFeeVersion 才能由 Governance 推进 serving 指针
 * - resolver 只按 scope 优先级读取 serving，不会命中 REGISTERED
 *
 * 原攻击路径：
 * registerFee(global) → registerFee(rogue) → seal → activate(global)+activate(epoch)
 * 修复后 resolve 仍命中 global；Epoch ACTIVE 后也不能再把遗漏的 rogue 切入 serving。
 */
contract P01_FeeScopePinTest is FeeRegistryTestBase {
    /// @notice 更高优先级 REGISTERED 不得遮挡 Governance 已激活的 GLOBAL
    function test_registeredHigherScopeCannotPinActivatedGlobalResolution() public {
        // 1) 打开未封存 Fee Epoch
        FeePolicyEpochConfig memory epoch = _createEpoch(1);

        // 2) Configurer 先登记合法低优先级 GLOBAL
        FeeConfig memory globalFee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(globalFee);

        // 3) 同 Epoch 内再登记更高优先级 ASSET_VERSION；它只进入登记链，状态为 REGISTERED
        FeeConfig memory rogue =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(rogue);

        // 4) Governance 按「已知版本」封存，并只激活 GLOBAL + Epoch（未激活 rogue）
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(globalFee.feeVersionId, globalFee.configHash);
        _activateEpoch(epoch, globalFee.feeVersionId);

        // 5) rogue 没有 serving 指针，解析继续回落并命中已激活的 GLOBAL
        (bytes32 resolvedId, bytes32 resolvedScope) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        assertEq(resolvedId, globalFee.feeVersionId, unicode"REGISTERED 高优先级版本不得改变解析");
        assertEq(resolvedScope, globalFee.matchedScopeHash);
        assertEq(uint8(feeRegistry.getFeeVersion(rogue.feeVersionId).status), uint8(FeeVersionStatus.REGISTERED));

        // 6) 合法 GLOBAL 可执行，rogue 自身仍不可执行
        assertTrue(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                globalFee.feeVersionId,
                globalFee.matchedScopeHash,
                globalFee.feeConstraintHash
            ),
            unicode"已激活 GLOBAL 应继续服务该资产"
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                rogue.feeVersionId,
                rogue.matchedScopeHash,
                rogue.feeConstraintHash
            ),
            unicode"REGISTERED rogue 不得执行"
        );

        // 7) 封存后仍无法再登记同 scope 版本
        FeeConfig memory repair =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 2, rogue.feeVersionId);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochSealed.selector, uint64(1)));
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(repair);

        // 8) Epoch 已 ACTIVE 后也不能把遗漏的 rogue 切入 serving
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.UnauthorizedStateTransition.selector,
                rogue.feeVersionId,
                uint8(FeePolicyEpochStatus.ACTIVE),
                uint8(FeePolicyEpochStatus.DRAFT)
            )
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(rogue.feeVersionId, rogue.configHash);
        assertEq(uint8(feeRegistry.getFeeVersion(rogue.feeVersionId).status), uint8(FeeVersionStatus.REGISTERED));
    }

    /// @notice N1: 只有 REGISTERED、没有 ACTIVE serving 时，Epoch 不能激活
    function test_registeredVersionCannotMakeEpochActive() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory globalFee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(globalFee);
        _sealEpoch(epoch);

        vm.warp(epoch.quoteValidFrom);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeePolicyEpochFeeNotReady.selector, uint64(1), globalFee.feeVersionId)
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(1, epoch.configHash, globalFee.feeVersionId);

        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.DRAFT));
        assertEq(uint8(feeRegistry.getFeeVersion(globalFee.feeVersionId).status), uint8(FeeVersionStatus.REGISTERED));
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                globalFee.feeVersionId,
                globalFee.matchedScopeHash,
                globalFee.feeConstraintHash
            ),
            unicode"REGISTERED 版本不得执行"
        );
    }
}
