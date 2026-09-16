// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {RegistryTestBase} from "../helpers/RegistryTestBase.sol";

contract RegistryInitializationHarness is UUPSRegistryBase {
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }
}

contract RegistryInitializationTest is RegistryTestBase {
    address internal constant PAUSER = address(0x1002);
    address internal constant CONFIGURER = address(0x1003);

    function deployRegistryProxy(address implementation, bytes calldata initializationData) external returns (address) {
        return _deployProxy(implementation, initializationData);
    }

    function testImplementationCannotBeInitializedButProxyIsAtomicallyInitialized() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER);

        RegistryInitializationHarness registry = RegistryInitializationHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    RegistryInitializationHarness.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertFalse(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(this)));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER);
    }

    function testProxyFactoryRejectsEmptyInitializationCalldata() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();

        vm.expectRevert(RegistryTestBase.EmptyInitializationData.selector);
        this.deployRegistryProxy(address(implementation), bytes(""));
    }

    function testInitializationAllowsSplitRoleHolders() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();
        address upgrader = address(0x1004);
        RegistryInitializationHarness registry = RegistryInitializationHarness(
            this.deployRegistryProxy(
                address(implementation),
                abi.encodeCall(
                    RegistryInitializationHarness.initialize,
                    (address(timelock), GOVERNANCE, upgrader, PAUSER, CONFIGURER)
                )
            )
        );

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, upgrader));
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
    }

    function testInitializationRejectsZeroConfigurerWithConfigurerRoleContext() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.CONFIGURER_ROLE, address(0)));
        this.deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                RegistryInitializationHarness.initialize,
                (address(timelock), address(timelock), address(timelock), PAUSER, address(0))
            )
        );
    }

    function testInitializationAllowsOneAddressToHoldAllRoles() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();
        address unified = address(0x1111);
        RegistryInitializationHarness registry = RegistryInitializationHarness(
            this.deployRegistryProxy(
                address(implementation),
                abi.encodeCall(RegistryInitializationHarness.initialize, (unified, unified, unified, unified, unified))
            )
        );

        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, unified));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, unified));
        assertTrue(registry.hasRole(Roles.UPGRADER_ROLE, unified));
        assertTrue(registry.hasRole(Roles.PAUSER_ROLE, unified));
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, unified));
    }

    function testInitializationRejectsZeroRoleHolderWithRoleContext() public {
        RegistryInitializationHarness implementation = new RegistryInitializationHarness();

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidRoleHolder.selector, Roles.GOVERNANCE_ROLE, address(0)));
        this.deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                RegistryInitializationHarness.initialize,
                (address(timelock), address(0), address(timelock), PAUSER, CONFIGURER)
            )
        );
    }
}
