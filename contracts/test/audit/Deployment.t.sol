// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT (Module F). Delete after review.

import {Test} from "forge-std/Test.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, DirectOperation} from "script/DeployTypes.sol";
import {UpgradeRegistries, UpgradeSnapshot, UpgradeVerificationSet} from "script/UpgradeRegistries.s.sol";
import {VerifyDeployment} from "script/VerifyDeployment.s.sol";
import {VerifyRoles} from "script/VerifyRoles.s.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {Roles} from "src/libraries/Roles.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode} from "src/types/HTPTypes.sol";

interface IDependentView {
    function getDependentDvpCount() external view returns (uint256);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

contract TmpAuditModuleFDeployment is Test {
    address private constant DEFAULT_ADMIN = address(0xA0A0);
    address private constant GOVERNANCE = address(0xB0B0);
    address private constant UPGRADER = address(0xC0C0);
    address private constant PAUSER = address(0xD0D0);
    address private constant EXECUTOR = address(0xE0E0);
    address private constant CONFIGURER = address(0xF0F0);
    address private constant BACKDOOR = address(0xBADBAD);

    DeployHTP private deployer;
    CoreDeployment private core;

    function setUp() public {
        deployer = new DeployHTP();
        DeploymentConfig memory config = DeploymentConfig({
            roles: DeploymentRoles({
                defaultAdmin: DEFAULT_ADMIN,
                governance: GOVERNANCE,
                upgrader: UPGRADER,
                pauser: PAUSER,
                executor: EXECUTOR,
                configurer: CONFIGURER
            }),
            deploymentVersion: bytes("1.2.3"),
            chainId: block.chainid
        });
        core = deployer.deployCore(config, uint64(vm.getNonce(address(deployer))));
    }

    function _registries() private view returns (address[8] memory registries) {
        registries = [
            core.adapterRegistry.proxy,
            core.calculatorRegistry.proxy,
            core.settlementTokenRegistry.proxy,
            core.assetVersionRegistry.proxy,
            core.eligibilityRegistry.proxy,
            core.feeRegistry.proxy,
            core.marketRuleRegistry.proxy,
            core.participantRegistry.proxy
        ];
    }

    /// Evidence for the post-deployment role table: the broadcasting deployer
    /// never receives any role, on any contract, so there is nothing to revoke.
    /// Every custom role is administered by DEFAULT_ADMIN_ROLE.
    function test_roleTable_deployerHoldsNothingAndAdminsAreDefaultAdmin() public view {
        bytes32[5] memory allRoles = [
            Roles.DEFAULT_ADMIN_ROLE,
            Roles.GOVERNANCE_ROLE,
            Roles.UPGRADER_ROLE,
            Roles.PAUSER_ROLE,
            Roles.CONFIGURER_ROLE
        ];
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            FeeRegistry registry = FeeRegistry(registries[i]);
            for (uint256 j = 0; j < allRoles.length; ++j) {
                assertFalse(registry.hasRole(allRoles[j], address(deployer)), "deployer must hold no registry role");
                assertFalse(registry.hasRole(allRoles[j], address(this)), "test harness must hold no registry role");
                assertEq(registry.getRoleAdmin(allRoles[j]), Roles.DEFAULT_ADMIN_ROLE, "role admin");
            }
            assertFalse(registry.hasRole(Roles.EXECUTOR_ROLE, EXECUTOR), "registries have no EXECUTOR");
        }

        DvPSettlement settlement = DvPSettlement(core.dvp);
        assertFalse(settlement.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(deployer)));
        assertFalse(settlement.hasRole(Roles.GOVERNANCE_ROLE, address(deployer)));
        assertFalse(settlement.hasRole(Roles.PAUSER_ROLE, address(deployer)));
        assertFalse(settlement.hasRole(Roles.EXECUTOR_ROLE, address(deployer)));
        // DvP holds neither UPGRADER nor CONFIGURER for anyone.
        assertFalse(settlement.hasRole(Roles.UPGRADER_ROLE, UPGRADER));
        assertFalse(settlement.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
    }

    /// F-01: DeployHTP never registers the DvP as a dependent, so the eight
    /// registries end deployment with an empty dependent set.
    function test_F01_deploymentLeavesDependentDvpSetEmpty() public view {
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            assertEq(IDependentView(registries[i]).getDependentDvpCount(), 0, "dependent set should be empty");
        }
        // The DvP is simultaneously live: not paused, not retired.
        assertFalse(DvPSettlement(core.dvp).globalPaused(), "dvp deployed unpaused");
        assertFalse(DvPSettlement(core.dvp).retired(), "dvp deployed not retired");
    }

    /// F-01: with the dependent set empty the UUPS "pause before upgrade" gate
    /// is a zero-iteration loop, so UPGRADER alone can swap implementations
    /// while the DvP keeps accepting settle().
    // 修复后：UPGRADER 单独无法在 DvP 存活时替换实现。
    // 原缺陷是空依赖集合让门禁 fail-open，UPGRADER 一人即可热替换任意 Registry。
    function test_F01_upgraderAloneCannotUpgradeWhileDvpLive() public {
        assertFalse(DvPSettlement(core.dvp).globalPaused());
        address newImplementation = address(new AdapterRegistry());
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address implementationBefore = address(uint160(uint256(vm.load(core.adapterRegistry.proxy, slot))));

        // 尚未登记依赖 DvP：门禁 fail-closed，而不是把空集合当作「无依赖」。
        vm.prank(UPGRADER);
        vm.expectRevert(HTPErrors.NoDependentDvpRegistered.selector);
        IDependentView(core.adapterRegistry.proxy).upgradeToAndCall(newImplementation, "");
        assertEq(
            address(uint160(uint256(vm.load(core.adapterRegistry.proxy, slot)))),
            implementationBefore,
            "implementation must be untouched"
        );

        // 补上登记之后，门禁转为要求依赖 DvP 已暂停——双角色控制在此恢复。
        vm.prank(GOVERNANCE);
        IDependentView(core.adapterRegistry.proxy).registerDependentDvp(core.dvp, bytes32(uint256(0xE1)));
        vm.prank(UPGRADER);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpNotPaused.selector, core.dvp));
        IDependentView(core.adapterRegistry.proxy).upgradeToAndCall(newImplementation, "");
    }

    /// F-01 corollary: VerifyDeployment.verifyDependentDvpRegistrations fails
    /// immediately after DeployHTP, i.e. the repo's own post-deploy check
    /// documents that the deployment script leaves this step undone.
    function test_F01_verifyDependentRegistrationsFailsRightAfterDeploy() public {
        VerifyDeployment verifier = new VerifyDeployment();
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployment.VerificationFailed.selector, bytes32("DEPENDENT_DVP_COUNT"), core.adapterRegistry.proxy
            )
        );
        verifier.verifyDependentDvpRegistrations(core);
    }

    /// F-03: VerifyRoles only asserts that the intended holders HAVE the roles.
    /// It cannot detect an additional DEFAULT_ADMIN because the contracts use
    /// plain AccessControl (no enumeration).
    function test_F03_verifyRolesPassesWithExtraAdmin() public {
        VerifyRoles verifier = new VerifyRoles();
        DeploymentRoles memory roles = DeploymentRoles({
            defaultAdmin: DEFAULT_ADMIN,
            governance: GOVERNANCE,
            upgrader: UPGRADER,
            pauser: PAUSER,
            executor: EXECUTOR,
            configurer: CONFIGURER
        });
        verifier.verifyTopology(core, roles);

        vm.startPrank(DEFAULT_ADMIN);
        IDependentView(core.feeRegistry.proxy).grantRole(Roles.DEFAULT_ADMIN_ROLE, BACKDOOR);
        DvPSettlement(core.dvp).grantRole(Roles.EXECUTOR_ROLE, BACKDOOR);
        vm.stopPrank();

        assertTrue(FeeRegistry(core.feeRegistry.proxy).hasRole(Roles.DEFAULT_ADMIN_ROLE, BACKDOOR));
        assertTrue(DvPSettlement(core.dvp).hasRole(Roles.EXECUTOR_ROLE, BACKDOOR));
        // Still passes: the topology check is positive-only.
        verifier.verifyTopology(core, roles);
    }

    /// F-07: the upgrade runbook's unpause gate verifies a caller-supplied set
    /// of registries and never binds it to the eight registries the DvP
    /// actually depends on, so verifying one unrelated registry is enough.
    function test_F07_unpauseGateAcceptsAnArbitrarySubset() public {
        vm.prank(GOVERNANCE);
        IDependentView(core.adapterRegistry.proxy).registerDependentDvp(core.dvp, bytes32(uint256(0xE1)));
        vm.prank(PAUSER);
        DvPSettlement(core.dvp).pauseGlobal(ReasonCode.PLANNED_MIGRATION, bytes32(uint256(0xE1)));

        UpgradeRegistries runbook = new UpgradeRegistries();
        bytes[] memory probes = new bytes[](1);
        probes[0] = abi.encodeWithSignature("getDependentDvpCount()");

        // One registry out of eight; and it was never upgraded at all.
        address[] memory registries = new address[](1);
        registries[0] = core.adapterRegistry.proxy;
        address[] memory implementations = new address[](1);
        implementations[0] = core.adapterRegistry.implementation;
        bytes32[] memory codeHashes = new bytes32[](1);
        codeHashes[0] = core.adapterRegistry.implementation.codehash;
        UpgradeSnapshot[] memory beforeStates = new UpgradeSnapshot[](1);
        beforeStates[0] = runbook.snapshot(core.adapterRegistry.proxy, probes);
        bytes[][] memory probeSets = new bytes[][](1);
        probeSets[0] = probes;

        DirectOperation memory operation = runbook.buildUnpauseAfterSuccessfulVerification(
            core.dvp,
            UpgradeVerificationSet({
                registries: registries,
                implementations: implementations,
                codeHashes: codeHashes,
                beforeStates: beforeStates,
                publicStateProbes: probeSets,
                expectedDefaultAdmin: DEFAULT_ADMIN,
                expectedGovernance: GOVERNANCE,
                expectedUpgrader: UPGRADER
            }),
            bytes32(uint256(0xE2))
        );

        assertEq(operation.target, core.dvp, "runbook happily produces the unpause call");
        assertEq(
            operation.data,
            abi.encodeWithSignature(
                "unpauseGlobal(uint8,bytes32)", uint8(ReasonCode.GOVERNANCE_ACTION), bytes32(uint256(0xE2))
            )
        );
    }

    /// 修复后（F-04）：DvP 上的 PAUSER 与 GOVERNANCE 仍可被弃权——它们丢了还能
    /// 由 DEFAULT_ADMIN 补授，属于可恢复故障。真正会锁死整个系统的是最后一个
    /// DEFAULT_ADMIN：一旦没有它，任何角色都补不回来，DvP 再也无法暂停，八个
    /// Registry 的升级门禁便永远无法满足。护住这一个就切断了整条死锁链。
    function test_F04_lastDefaultAdminCannotBeRenouncedSoRecoveryStaysOpen() public {
        // Realistic going-live state: the dependent registration was done.
        vm.startPrank(GOVERNANCE);
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            IDependentView(registries[i]).registerDependentDvp(core.dvp, bytes32(uint256(0xE1)));
        }
        vm.stopPrank();

        // Operational accident on the two recoverable roles.
        vm.prank(PAUSER);
        DvPSettlement(core.dvp).renounceRole(Roles.PAUSER_ROLE, PAUSER);
        vm.prank(GOVERNANCE);
        DvPSettlement(core.dvp).renounceRole(Roles.GOVERNANCE_ROLE, GOVERNANCE);

        // 最后一个 DEFAULT_ADMIN 不能再弃权，恢复通道因此始终存在。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, DEFAULT_ADMIN));
        vm.prank(DEFAULT_ADMIN);
        DvPSettlement(core.dvp).renounceRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN);

        // 补授 PAUSER 后暂停能力立刻恢复。
        vm.prank(DEFAULT_ADMIN);
        DvPSettlement(core.dvp).grantRole(Roles.PAUSER_ROLE, PAUSER);
        vm.prank(PAUSER);
        DvPSettlement(core.dvp).pauseGlobal(ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xE1)));
        assertTrue(DvPSettlement(core.dvp).globalPaused());

        // 于是 Registry 升级门禁重新可满足，不再是永久冻结。
        address newImplementation = address(new AdapterRegistry());
        vm.prank(UPGRADER);
        IDependentView(core.adapterRegistry.proxy).upgradeToAndCall(newImplementation, "");
    }
}
