// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Roles} from "src/libraries/Roles.sol";
import {UUPSRegistryBase} from "src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract SlowMistN3RegistryHarness is UUPSRegistryBase {
    function initialize(address defaultAdmin) external initializer {
        _initializeRegistryBase(defaultAdmin, defaultAdmin, defaultAdmin, defaultAdmin, defaultAdmin);
    }
}

/// @notice SlowMist N3: zero address cannot bypass the last actionable default-admin guard.
contract SlowMistN3RegistryTest is RegistryTestBase {
    SlowMistN3RegistryHarness private registry;

    function setUp() public override {
        super.setUp();
        SlowMistN3RegistryHarness implementation = new SlowMistN3RegistryHarness();
        registry = SlowMistN3RegistryHarness(
            _deployProxy(
                address(implementation), abi.encodeCall(SlowMistN3RegistryHarness.initialize, (address(timelock)))
            )
        );
    }

    function test_N3_RegistryRejectsZeroAdminAndKeepsBothRemovalPathsGuarded() public {
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.DEFAULT_ADMIN_ROLE, address(0))
        );
        vm.prank(address(timelock));
        registry.grantRole(Roles.DEFAULT_ADMIN_ROLE, address(0));

        assertFalse(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(0)));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.renounceRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, address(timelock)));
        vm.prank(address(timelock));
        registry.revokeRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock));
    }
}

/// @notice SlowMist N3: the non-upgradeable DvP rejects the same zero-address admin bypass.
contract SlowMistN3DvpTest is DvPTestBase {
    function test_N3_DvPRejectsZeroAdminAndKeepsBothRemovalPathsGuarded() public {
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.DEFAULT_ADMIN_ROLE, address(0))
        );
        vm.prank(GOVERNANCE);
        dvp.grantRole(Roles.DEFAULT_ADMIN_ROLE, address(0));

        assertFalse(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(0)));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        dvp.renounceRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.LastDefaultAdminCannotBeRemoved.selector, GOVERNANCE));
        vm.prank(GOVERNANCE);
        dvp.revokeRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE);
    }
}
