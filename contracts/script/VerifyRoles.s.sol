// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script} from "forge-std/Script.sol";
import {CoreDeployment, DeploymentRoles} from "./DeployTypes.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Verifies the directly configured deployment role topology.
contract VerifyRoles is Script {
    bytes32 public constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error RoleVerificationFailed(bytes32 role, address target, address account);

    function verifyTopology(CoreDeployment calldata core, DeploymentRoles calldata roles) external view {
        address[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            address registry = registries[i];
            if (vm.load(registry, ERC1967_ADMIN_SLOT) != bytes32(0)) {
                revert RoleVerificationFailed("PROXY_ADMIN_NOT_ZERO", registry, address(0));
            }
            _requireRole(registry, Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin, true);
            _requireRole(registry, Roles.GOVERNANCE_ROLE, roles.governance, true);
            _requireRole(registry, Roles.UPGRADER_ROLE, roles.upgrader, true);
            _requireRole(registry, Roles.PAUSER_ROLE, roles.pauser, true);
            // 八个 Registry 共用同一个 CONFIGURER_ROLE 与同一个持有人。
            _requireRole(registry, Roles.CONFIGURER_ROLE, roles.configurer, true);
        }

        _requireRole(core.dvp, Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin, true);
        _requireRole(core.dvp, Roles.GOVERNANCE_ROLE, roles.governance, true);
        _requireRole(core.dvp, Roles.PAUSER_ROLE, roles.pauser, true);
        _requireRole(core.dvp, Roles.EXECUTOR_ROLE, roles.executor, true);
        // DvP 不可升级，也不参与配置登记：这两个角色必须为空。
        _requireRole(core.dvp, Roles.UPGRADER_ROLE, roles.upgrader, false);
        _requireRole(core.dvp, Roles.CONFIGURER_ROLE, roles.configurer, false);
    }

    function _requireRole(address target, bytes32 role, address account, bool expected) private view {
        if (IAccessControl(target).hasRole(role, account) != expected) {
            revert RoleVerificationFailed(role, target, account);
        }
    }

    function _registries(CoreDeployment calldata core) private pure returns (address[8] memory registries) {
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
}
