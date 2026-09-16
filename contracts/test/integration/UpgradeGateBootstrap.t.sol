// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, DirectOperation} from "script/DeployTypes.sol";
import {RegisterDependentDvps} from "script/RegisterDependentDvps.s.sol";
import {VerifyDeployment} from "script/VerifyDeployment.s.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {UUPSRegistryBase} from "src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode} from "src/types/HTPTypes.sol";

interface IGateView {
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;
}

/// @notice 覆盖「部署 → 登记依赖 DvP → 升级门禁可用」这条收口链路。
///
/// @dev 部署者不持有 GOVERNANCE，所以八笔 registerDependentDvp 无法并入部署广播。
/// 在它们完成之前门禁 fail-closed，本套件既验证这个安全默认，也验证收口脚本确实能解开它。
contract UpgradeGateBootstrapTest is Test {
    address private constant DEFAULT_ADMIN = address(0x1001);
    address private constant UPGRADER = address(0x1003);
    address private constant PAUSER = address(0x1004);
    address private constant EXECUTOR = address(0x1005);
    address private constant CONFIGURER = address(0x1006);
    bytes32 private constant EVIDENCE = bytes32(uint256(0xE1));

    DeployHTP private orchestrator;
    RegisterDependentDvps private gateScript;
    CoreDeployment private core;

    function setUp() public {
        orchestrator = new DeployHTP();
        // 脚本合约充当 GOVERNANCE，等价于生产环境用 GOVERNANCE 私钥广播 run()。
        gateScript = new RegisterDependentDvps();

        DeploymentConfig memory config = DeploymentConfig({
            roles: DeploymentRoles({
                defaultAdmin: DEFAULT_ADMIN,
                governance: address(gateScript),
                upgrader: UPGRADER,
                pauser: PAUSER,
                executor: EXECUTOR,
                configurer: CONFIGURER
            }),
            deploymentVersion: bytes("1.0.0"),
            chainId: block.chainid
        });
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        core = orchestrator.deployCore(config, firstNonce);
    }

    function testDeploymentLeavesGateClosedNotOpen() public {
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            assertEq(IGateView(registries[i]).getDependentDvpCount(), 0, "set starts empty");
        }
        assertFalse(DvPSettlement(core.dvp).globalPaused(), "dvp starts live");

        // 空集合是 fail-closed 的安全默认，而不是「无依赖所以放行」。
        address nextImplementation = address(new AdapterRegistry());
        vm.expectRevert(HTPErrors.NoDependentDvpRegistered.selector);
        vm.prank(UPGRADER);
        IGateView(core.adapterRegistry.proxy).upgradeToAndCall(nextImplementation, "");

        assertEq(gateScript.pendingRegistrations(core).length, 8, "all eight pending");
    }

    function testScriptRegistersEveryRegistryAndSelfVerifies() public {
        uint256 written = gateScript.registerAll(core, EVIDENCE);

        assertEq(written, 8, "one registration per registry");
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            assertEq(IGateView(registries[i]).getDependentDvpCount(), 1);
            (address stored, bool exempt) = IGateView(registries[i]).getDependentDvp(0);
            assertEq(stored, core.dvp);
            assertFalse(exempt);
        }
        assertEq(gateScript.pendingRegistrations(core).length, 0, "nothing left pending");

        // 独立复核：部署验收脚本此刻应当通过（修复前它在这里 revert）。
        new VerifyDeployment().verifyDependentDvpRegistrations(core);
    }

    function testScriptIsIdempotentAndSafeToRerun() public {
        assertEq(gateScript.registerAll(core, EVIDENCE), 8);

        // 重跑不得 revert，也不得把同一个 DvP 二次写入只增不删的集合。
        assertEq(gateScript.registerAll(core, EVIDENCE), 0, "second run writes nothing");
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            assertEq(IGateView(registries[i]).getDependentDvpCount(), 1, "no duplicate entry");
        }
    }

    function testPartialProgressIsResumable() public {
        // 模拟一次中途失败：只有三个 Registry 完成了登记。
        address[8] memory registries = _registries();
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(address(gateScript));
            UUPSRegistryBase(registries[i]).registerDependentDvp(core.dvp, EVIDENCE);
        }

        address[] memory pending = gateScript.pendingRegistrations(core);
        assertEq(pending.length, 5, "five still pending");
        DirectOperation[] memory operations = gateScript.pendingOperations(core, EVIDENCE);
        assertEq(operations.length, 5, "calldata only for the remainder");
        for (uint256 i = 0; i < operations.length; ++i) {
            assertEq(operations[i].target, pending[i]);
        }

        assertEq(gateScript.registerAll(core, EVIDENCE), 5, "resume completes the rest");
        assertEq(gateScript.pendingRegistrations(core).length, 0);
    }

    function testGateEnforcesPauseOnceRegistrationsLand() public {
        gateScript.registerAll(core, EVIDENCE);
        address nextImplementation = address(new AdapterRegistry());

        // DvP 仍在服役：门禁从「未登记」转为「必须先暂停」，双角色控制在此生效。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpNotPaused.selector, core.dvp));
        vm.prank(UPGRADER);
        IGateView(core.adapterRegistry.proxy).upgradeToAndCall(nextImplementation, "");

        vm.prank(PAUSER);
        DvPSettlement(core.dvp).pauseGlobal(_pauseReason(), EVIDENCE);

        vm.prank(UPGRADER);
        IGateView(core.adapterRegistry.proxy).upgradeToAndCall(nextImplementation, "");
        assertEq(
            address(uint160(uint256(vm.load(core.adapterRegistry.proxy, _implementationSlot())))),
            nextImplementation,
            "upgrade lands only after pause"
        );
    }

    function testScriptRejectsZeroEvidenceAndUndeployedDvp() public {
        vm.expectRevert(RegisterDependentDvps.EvidenceHashRequired.selector);
        gateScript.registerAll(core, bytes32(0));

        CoreDeployment memory broken = core;
        broken.dvp = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(RegisterDependentDvps.DvpNotDeployed.selector, address(0xDEAD)));
        gateScript.registerAll(broken, EVIDENCE);
    }

    function _registries() private view returns (address[8] memory registries) {
        registries[0] = core.adapterRegistry.proxy;
        registries[1] = core.calculatorRegistry.proxy;
        registries[2] = core.settlementTokenRegistry.proxy;
        registries[3] = core.assetVersionRegistry.proxy;
        registries[4] = core.eligibilityRegistry.proxy;
        registries[5] = core.feeRegistry.proxy;
        registries[6] = core.marketRuleRegistry.proxy;
        registries[7] = core.participantRegistry.proxy;
    }

    function _implementationSlot() private pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function _pauseReason() private pure returns (ReasonCode) {
        return ReasonCode.PLANNED_MIGRATION;
    }
}
