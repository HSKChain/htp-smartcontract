// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {Roles} from "src/libraries/Roles.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract DvPAccessControlTest is DvPTestBase {
    address private constant DEFAULT_ADMIN = address(0x4001);
    bytes32 private constant EVIDENCE = keccak256("access-control-test");

    function testConstructorAssignsIndependentRolesWithoutDeployerResidue() public view {
        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(dvp.hasRole(Roles.EXECUTOR_ROLE, EXECUTOR));

        assertEq(dvp.getRoleAdmin(Roles.GOVERNANCE_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(dvp.getRoleAdmin(Roles.PAUSER_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(dvp.getRoleAdmin(Roles.EXECUTOR_ROLE), Roles.DEFAULT_ADMIN_ROLE);

        assertFalse(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(this)));
        assertFalse(dvp.hasRole(Roles.GOVERNANCE_ROLE, address(this)));
        assertFalse(dvp.hasRole(Roles.PAUSER_ROLE, address(this)));
        assertFalse(dvp.hasRole(Roles.EXECUTOR_ROLE, address(this)));
    }

    // DvP 不可升级，失去最后一个 DEFAULT_ADMIN 就再也补授不出任何角色：
    // 没人能 pauseGlobal，八个 Registry 的升级门禁便永远无法满足（审计 F-04）。
    // renounce 与 admin 自撤销效果相同，两条都必须拦。
    function testLastDefaultAdminCannotBeRemovedByEitherRenounceOrRevoke() public {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        dvp.renounceRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        dvp.revokeRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);

        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE));
    }

    // 保护的是「最后一个」而非「这个角色」：补上接任者后交接照常，
    // 且接任者立刻继承同样的保护，中间不存在可以自摘的空窗。
    function testDefaultAdminHandoverWorksAndSuccessorInheritsProtection() public {
        vm.prank(GOVERNANCE);
        dvp.grantRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN);

        vm.prank(GOVERNANCE);
        dvp.renounceRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);
        assertFalse(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, DEFAULT_ADMIN));
        vm.prank(DEFAULT_ADMIN);
        dvp.renounceRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN);
    }

    // 其余角色不受此保护：它们丢了都能由 DEFAULT_ADMIN 补授，属于可恢复故障。
    // 只护 DEFAULT_ADMIN 就足以切断 F-04 的死锁链。
    function testOtherRolesRemainRenounceableBecauseTheyAreRecoverable() public {
        vm.prank(PAUSER);
        dvp.renounceRole(Roles.PAUSER_ROLE, PAUSER);
        assertFalse(dvp.hasRole(Roles.PAUSER_ROLE, PAUSER));

        vm.prank(GOVERNANCE);
        dvp.grantRole(Roles.PAUSER_ROLE, PAUSER);
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, PAUSER));
    }

    // 重复授予不得抬高计数，否则保护会因计数虚高而失效。
    function testRedundantDefaultAdminGrantDoesNotInflateTheCount() public {
        vm.prank(GOVERNANCE);
        dvp.grantRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        dvp.renounceRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);
    }

    function testConstructorAllowsOneAddressToHoldEveryRole() public {
        DvPSettlement unified = _deploy(DEFAULT_ADMIN, DEFAULT_ADMIN, DEFAULT_ADMIN, DEFAULT_ADMIN);

        assertTrue(unified.hasRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN));
        assertTrue(unified.hasRole(Roles.GOVERNANCE_ROLE, DEFAULT_ADMIN));
        assertTrue(unified.hasRole(Roles.PAUSER_ROLE, DEFAULT_ADMIN));
        assertTrue(unified.hasRole(Roles.EXECUTOR_ROLE, DEFAULT_ADMIN));

        vm.startPrank(DEFAULT_ADMIN);
        unified.pauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);
        unified.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);
        vm.stopPrank();
    }

    function testConstructorRejectsEachZeroRoleHolderWithRoleContext() public {
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.DEFAULT_ADMIN_ROLE, address(0))
        );
        _deploy(address(0), GOVERNANCE, PAUSER, EXECUTOR);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.GOVERNANCE_ROLE, address(0)));
        _deploy(DEFAULT_ADMIN, address(0), PAUSER, EXECUTOR);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.PAUSER_ROLE, address(0)));
        _deploy(DEFAULT_ADMIN, GOVERNANCE, address(0), EXECUTOR);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.EXECUTOR_ROLE, address(0)));
        _deploy(DEFAULT_ADMIN, GOVERNANCE, PAUSER, address(0));
    }

    function testDefaultAdminCanGrantAndRevokeOverlappingRolesIndependently() public {
        DvPSettlement split = _deploy(DEFAULT_ADMIN, GOVERNANCE, PAUSER, EXECUTOR);

        vm.startPrank(DEFAULT_ADMIN);
        split.grantRole(Roles.EXECUTOR_ROLE, PAUSER);
        split.revokeRole(Roles.GOVERNANCE_ROLE, GOVERNANCE);
        vm.stopPrank();

        assertTrue(split.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(split.hasRole(Roles.EXECUTOR_ROLE, PAUSER));
        assertFalse(split.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(split.hasRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN));
    }

    function testIndependentRolesRemainSelectorScoped() public {
        DvPSettlement split = _deploy(DEFAULT_ADMIN, GOVERNANCE, PAUSER, EXECUTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, GOVERNANCE, Roles.PAUSER_ROLE
            )
        );
        vm.prank(GOVERNANCE);
        split.pauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.prank(PAUSER);
        split.pauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(PAUSER);
        split.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.prank(GOVERNANCE);
        split.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);
    }

    function testGovernanceCannotAdminRolesWhenDefaultAdminIsSeparate() public {
        DvPSettlement split = _deploy(DEFAULT_ADMIN, GOVERNANCE, PAUSER, EXECUTOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, GOVERNANCE, Roles.DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(GOVERNANCE);
        split.grantRole(Roles.EXECUTOR_ROLE, GOVERNANCE);
    }

    function _deploy(address defaultAdmin, address governance, address pauser, address executor)
        private
        returns (DvPSettlement)
    {
        return _deployDvp(
            DvPRoles({defaultAdmin: defaultAdmin, governance: governance, pauser: pauser, executor: executor})
        );
    }
}
