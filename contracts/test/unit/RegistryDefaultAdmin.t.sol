// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {RegistryTestBase} from "../helpers/RegistryTestBase.sol";

contract RegistryDefaultAdminHarness is UUPSRegistryBase {
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address operator)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, operator);
    }
}

contract RegistryDefaultAdminTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);
    address internal constant NEXT_TIMELOCK = address(0x5001);

    RegistryDefaultAdminHarness internal registry;

    function setUp() public override {
        super.setUp();
        RegistryDefaultAdminHarness implementation = new RegistryDefaultAdminHarness();
        registry = RegistryDefaultAdminHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    RegistryDefaultAdminHarness.initialize,
                    (address(timelock), GOVERNANCE, address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
    }

    function testDefaultAdminCanBeGrantedAndRevokedWithOrdinaryAccessControlSemantics() public {
        vm.prank(address(timelock));
        registry.grantRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK);

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK));
        assertFalse(registry.hasRole(Roles.GOVERNANCE_ROLE, NEXT_TIMELOCK));
        assertFalse(registry.hasRole(Roles.UPGRADER_ROLE, NEXT_TIMELOCK));

        vm.prank(NEXT_TIMELOCK);
        registry.revokeRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK));
        assertFalse(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
    }

    function testGovernanceCannotManageRolesWithoutDefaultAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, GOVERNANCE, Roles.DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(GOVERNANCE);
        registry.grantRole(Roles.PAUSER_ROLE, GOVERNANCE);
    }

    function testRevokingDefaultAdminDoesNotRevokeIndependentRoles() public {
        // 需要先有接任者：摘除最后一个 DEFAULT_ADMIN 已被禁止。本用例要测的是
        // 「丢掉 admin 不会连带丢掉其他角色」，与人数无关。
        vm.prank(address(timelock));
        registry.grantRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK);

        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        assertFalse(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
    }

    // 失去最后一个 DEFAULT_ADMIN 之后，任何角色都无法再授予，而升级门禁要求依赖
    // DvP 先被暂停——若 PAUSER 也已丢失，这台 Registry 连换实现的路都没有了。
    // renounce 与 admin 自撤销殊途同归，两条都必须拦。
    function testLastDefaultAdminCannotBeRemovedByEitherRenounceOrRevoke() public {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.revokeRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
    }

    // 保护的是「最后一个」，不是「这个角色」。补上接任者之后交接照常进行，
    // 而且换完之后新 admin 同样受保护，不会出现一个可以自摘的空窗。
    function testHandoverWorksAndTheSuccessorInheritsTheSameProtection() public {
        vm.prank(address(timelock));
        registry.grantRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK);

        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));
        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, NEXT_TIMELOCK));
        vm.prank(NEXT_TIMELOCK);
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, NEXT_TIMELOCK);
    }

    // 重复授予不得把计数抬高，否则计数会虚高、保护随之失效。
    function testRedundantGrantDoesNotInflateTheAdminCount() public {
        vm.prank(address(timelock));
        registry.grantRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));
    }
}
