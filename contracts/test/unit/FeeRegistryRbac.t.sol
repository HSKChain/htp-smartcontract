// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {Roles} from "src/libraries/Roles.sol";
import {FeeConfig, FeePolicyEpochConfig, ReasonCode} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

contract FeeRegistryRbacTest is FeeRegistryTestBase {
    function testAllMutationSelectorsRejectEveryCrossRole() public {
        FeePolicyEpochConfig memory epoch;
        FeeConfig memory config;
        bytes32 evidenceHash = bytes32(uint256(1));

        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.createFeePolicyEpoch, (epoch)));
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.sealFeePolicyEpoch, (uint64(1), bytes32(0))));
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.activateFeePolicyEpoch, (uint64(1), bytes32(0), bytes32(0))));
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.moveFeePolicyEpochToLegacyServing, (uint64(1), evidenceHash)));
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.closeFeePolicyEpoch, (uint64(1), evidenceHash)));
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.activateFeeVersion, (bytes32(0), bytes32(0))));
        _assertGovernanceOnly(
            abi.encodeCall(
                IFeeRegistry.unpauseFeeVersion, (bytes32(0), bytes32(0), ReasonCode.GOVERNANCE_ACTION, evidenceHash)
            )
        );
        _assertGovernanceOnly(
            abi.encodeCall(IFeeRegistry.deprecateFeeVersion, (bytes32(0), ReasonCode.GOVERNANCE_ACTION, evidenceHash))
        );
        _assertGovernanceOnly(abi.encodeCall(IFeeRegistry.registerDependentDvp, (address(dependentDvp), evidenceHash)));
        _assertGovernanceOnly(
            abi.encodeCall(IFeeRegistry.exemptRetiredDependentDvp, (address(dependentDvp), evidenceHash))
        );
        bytes memory upgradeCall = abi.encodeCall(IFeeRegistry.upgradeToAndCall, (address(1), bytes("")));
        _assertDenied(upgradeCall, CONFIGURER, Roles.UPGRADER_ROLE);
        _assertDenied(upgradeCall, PAUSER, Roles.UPGRADER_ROLE);

        bytes memory registerCall = abi.encodeCall(IFeeRegistry.registerFeeVersion, (config));
        _assertDenied(registerCall, address(timelock), Roles.CONFIGURER_ROLE);
        _assertDenied(registerCall, PAUSER, Roles.CONFIGURER_ROLE);

        bytes memory pauseCall =
            abi.encodeCall(IFeeRegistry.pauseFeeVersion, (bytes32(0), ReasonCode.SECURITY_INCIDENT, evidenceHash));
        _assertDenied(pauseCall, address(timelock), Roles.PAUSER_ROLE);
        _assertDenied(pauseCall, CONFIGURER, Roles.PAUSER_ROLE);
    }

    function _assertGovernanceOnly(bytes memory callData) private {
        _assertDenied(callData, CONFIGURER, Roles.GOVERNANCE_ROLE);
        _assertDenied(callData, PAUSER, Roles.GOVERNANCE_ROLE);
    }

    function _assertDenied(bytes memory callData, address caller, bytes32 requiredRole) private {
        vm.prank(caller);
        (bool success, bytes memory revertData) = address(feeRegistry).call(callData);
        assertFalse(success);
        assertEq(
            revertData,
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, requiredRole)
        );
    }
}
