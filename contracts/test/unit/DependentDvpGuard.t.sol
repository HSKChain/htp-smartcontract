// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {
    GasBombDvPGovernanceView,
    LongReturnDvPGovernanceView,
    NonCanonicalBoolDvPGovernanceView,
    RetiredOnlyDvPGovernanceView,
    RevertingDvPGovernanceView,
    ShortReturnDvPGovernanceView
} from "../fixtures/MalformedDvPGovernanceViews.sol";
import {MockDvP} from "../fixtures/MockDvP.sol";
import {RegistryTestBase} from "../helpers/RegistryTestBase.sol";

contract DependentDvpRegistryHarness is UUPSRegistryBase {
    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function implementationVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract DependentDvpRegistryHarnessV2 is DependentDvpRegistryHarness {
    function implementationVersion() external pure override returns (uint256) {
        return 2;
    }
}

contract DependentDvpGuardTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE1));
    bytes32 internal constant DEPENDENT_DVP_REGISTERED_TOPIC =
        0x9ac7fdd43f547f43c6f6abcc66e02cf4da63194b1c98ef48a7065b7d03ba74aa;
    bytes32 internal constant DEPENDENT_DVP_RETIRED_EXEMPTED_TOPIC =
        0xadf89ce9a4d219c14de12d19ebdcff85702f5a3f5ed8e425ee2651fa93b226c5;

    DependentDvpRegistryHarness internal registry;

    function setUp() public override {
        super.setUp();
        DependentDvpRegistryHarness implementation = new DependentDvpRegistryHarness();
        registry = DependentDvpRegistryHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(DependentDvpRegistryHarness.initialize, (address(timelock), PAUSER, CONFIGURER))
            )
        );
    }

    function testGovernanceAppendsDependentDvpAndEmitsAuditEvent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, CONFIGURER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(CONFIGURER);
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertDependentDvpEvent(logs[0], DEPENDENT_DVP_REGISTERED_TOPIC, EVIDENCE_HASH);

        assertEq(registry.getDependentDvpCount(), 1);
        (address storedDvp, bool retiredExempt) = registry.getDependentDvp(0);
        assertEq(storedDvp, address(dependentDvp));
        assertFalse(retiredExempt);
    }

    function testGovernanceCanIrreversiblyExemptStrictlyRetiredDependentDvp() public {
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        dependentDvp.setRetired(true);

        bytes32 retirementEvidence = bytes32(uint256(0xE2));
        vm.recordLogs();
        vm.prank(address(timelock));
        registry.exemptRetiredDependentDvp(address(dependentDvp), retirementEvidence);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertDependentDvpEvent(logs[0], DEPENDENT_DVP_RETIRED_EXEMPTED_TOPIC, retirementEvidence);

        (address storedDvp, bool retiredExempt) = registry.getDependentDvp(0);
        assertEq(storedDvp, address(dependentDvp));
        assertTrue(retiredExempt);
        assertEq(registry.getDependentDvpCount(), 1);
    }

    function testUpgradeRequiresEveryNonExemptDependentDvpToBeGloballyPaused() public {
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpNotPaused.selector, address(dependentDvp)));
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        assertEq(registry.implementationVersion(), 2);
    }

    function testRetiredExemptionRejectsFalseStatus() public {
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpNotRetired.selector, address(dependentDvp)));
        vm.prank(address(timelock));
        registry.exemptRetiredDependentDvp(address(dependentDvp), bytes32(uint256(0xE2)));
    }

    // 登记入口已挡住畸形应答，因此这里模拟「登记时正常、事后 runtime 漂移」，
    // 保留对豁免通道 fail-closed 分支的覆盖。
    function testRetiredExemptionRejectsMalformedStatusAfterRuntimeDrift() public {
        address[4] memory malformed = _deployMalformedViews();
        for (uint256 i = 0; i < malformed.length; ++i) {
            DependentDvpRegistryHarness isolated = _deployRegistry();
            MockDvP healthy = new MockDvP(bytes32(uint256(0x500 + i)));
            vm.prank(address(timelock));
            isolated.registerDependentDvp(address(healthy), bytes32(uint256(0x100 + i)));

            vm.etch(address(healthy), malformed[i].code);
            vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpStatusMalformed.selector, address(healthy)));
            vm.prank(address(timelock));
            isolated.exemptRetiredDependentDvp(address(healthy), bytes32(uint256(0x200 + i)));
        }
    }

    function testUpgradeRejectsRevertShortLongAndNonCanonicalPausedStatus() public {
        address[4] memory malformed = _deployMalformedViews();
        for (uint256 i = 0; i < malformed.length; ++i) {
            DependentDvpRegistryHarness isolated = _deployRegistry();
            MockDvP healthy = new MockDvP(bytes32(uint256(0x600 + i)));
            vm.prank(address(timelock));
            isolated.registerDependentDvp(address(healthy), bytes32(uint256(0x300 + i)));

            vm.etch(address(healthy), malformed[i].code);
            DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();

            vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpStatusMalformed.selector, address(healthy)));
            vm.prank(address(timelock));
            isolated.upgradeToAndCall(address(nextImplementation), bytes(""));
        }
    }

    function testRetiredExemptionSkipsGlobalPausedCallDuringUpgrade() public {
        MockDvP retiring = new MockDvP(keccak256("retiring-dvp"));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(retiring), EVIDENCE_HASH);
        retiring.setRetired(true);
        vm.prank(address(timelock));
        registry.exemptRetiredDependentDvp(address(retiring), bytes32(uint256(0xE2)));

        // 豁免后把 globalPaused 换成必然 revert 的实现：升级仍须成功，
        // 这直接证明门禁跳过了该调用而不是碰巧读到了 true。
        vm.etch(address(retiring), address(new RetiredOnlyDvPGovernanceView()).code);

        DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        assertEq(registry.implementationVersion(), 2);
    }

    function testUpgradeRejectsEmptyDependentSet() public {
        assertEq(registry.getDependentDvpCount(), 0);
        DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();

        vm.expectRevert(HTPErrors.NoDependentDvpRegistered.selector);
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        assertEq(registry.implementationVersion(), 1);

        // 空集合不构成死锁：registerDependentDvp 不经过升级门禁，补登记即可恢复。
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        assertEq(registry.implementationVersion(), 2);
    }

    function testRegistrationRejectsMalformedRetiredAndGasBombGovernanceViews() public {
        address[4] memory malformed = _deployMalformedViews();
        for (uint256 i = 0; i < malformed.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, malformed[i]));
            vm.prank(address(timelock));
            registry.registerDependentDvp(malformed[i], bytes32(uint256(0x700 + i)));
        }

        // 烧 gas 而非 revert：限 gas 后表现为 wellFormed=false，而不是把整笔交易拖成 OOG。
        address gasBomb = address(new GasBombDvPGovernanceView());
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, gasBomb));
        vm.prank(address(timelock));
        registry.registerDependentDvp(gasBomb, bytes32(uint256(0x900)));

        // 已退役的 DvP 登记后只能立刻豁免，等于白占一个永久槽位。
        MockDvP alreadyRetired = new MockDvP(keccak256("already-retired"));
        alreadyRetired.setRetired(true);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpRetired.selector, address(alreadyRetired)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(alreadyRetired), bytes32(uint256(0xA00)));

        assertEq(registry.getDependentDvpCount(), 0);
    }

    function testRegistrationRejectsZeroNoCodeDuplicateAndZeroEvidence() public {
        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDependentDvp.selector, address(0)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(0), EVIDENCE_HASH);

        address noCode = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidDependentDvp.selector, noCode));
        vm.prank(address(timelock));
        registry.registerDependentDvp(noCode, EVIDENCE_HASH);

        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpAlreadyRegistered.selector, address(dependentDvp)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), bytes32(uint256(0xE2)));

        assertEq(registry.getDependentDvpCount(), 1);
    }

    function testDependentDvpCollectionHasNoDeleteOrReplaceSelector() public {
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        vm.prank(address(timelock));
        (bool removeSuccess,) =
            address(registry).call(abi.encodeWithSignature("removeDependentDvp(address)", address(dependentDvp)));
        vm.prank(address(timelock));
        (bool replaceSuccess,) = address(registry)
            .call(
                abi.encodeWithSignature("replaceDependentDvp(address,address)", address(dependentDvp), address(0xBEEF))
            );

        assertFalse(removeSuccess);
        assertFalse(replaceSuccess);
        assertEq(registry.getDependentDvpCount(), 1);
        (address storedDvp,) = registry.getDependentDvp(0);
        assertEq(storedDvp, address(dependentDvp));
    }

    function testDependentDvpLimitCannotBeFreedByDeletion() public {
        uint256 limit = registry.MAX_DEPENDENT_DVPS();
        for (uint256 i = 0; i < limit; ++i) {
            MockDvP dvp = new MockDvP(bytes32(i + 1));
            vm.prank(address(timelock));
            registry.registerDependentDvp(address(dvp), bytes32(uint256(0x1000 + i)));
        }

        MockDvP overflowDvp = new MockDvP(bytes32(uint256(limit + 1)));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpLimitReached.selector, limit));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(overflowDvp), bytes32(uint256(0xFFFF)));

        (address firstDvp,) = registry.getDependentDvp(0);
        vm.prank(address(timelock));
        (bool removeSuccess,) = address(registry).call(abi.encodeWithSignature("removeDependentDvp(address)", firstDvp));
        assertFalse(removeSuccess);
        assertEq(registry.getDependentDvpCount(), limit);
    }

    function testUpgradeTraversesMaximumPausedDependentDvpsWithinMeasuredBudget() public {
        uint256 limit = registry.MAX_DEPENDENT_DVPS();
        for (uint256 i = 0; i < limit; ++i) {
            MockDvP dvp = new MockDvP(bytes32(i + 1));
            dvp.setGlobalPaused(true);
            vm.prank(address(timelock));
            registry.registerDependentDvp(address(dvp), bytes32(uint256(0x2000 + i)));
        }
        DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();

        vm.prank(address(timelock));
        uint256 gasBefore = gasleft();
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_max_dependent_upgrade_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 200_000);

        assertEq(registry.implementationVersion(), 2);
        assertEq(registry.getDependentDvpCount(), limit);
    }

    function testLimitOverflowMigratesToNewRegistryAndDvpWithoutDeletingOldDependencies() public {
        uint256 limit = registry.MAX_DEPENDENT_DVPS();
        for (uint256 i = 0; i < limit; ++i) {
            MockDvP oldDvp = new MockDvP(bytes32(i + 1));
            vm.prank(address(timelock));
            registry.registerDependentDvp(address(oldDvp), bytes32(uint256(0x3000 + i)));
        }

        DependentDvpRegistryHarness replacementRegistry = _deployRegistry();
        MockDvP replacementDvp = new MockDvP(keccak256("replacement-dvp"));
        vm.prank(address(timelock));
        replacementRegistry.registerDependentDvp(address(replacementDvp), bytes32(uint256(0x4000)));

        (address firstOldDvp,) = registry.getDependentDvp(0);
        vm.prank(address(timelock));
        (bool removed,) = address(registry).call(abi.encodeWithSignature("removeDependentDvp(address)", firstOldDvp));

        assertFalse(removed);
        assertEq(registry.getDependentDvpCount(), limit);
        assertEq(replacementRegistry.getDependentDvpCount(), 1);
        (address storedReplacementDvp,) = replacementRegistry.getDependentDvp(0);
        assertEq(storedReplacementDvp, address(replacementDvp));
    }

    function testUpgradePreservesRolesAndDependentDvpHistory() public {
        MockDvP pausedDvp = dependentDvp;
        pausedDvp.setGlobalPaused(true);
        MockDvP retiredDvp = new MockDvP(keccak256("retired-dependent"));

        vm.startPrank(address(timelock));
        registry.registerDependentDvp(address(pausedDvp), EVIDENCE_HASH);
        registry.registerDependentDvp(address(retiredDvp), bytes32(uint256(0xE2)));
        vm.stopPrank();

        retiredDvp.setRetired(true);

        vm.startPrank(address(timelock));
        registry.exemptRetiredDependentDvp(address(retiredDvp), bytes32(uint256(0xE3)));
        DependentDvpRegistryHarnessV2 nextImplementation = new DependentDvpRegistryHarnessV2();
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        vm.stopPrank();

        assertEq(registry.implementationVersion(), 2);
        assertEq(registry.getDependentDvpCount(), 2);
        (address first, bool firstExempt) = registry.getDependentDvp(0);
        (address second, bool secondExempt) = registry.getDependentDvp(1);
        assertEq(first, address(pausedDvp));
        assertFalse(firstExempt);
        assertEq(second, address(retiredDvp));
        assertTrue(secondExempt);
        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
    }

    function _deployMalformedViews() private returns (address[4] memory views) {
        views[0] = address(new RevertingDvPGovernanceView());
        views[1] = address(new ShortReturnDvPGovernanceView());
        views[2] = address(new LongReturnDvPGovernanceView());
        views[3] = address(new NonCanonicalBoolDvPGovernanceView());
    }

    function _deployRegistry() private returns (DependentDvpRegistryHarness) {
        DependentDvpRegistryHarness implementation = new DependentDvpRegistryHarness();
        return DependentDvpRegistryHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(DependentDvpRegistryHarness.initialize, (address(timelock), PAUSER, CONFIGURER))
            )
        );
    }

    function _assertDependentDvpEvent(Vm.Log memory entry, bytes32 expectedTopic, bytes32 expectedEvidence)
        private
        view
    {
        assertEq(entry.emitter, address(registry));
        assertEq(entry.topics.length, 2);
        assertEq(entry.topics[0], expectedTopic);
        assertEq(entry.topics[1], bytes32(uint256(uint160(address(dependentDvp)))));
        assertEq(entry.data.length, 96);
        (uint256 chainId, bytes32 evidenceHash, address actor) = abi.decode(entry.data, (uint256, bytes32, address));
        assertEq(chainId, block.chainid);
        assertEq(evidenceHash, expectedEvidence);
        assertEq(actor, address(timelock));
    }
}
