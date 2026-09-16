// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {CoreDeployment, DeploymentConfig, DeploymentRoles, RegistryDeployment} from "./DeployTypes.sol";
import {RegistryDeploymentPrimitives} from "./RegistryDeploymentPrimitives.sol";
import {DvPRegistries, DvPRoles, DvPSettlement} from "../src/DvPSettlement.sol";
import {EligibilityRegistry} from "../src/registry/EligibilityRegistry.sol";
import {ParticipantRegistry} from "../src/registry/ParticipantRegistry.sol";
import {DvPCurrentStateValidatorFactory} from "../src/validation/DvPCurrentStateValidatorFactory.sol";

abstract contract CoreDeploymentTopology is RegistryDeploymentPrimitives {
    error CreateAddressMismatch(address expected, address actual);

    uint64 internal constant CREATES_BEFORE_DVP = 17;
    uint64 internal constant TOTAL_CORE_CREATES = CREATES_BEFORE_DVP + 1;

    function _deployCoreTopology(DeploymentConfig memory config, address predictedDvp)
        internal
        returns (CoreDeployment memory deployment)
    {
        deployment.adapterRegistry = _deployAdapterRegistry(config.roles);
        deployment.calculatorRegistry = _deployCalculatorRegistry(config.roles);
        deployment.settlementTokenRegistry =
            _deploySettlementTokenRegistry(config.roles, deployment.adapterRegistry.proxy);
        deployment.assetVersionRegistry = _deployAssetVersionRegistry(
            config.roles,
            deployment.settlementTokenRegistry.proxy,
            deployment.adapterRegistry.proxy,
            deployment.calculatorRegistry.proxy
        );
        deployment.eligibilityRegistry = _deployEligibilityRegistry(config.roles);
        deployment.marketRuleRegistry = _deployMarketRuleRegistry(
            config.roles, deployment.assetVersionRegistry.proxy, deployment.settlementTokenRegistry.proxy
        );
        deployment.feeRegistry = _deployFeeRegistry(
            config.roles, deployment.assetVersionRegistry.proxy, deployment.settlementTokenRegistry.proxy
        );
        deployment.participantRegistry = _deployParticipantRegistry(config.roles);

        deployment.currentStateValidatorFactory = address(new DvPCurrentStateValidatorFactory());
        deployment.dvp = address(
            new DvPSettlement(
                DvPRoles({
                    defaultAdmin: config.roles.defaultAdmin,
                    governance: config.roles.governance,
                    pauser: config.roles.pauser,
                    executor: config.roles.executor
                }),
                DvPRegistries({
                    participant: deployment.participantRegistry.proxy,
                    assetVersion: deployment.assetVersionRegistry.proxy,
                    eligibility: deployment.eligibilityRegistry.proxy,
                    fee: deployment.feeRegistry.proxy,
                    marketRule: deployment.marketRuleRegistry.proxy,
                    settlementToken: deployment.settlementTokenRegistry.proxy,
                    adapter: deployment.adapterRegistry.proxy,
                    principalCalculator: deployment.calculatorRegistry.proxy
                }),
                config.chainId,
                config.deploymentVersion,
                deployment.currentStateValidatorFactory
            )
        );
        if (deployment.dvp != predictedDvp) revert CreateAddressMismatch(predictedDvp, deployment.dvp);
    }

    function _deployEligibilityRegistry(DeploymentRoles memory roles)
        internal
        returns (RegistryDeployment memory deployment)
    {
        EligibilityRegistry implementation = new EligibilityRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                EligibilityRegistry.initialize,
                (roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.configurer)
            )
        );
    }

    function _deployParticipantRegistry(DeploymentRoles memory roles)
        internal
        returns (RegistryDeployment memory deployment)
    {
        ParticipantRegistry implementation = new ParticipantRegistry();
        deployment = _deployRegistryProxy(
            address(implementation),
            abi.encodeCall(
                ParticipantRegistry.initialize,
                (roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.configurer)
            )
        );
    }

    function _predictDvpAddress(address createDeployer, uint64 expectedFirstCreateNonce)
        internal
        pure
        returns (address)
    {
        return _computeCreateAddress(createDeployer, expectedFirstCreateNonce + CREATES_BEFORE_DVP);
    }

    function _computeCreateAddress(address deployer, uint64 nonce) internal pure returns (address) {
        bytes memory rlp;
        if (nonce == 0) {
            rlp = abi.encodePacked(hex"d694", deployer, hex"80");
        } else if (nonce <= 0x7f) {
            rlp = abi.encodePacked(hex"d694", deployer, uint8(nonce));
        } else if (nonce <= type(uint8).max) {
            rlp = abi.encodePacked(hex"d794", deployer, hex"81", uint8(nonce));
        } else if (nonce <= type(uint16).max) {
            rlp = abi.encodePacked(hex"d894", deployer, hex"82", uint16(nonce));
        } else if (nonce <= 0xffffff) {
            rlp = abi.encodePacked(hex"d994", deployer, hex"83", bytes3(uint24(nonce)));
        } else if (nonce <= type(uint32).max) {
            rlp = abi.encodePacked(hex"da94", deployer, hex"84", uint32(nonce));
        } else if (nonce <= 0xffffffffff) {
            rlp = abi.encodePacked(hex"db94", deployer, hex"85", bytes5(uint40(nonce)));
        } else if (nonce <= 0xffffffffffff) {
            rlp = abi.encodePacked(hex"dc94", deployer, hex"86", bytes6(uint48(nonce)));
        } else if (nonce <= 0xffffffffffffff) {
            rlp = abi.encodePacked(hex"dd94", deployer, hex"87", bytes7(uint56(nonce)));
        } else {
            rlp = abi.encodePacked(hex"de94", deployer, hex"88", nonce);
        }
        return address(uint160(uint256(keccak256(rlp))));
    }
}
