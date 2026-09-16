// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeploymentRoles, RegistryDeployment} from "./DeployTypes.sol";
import {AdapterRegistry} from "../src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "../src/registry/AssetVersionRegistry.sol";
import {FeeRegistry} from "../src/registry/FeeRegistry.sol";
import {MarketRuleRegistry} from "../src/registry/MarketRuleRegistry.sol";
import {PrincipalCalculatorRegistry} from "../src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "../src/registry/SettlementTokenRegistry.sol";

abstract contract RegistryDeploymentPrimitives {
    function _deployAdapterRegistry(DeploymentRoles memory roles)
        internal
        returns (RegistryDeployment memory deployment)
    {
        AdapterRegistry implementation = new AdapterRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                AdapterRegistry.initialize,
                (roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.configurer)
            )
        );
    }

    function _deployCalculatorRegistry(DeploymentRoles memory roles)
        internal
        returns (RegistryDeployment memory deployment)
    {
        PrincipalCalculatorRegistry implementation = new PrincipalCalculatorRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                PrincipalCalculatorRegistry.initialize,
                (roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.configurer)
            )
        );
    }

    function _deploySettlementTokenRegistry(DeploymentRoles memory roles, address adapterRegistry)
        internal
        returns (RegistryDeployment memory deployment)
    {
        SettlementTokenRegistry implementation = new SettlementTokenRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                SettlementTokenRegistry.initialize,
                (roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.configurer, adapterRegistry)
            )
        );
    }

    function _deployAssetVersionRegistry(
        DeploymentRoles memory roles,
        address settlementTokenRegistry,
        address adapterRegistry,
        address calculatorRegistry
    ) internal returns (RegistryDeployment memory deployment) {
        AssetVersionRegistry implementation = new AssetVersionRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                AssetVersionRegistry.initialize,
                (
                    roles.defaultAdmin,
                    roles.governance,
                    roles.upgrader,
                    roles.pauser,
                    roles.configurer,
                    settlementTokenRegistry,
                    adapterRegistry,
                    calculatorRegistry
                )
            )
        );
    }

    function _deployFeeRegistry(
        DeploymentRoles memory roles,
        address assetVersionRegistry,
        address settlementTokenRegistry
    ) internal returns (RegistryDeployment memory deployment) {
        FeeRegistry implementation = new FeeRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                FeeRegistry.initialize,
                (
                    roles.defaultAdmin,
                    roles.governance,
                    roles.upgrader,
                    roles.pauser,
                    roles.configurer,
                    assetVersionRegistry,
                    settlementTokenRegistry
                )
            )
        );
    }

    function _deployMarketRuleRegistry(
        DeploymentRoles memory roles,
        address assetVersionRegistry,
        address settlementTokenRegistry
    ) internal returns (RegistryDeployment memory deployment) {
        MarketRuleRegistry implementation = new MarketRuleRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                MarketRuleRegistry.initialize,
                (
                    roles.defaultAdmin,
                    roles.governance,
                    roles.upgrader,
                    roles.pauser,
                    roles.configurer,
                    assetVersionRegistry,
                    settlementTokenRegistry
                )
            )
        );
    }

    function _deployRegistryProxy(address implementation, bytes memory initializationData)
        internal
        returns (RegistryDeployment memory deployment)
    {
        deployment.implementation = implementation;
        deployment.implementationCodeHash = implementation.codehash;
        deployment.proxy = address(new ERC1967Proxy(implementation, initializationData));
    }
}
