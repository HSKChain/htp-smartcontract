// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract RegistryInitializerFixture is Initializable {
    uint256 public initializedValue;
    address public initializedBy;

    function initialize(uint256 value) external initializer {
        initializedValue = value;
        initializedBy = msg.sender;
    }
}

contract RegistryTestBaseTest is RegistryTestBase {
    function setUp() public override {
        super.setUp();
    }

    function testProxyFactoryAtomicallyInitializesImplementation() public {
        RegistryInitializerFixture implementation = new RegistryInitializerFixture();
        address proxy =
            _deployProxy(address(implementation), abi.encodeCall(RegistryInitializerFixture.initialize, (42)));
        RegistryInitializerFixture initialized = RegistryInitializerFixture(proxy);

        assertEq(initialized.initializedValue(), 42);
        assertEq(initialized.initializedBy(), address(this));
        vm.expectRevert(bytes4(0xf92ee8a9));
        initialized.initialize(43);
    }

    function testTimelockFixtureUsesExplicitGovernanceRoles() public view {
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), GOVERNANCE));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), GOVERNANCE));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), GOVERNANCE));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), GOVERNANCE));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function testBaseProvidesOnlyGovernanceViewMock() public view {
        assertFalse(dependentDvp.globalPaused());
        assertFalse(dependentDvp.retired());
        assertEq(dependentDvp.deploymentVersionHash(), DEPLOYMENT_VERSION_HASH);
    }
}
