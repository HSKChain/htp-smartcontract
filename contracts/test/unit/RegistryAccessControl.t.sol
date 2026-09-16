// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {RegistryTestBase} from "../helpers/RegistryTestBase.sol";

contract RegistryAccessHarness is UUPSRegistryBase {
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }

    function setParticipant() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function registerAssetVersion() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function setEligibility() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function registerFeeVersion() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function registerSettlementToken() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function registerAdapter() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function registerPrincipalCalculator() external onlyRole(Roles.CONFIGURER_ROLE) {}

    function pauseAction() external onlyRole(Roles.PAUSER_ROLE) {}

    function unpauseAction() external onlyRole(Roles.GOVERNANCE_ROLE) {}

    function activateAction() external onlyRole(Roles.GOVERNANCE_ROLE) {}

    function deprecateAction() external onlyRole(Roles.GOVERNANCE_ROLE) {}

    function implementationVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract RegistryAccessHarnessV2 is RegistryAccessHarness {
    function implementationVersion() external pure override returns (uint256) {
        return 2;
    }
}

contract RegistryAccessControlTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);

    // 单一 CONFIGURER 覆盖八个 Registry 的全部登记/写入入口。
    // 这是角色合并后的预期行为：不再有「跨 Registry 被拒」的边界。
    function testSingleConfigurerCoversEveryRegistryWritePath() public {
        address configurer = address(0x3001);
        RegistryAccessHarness registry = _deployAccessRegistry(configurer);

        bytes4[7] memory writePaths = _writePathSelectors();
        for (uint256 i = 0; i < writePaths.length; ++i) {
            _callSelector(registry, writePaths[i], configurer);
        }
    }

    // 非 CONFIGURER 在每一条写入路径上都被拒，且要求的角色统一是 CONFIGURER_ROLE。
    function testNonConfigurerIsRejectedOnEveryRegistryWritePath() public {
        RegistryAccessHarness registry = _deployAccessRegistry(address(0x3001));
        address outsider = address(0xBAD);

        bytes4[7] memory writePaths = _writePathSelectors();
        for (uint256 i = 0; i < writePaths.length; ++i) {
            _expectAccountDenied(registry, writePaths[i], outsider, Roles.CONFIGURER_ROLE);
        }
    }

    function testIndependentPauserCanOnlyUsePausePath() public {
        RegistryAccessHarness registry = _deployAccessRegistry(address(0x3001));

        vm.prank(PAUSER);
        registry.pauseAction();

        _expectPauserDenied(registry, RegistryAccessHarness.unpauseAction.selector, Roles.GOVERNANCE_ROLE);
        _expectPauserDenied(registry, RegistryAccessHarness.activateAction.selector, Roles.GOVERNANCE_ROLE);
        _expectPauserDenied(registry, RegistryAccessHarness.deprecateAction.selector, Roles.GOVERNANCE_ROLE);

        RegistryAccessHarnessV2 nextImplementation = new RegistryAccessHarnessV2();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(PAUSER);
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function testConfigurerCannotUseGovernanceOrUpgradePaths() public {
        address configurer = address(0x3001);
        RegistryAccessHarness registry = _deployAccessRegistry(configurer);

        _expectAccountDenied(registry, RegistryAccessHarness.activateAction.selector, configurer, Roles.GOVERNANCE_ROLE);
        _expectAccountDenied(registry, RegistryAccessHarness.unpauseAction.selector, configurer, Roles.GOVERNANCE_ROLE);
        _expectAccountDenied(
            registry, RegistryAccessHarness.deprecateAction.selector, configurer, Roles.GOVERNANCE_ROLE
        );

        RegistryAccessHarnessV2 nextImplementation = new RegistryAccessHarnessV2();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, configurer, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(configurer);
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function testTimelockGovernanceCanUseRecoveryAndUpgradePaths() public {
        RegistryAccessHarness registry = _deployAccessRegistry(address(0x3001));
        _satisfyUpgradeGate(address(registry));

        vm.startPrank(address(timelock));
        registry.unpauseAction();
        registry.activateAction();
        registry.deprecateAction();
        RegistryAccessHarnessV2 nextImplementation = new RegistryAccessHarnessV2();
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));
        vm.stopPrank();

        assertEq(registry.implementationVersion(), 2);
    }

    function testCommonAndOperationalRoleAdminsAreDefaultAdmin() public {
        RegistryAccessHarness registry = _deployAccessRegistry(address(0x3001));

        assertEq(registry.getRoleAdmin(Roles.GOVERNANCE_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.UPGRADER_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.PAUSER_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(Roles.CONFIGURER_ROLE), Roles.DEFAULT_ADMIN_ROLE);
    }

    function testUnlistedSelectorIsRejected() public {
        RegistryAccessHarness registry = _deployAccessRegistry(address(0x3001));

        (bool success, bytes memory returndata) = address(registry).call(hex"deadbeef");
        assertFalse(success);
        assertEq(returndata.length, 0);
    }

    function _writePathSelectors() private pure returns (bytes4[7] memory selectors) {
        selectors[0] = RegistryAccessHarness.setParticipant.selector;
        selectors[1] = RegistryAccessHarness.registerAssetVersion.selector;
        selectors[2] = RegistryAccessHarness.setEligibility.selector;
        selectors[3] = RegistryAccessHarness.registerFeeVersion.selector;
        selectors[4] = RegistryAccessHarness.registerSettlementToken.selector;
        selectors[5] = RegistryAccessHarness.registerAdapter.selector;
        selectors[6] = RegistryAccessHarness.registerPrincipalCalculator.selector;
    }

    function _deployAccessRegistry(address configurer) private returns (RegistryAccessHarness) {
        RegistryAccessHarness implementation = new RegistryAccessHarness();
        return RegistryAccessHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    RegistryAccessHarness.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, configurer)
                )
            )
        );
    }

    function _callSelector(RegistryAccessHarness registry, bytes4 selector, address actor) private {
        vm.prank(actor);
        (bool success, bytes memory returndata) = address(registry).call(abi.encodeWithSelector(selector));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    function _expectPauserDenied(RegistryAccessHarness registry, bytes4 selector, bytes32 requiredRole) private {
        _expectAccountDenied(registry, selector, PAUSER, requiredRole);
    }

    function _expectAccountDenied(
        RegistryAccessHarness registry,
        bytes4 selector,
        address account,
        bytes32 requiredRole
    ) private {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, requiredRole)
        );
        vm.prank(account);
        (bool success, bytes memory returndata) = address(registry).call(abi.encodeWithSelector(selector));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}
