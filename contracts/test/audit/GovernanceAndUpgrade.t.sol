// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT — Module C (Registry / UUPS / access control).
// Delete after the audit. Does not modify any src/ or pre-existing test file.

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "src/libraries/Roles.sol";
import {UUPSRegistryBase} from "src/registry/UUPSRegistryBase.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {MarketRuleRegistry} from "src/registry/MarketRuleRegistry.sol";
import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    ParticipantInput,
    ParticipantType,
    ReasonCode,
    ScopeType,
    SettlementTokenConfig,
    SettlementTokenRecord,
    SettlementTokenStatus
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract TmpAuditHarness is UUPSRegistryBase {
    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function implementationVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract TmpAuditHarnessV2 is TmpAuditHarness {
    function implementationVersion() external pure override returns (uint256) {
        return 2;
    }
}

// A perfectly ordinary contract that happens NOT to implement IDvPGovernanceView.
// Stands in for "governance pasted the wrong address" (a token, a registry, an old DvP).
contract TmpNotADvp {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

// Created and destroyed inside one transaction: post-EIP-6780 the account is deleted.
contract TmpKamikaze {
    function globalPaused() external pure returns (bool) {
        return true;
    }

    function retired() external pure returns (bool) {
        return true;
    }

    function destroy() external {
        selfdestruct(payable(msg.sender));
    }
}

contract TmpAuditUpgradeGateTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);
    bytes32 internal constant EVIDENCE = bytes32(uint256(0xE1));

    TmpAuditHarness internal registry;

    function setUp() public override {
        super.setUp();
        registry = _deployRegistry();
    }

    // 修复后：接口不完整的地址在登记入口就被拒，污染不了只增不删的集合。
    // 原缺陷是 registerDependentDvp 只查 code.length，一次填错即永久废掉升级路径。
    function testMisregisteredDependentIsRejectedAtRegistration() public {
        TmpNotADvp wrongAddress = new TmpNotADvp();

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, address(wrongAddress)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(wrongAddress), EVIDENCE);
        assertEq(registry.getDependentDvpCount(), 0);

        // 集合未被污染，正常的登记与升级路径完好。
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), bytes32(uint256(0xE2)));

        TmpAuditHarnessV2 next = new TmpAuditHarnessV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), bytes(""));
        assertEq(registry.implementationVersion(), 2);
    }

    // 修复后变体：登记入口同时读 retired()，同一交易内自毁这类地址也进不来。
    function testSelfDestructingDependentIsRejectedAtRegistration() public {
        TmpKamikaze kamikaze = new TmpKamikaze();

        // 其 fallback 对两个 selector 都返回 1，因此先被 retired() == true 拦下。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpRetired.selector, address(kamikaze)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(kamikaze), EVIDENCE);
        assertEq(registry.getDependentDvpCount(), 0);
    }

    // C-02: the gate is vacuous while the dependent set is empty; nothing on-chain forces it to be filled.
    // 修复后：空依赖集合被读作「尚未登记」而非「无依赖」，升级 fail-closed。
    function testEmptyDependentSetBlocksUpgradeUntilRegistered() public {
        assertEq(registry.getDependentDvpCount(), 0);
        assertFalse(dependentDvp.globalPaused());

        TmpAuditHarnessV2 next = new TmpAuditHarnessV2();
        vm.expectRevert(HTPErrors.NoDependentDvpRegistered.selector);
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), bytes(""));
        assertEq(registry.implementationVersion(), 1);
    }

    // 修复后（C-05）：唯一的 DEFAULT_ADMIN 不能自弃，角色管理不会被冻结。
    function testSoleDefaultAdminCannotRenounceAndRoleAdministrationStaysOpen() public {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        vm.prank(address(timelock));
        registry.grantRole(Roles.PAUSER_ROLE, address(0xBEEF));
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, address(0xBEEF)));
    }

    // Verification (no finding): every implementation contract is initializer-locked and
    // upgradeToAndCall is onlyProxy, so the classic "own the logic contract" path is closed.
    function testEveryRegistryImplementationIsInitializerLockedAndNotUpgradeableDirectly() public {
        address[8] memory implementations = [
            address(new ParticipantRegistry()),
            address(new EligibilityRegistry()),
            address(new AdapterRegistry()),
            address(new PrincipalCalculatorRegistry()),
            address(new SettlementTokenRegistry()),
            address(new AssetVersionRegistry()),
            address(new MarketRuleRegistry()),
            address(new FeeRegistry())
        ];
        TmpAuditHarnessV2 next = new TmpAuditHarnessV2();
        for (uint256 i = 0; i < implementations.length; ++i) {
            (bool initialized,) = implementations[i].call(
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,address)",
                    address(this),
                    address(this),
                    address(this),
                    address(this),
                    address(this)
                )
            );
            assertFalse(initialized, "implementation accepted initialize()");

            (bool upgraded,) = implementations[i].call(
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(next), bytes(""))
            );
            assertFalse(upgraded, "implementation accepted a direct upgradeToAndCall()");
        }
    }

    // Verification (no finding): OZ blocks bricking the proxy with a non-UUPS implementation.
    function testUpgradeToNonUupsImplementationIsRejected() public {
        // 升级门禁现在要求依赖集合非空，这里先满足它，才能测到 UUPS 校验本身。
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE);

        TmpNotADvp notUups = new TmpNotADvp();
        vm.expectRevert();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(notUups), bytes(""));

        TmpAuditHarnessV2 next = new TmpAuditHarnessV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), bytes(""));
        assertEq(registry.implementationVersion(), 2);
    }

    function _deployRegistry() private returns (TmpAuditHarness) {
        TmpAuditHarness implementation = new TmpAuditHarness();
        return TmpAuditHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(TmpAuditHarness.initialize, (address(timelock), PAUSER, CONFIGURER))
            )
        );
    }
}

contract TmpAuditParticipantTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);
    address internal constant WALLET = address(0x7001);
    bytes32 internal constant EVIDENCE = bytes32(uint256(0xE1));

    ParticipantRegistry internal participants;

    function setUp() public override {
        super.setUp();
        ParticipantRegistry implementation = new ParticipantRegistry();
        participants = ParticipantRegistry(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    ParticipantRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        vm.prank(CONFIGURER);
        participants.setParticipant(
            ParticipantInput({
                wallet: WALLET,
                participantIdHash: bytes32(uint256(0x1D)),
                participantType: ParticipantType.INVESTOR,
                validUntil: uint64(block.timestamp + 365 days),
                evidenceHash: EVIDENCE
            }),
            0
        );
        assertTrue(participants.isParticipantActive(WALLET, ParticipantType.INVESTOR));
    }

    // 修复后（C-07）：不可逆的销毁原语不再握在 CONFIGURER 手里。撤销本身仍然
    // 是终态、仍然无法恢复——那是设计意图；变的是谁有权按下它。判据是可逆性：
    // CONFIGURER 负责能改回来的登记与更新，只有 GOVERNANCE 能做不可回退的动作。
    function testOnlyGovernanceCanIrreversiblyRevokeAParticipant() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, CONFIGURER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(CONFIGURER);
        participants.revokeParticipant(WALLET, 1, EVIDENCE);
        assertTrue(participants.isParticipantActive(WALLET, ParticipantType.INVESTOR));

        vm.prank(address(timelock));
        participants.revokeParticipant(WALLET, 1, EVIDENCE);
        assertFalse(participants.isParticipantActive(WALLET, ParticipantType.INVESTOR));

        // 终态性不变：撤销之后连治理自己也恢复不了，只能换新钱包。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantPermanentlyRevoked.selector, WALLET));
        vm.prank(address(timelock));
        participants.unpauseParticipant(WALLET, 2, ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantPermanentlyRevoked.selector, WALLET));
        vm.prank(CONFIGURER);
        participants.setParticipant(
            ParticipantInput({
                wallet: WALLET,
                participantIdHash: bytes32(uint256(0x1D)),
                participantType: ParticipantType.INVESTOR,
                validUntil: uint64(block.timestamp + 365 days),
                evidenceHash: EVIDENCE
            }),
            2
        );
    }

    // C-08: CONFIGURER can also silently expire an active participant one second into the future.
    function testConfigurerCanShrinkValidityToTheNextSecond() public {
        vm.prank(CONFIGURER);
        participants.setParticipant(
            ParticipantInput({
                wallet: WALLET,
                participantIdHash: bytes32(uint256(0x1D)),
                participantType: ParticipantType.INVESTOR,
                validUntil: uint64(block.timestamp + 1),
                evidenceHash: EVIDENCE
            }),
            1
        );
        assertTrue(participants.isParticipantActive(WALLET, ParticipantType.INVESTOR));
        vm.warp(block.timestamp + 1);
        assertFalse(participants.isParticipantActive(WALLET, ParticipantType.INVESTOR));
    }
}

contract TmpAuditFeeStateMachineTest is FeeRegistryTestBase {
    // C-03 回归：CONFIGURER 登记的高优先级候选不能改变 Governance 已提交的服务指针。
    function testConfigurerCannotFreezeFeeResolutionWithNeverActivatedVersion() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);

        FeeConfig memory globalFee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(globalFee);

        // The rogue entry only needs the CONFIGURER role and a higher-priority scope.
        FeeConfig memory rogue =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(rogue);

        _sealEpoch(epoch);

        // Governance activates the fee version it knows about, then the epoch.
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(globalFee.feeVersionId, globalFee.configHash);
        _activateEpoch(epoch);

        // Resolver 只读 serving；未激活的高优先级候选不会遮挡 GLOBAL。
        (bytes32 resolvedId, bytes32 resolvedScope) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        assertEq(resolvedId, globalFee.feeVersionId);
        assertEq(resolvedScope, globalFee.matchedScopeHash);
        assertEq(uint8(feeRegistry.getFeeVersion(rogue.feeVersionId).status), uint8(FeeVersionStatus.REGISTERED));

        // Governance 已批准的 GLOBAL 可执行，rogue 仍不可执行。
        assertTrue(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                globalFee.feeVersionId,
                globalFee.matchedScopeHash,
                globalFee.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                rogue.feeVersionId,
                rogue.matchedScopeHash,
                rogue.feeConstraintHash
            )
        );

        // Registration remains frozen after seal.
        FeeConfig memory repair =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 2, rogue.feeVersionId);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochSealed.selector, uint64(1)));
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(repair);

        // Epoch ACTIVE 后不能再把遗漏候选切入 serving。
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

    // 修复后（C-04）：PAUSED 不再是 DEPRECATED 的入边。这条边原先能把「先暂停、
    // 再废弃」这套标准应急动作变成一次不可逆的**放权**——DEPRECATED 可结算而
    // PAUSED 不可，且 pauseFeeVersion 只收 ACTIVE，废弃之后再也停不回来。
    function testAPausedFeeVersionCannotBeDeprecatedIntoExecutabilityAgain() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory fee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(fee.feeVersionId, fee.configHash);
        _activateEpoch(epoch);

        assertTrue(_executable(fee));

        // PAUSER stops it.
        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(fee.feeVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertFalse(_executable(fee));

        // 「继续往生命周期下游走」不再是逃逸口。
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.UnauthorizedStateTransition.selector,
                fee.feeVersionId,
                uint8(FeeVersionStatus.PAUSED),
                uint8(FeeVersionStatus.DEPRECATED)
            )
        );
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(fee.feeVersionId, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);

        // 暂停是吸收点：状态没变，仍然不可结算，且仍可被治理恢复。
        assertEq(uint8(feeRegistry.getFeeVersion(fee.feeVersionId).status), uint8(FeeVersionStatus.PAUSED));
        assertFalse(_executable(fee));

        // 要永久退役，先恢复成 ACTIVE 再废弃——这条路径依然通。
        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(fee.feeVersionId, fee.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(fee.feeVersionId, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(uint8(feeRegistry.getFeeVersion(fee.feeVersionId).status), uint8(FeeVersionStatus.DEPRECATED));
    }

    // C-06: activating revision N+1 leaves revision N fully ACTIVE and settleable.
    function testActivatingNextRevisionLeavesPreviousRevisionActive() public {
        SettlementTokenConfig memory v2 = settlementTokenConfig;
        v2.revision = 2;
        v2.configId = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            1,
            block.chainid,
            bytes32(uint256(uint160(address(settlementToken)))),
            2
        );
        v2.replacesConfigId = settlementTokenConfig.configId;
        v2.configHash = HTPHashing.hashSettlementTokenConfig(v2);

        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(v2);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(v2.configId, v2.configHash);

        SettlementTokenRecord memory oldRecord =
            settlementTokenRegistry.getSettlementToken(settlementTokenConfig.configId);
        assertEq(uint8(oldRecord.status), uint8(SettlementTokenStatus.ACTIVE));
        assertTrue(
            settlementTokenRegistry.isSettlementTokenConfigActive(
                settlementTokenConfig.configId, settlementTokenConfig.configHash
            )
        );
        assertEq(
            settlementTokenRegistry.getCurrentSettlementToken(address(settlementToken)).config.configId, v2.configId
        );
    }

    function _executable(FeeConfig memory fee) private view returns (bool) {
        return feeRegistry.isFeeVersionExecutable(
            1, assetVersionConfig.assetVersionId, fee.feeVersionId, fee.matchedScopeHash, fee.feeConstraintHash
        );
    }
}
