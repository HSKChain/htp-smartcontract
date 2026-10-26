// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {CoreDeployment, DirectOperation, ExampleConfigs} from "./DeployTypes.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "../src/interfaces/IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "../src/interfaces/IFeeRegistry.sol";
import {IParticipantRegistry} from "../src/interfaces/IParticipantRegistry.sol";
import {IMarketRuleRegistry} from "../src/interfaces/IMarketRuleRegistry.sol";
import {IPrincipalCalculatorRegistry} from "../src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "../src/interfaces/ISettlementTokenRegistry.sol";

contract DeploymentOperationBuilder {
    function dependentDvpRegistration(CoreDeployment memory core, bytes32 evidenceHash)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](8);
        bytes memory payload =
            abi.encodeWithSelector(IAdapterRegistry.registerDependentDvp.selector, core.dvp, evidenceHash);
        operations[0] = _operation(core.adapterRegistry.proxy, payload);
        operations[1] = _operation(core.calculatorRegistry.proxy, payload);
        operations[2] = _operation(core.settlementTokenRegistry.proxy, payload);
        operations[3] = _operation(core.assetVersionRegistry.proxy, payload);
        operations[4] = _operation(core.eligibilityRegistry.proxy, payload);
        operations[5] = _operation(core.feeRegistry.proxy, payload);
        operations[6] = _operation(core.participantRegistry.proxy, payload);
        operations[7] = _operation(core.marketRuleRegistry.proxy, payload);
    }

    function calculatorRegistrations(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](3);
        for (uint256 i = 0; i < operations.length; ++i) {
            operations[i] = _operation(
                core.calculatorRegistry.proxy,
                abi.encodeWithSelector(
                    IPrincipalCalculatorRegistry.registerPrincipalCalculator.selector, configs.calculators[i]
                )
            );
        }
    }

    function adapterRegistrations(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        // Ondo GM shares USDY's capability chain and must be registered only
        // after USDY revision 1 has been activated.
        operations = new DirectOperation[](3);
        for (uint256 i = 0; i < operations.length; ++i) {
            operations[i] = _operation(
                core.adapterRegistry.proxy,
                abi.encodeWithSelector(IAdapterRegistry.registerAdapter.selector, configs.adapters[i])
            );
        }
    }

    function ondoGmAdapterRegistration(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.adapterRegistry.proxy,
            abi.encodeWithSelector(IAdapterRegistry.registerAdapter.selector, configs.adapters[3])
        );
    }

    function usdyAdapterActivation(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _adapterActivation(core, configs.adapters[2].adapterConfigId, configs.adapters[2].configHash);
    }

    function ondoGmAdapterActivation(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _adapterActivation(core, configs.adapters[3].adapterConfigId, configs.adapters[3].configHash);
    }

    function calculatorAdapterActivations(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        // USDY is deliberately left REGISTERED as a candidate; it is not part of
        // the active offline example until its external production baselines are approved.
        operations = new DirectOperation[](5);
        for (uint256 i = 0; i < 3; ++i) {
            operations[i] = _operation(
                core.calculatorRegistry.proxy,
                abi.encodeWithSelector(
                    IPrincipalCalculatorRegistry.activatePrincipalCalculator.selector,
                    configs.calculators[i].calculatorConfigId,
                    configs.calculators[i].configHash
                )
            );
        }
        for (uint256 i = 0; i < 2; ++i) {
            operations[i + 3] = _operation(
                core.adapterRegistry.proxy,
                abi.encodeWithSelector(
                    IAdapterRegistry.activateAdapter.selector,
                    configs.adapters[i].adapterConfigId,
                    configs.adapters[i].configHash
                )
            );
        }
    }

    function settlementTokenRegistration(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.settlementTokenRegistry.proxy,
            abi.encodeWithSelector(ISettlementTokenRegistry.registerSettlementToken.selector, configs.settlementToken)
        );
    }

    function settlementTokenActivation(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.settlementTokenRegistry.proxy,
            abi.encodeWithSelector(
                ISettlementTokenRegistry.activateSettlementToken.selector,
                configs.settlementToken.configId,
                configs.settlementToken.configHash
            )
        );
    }

    function assetVersionRegistration(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.assetVersionRegistry.proxy,
            abi.encodeWithSelector(IAssetVersionRegistry.registerAssetVersion.selector, configs.assetVersion)
        );
    }

    function assetVersionActivation(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.assetVersionRegistry.proxy,
            abi.encodeWithSelector(
                IAssetVersionRegistry.activateAssetVersion.selector,
                configs.assetVersion.assetVersionId,
                configs.assetVersion.configHash
            )
        );
    }

    function participantRegistrations(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](2);
        for (uint256 i = 0; i < operations.length; ++i) {
            operations[i] = _operation(
                core.participantRegistry.proxy,
                abi.encodeWithSelector(IParticipantRegistry.setParticipant.selector, configs.participants[i], uint64(0))
            );
        }
    }

    function eligibilityUpdates(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](2);
        for (uint256 i = 0; i < operations.length; ++i) {
            operations[i] = _operation(
                core.eligibilityRegistry.proxy,
                abi.encodeWithSelector(
                    IEligibilityRegistry.setEligibility.selector, configs.eligibilities[i], uint64(0)
                )
            );
        }
    }

    function feeEpochCreation(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.feeRegistry.proxy, abi.encodeWithSelector(IFeeRegistry.createFeePolicyEpoch.selector, configs.feeEpoch)
        );
    }

    function feeVersionRegistration(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.feeRegistry.proxy, abi.encodeWithSelector(IFeeRegistry.registerFeeVersion.selector, configs.fee)
        );
    }

    function feeFinalization(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](3);
        operations[0] = _operation(
            core.feeRegistry.proxy,
            abi.encodeWithSelector(
                IFeeRegistry.sealFeePolicyEpoch.selector, configs.feeEpoch.feePolicyEpoch, configs.feeEpoch.configHash
            )
        );
        operations[1] = _operation(
            core.feeRegistry.proxy,
            abi.encodeWithSelector(
                IFeeRegistry.activateFeeVersion.selector, configs.fee.feeVersionId, configs.fee.configHash
            )
        );
        // N1: Multi-scope deployments must activate every intended fee before using this readiness witness.
        operations[2] = _operation(
            core.feeRegistry.proxy,
            abi.encodeWithSelector(
                IFeeRegistry.activateFeePolicyEpoch.selector,
                configs.feeEpoch.feePolicyEpoch,
                configs.feeEpoch.configHash,
                configs.fee.feeVersionId
            )
        );
    }

    function marketRuleRegistration(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.marketRuleRegistry.proxy,
            abi.encodeWithSelector(IMarketRuleRegistry.registerMarketRule.selector, configs.marketRule)
        );
    }

    function marketRuleFinalization(CoreDeployment memory core, ExampleConfigs memory configs)
        public
        pure
        returns (DirectOperation[] memory operations)
    {
        operations = new DirectOperation[](2);
        operations[0] = _operation(
            core.marketRuleRegistry.proxy,
            abi.encodeWithSelector(
                IMarketRuleRegistry.sealMarketRule.selector,
                configs.marketRule.marketRuleConfigId,
                configs.marketRule.configHash
            )
        );
        operations[1] = _operation(
            core.marketRuleRegistry.proxy,
            abi.encodeWithSelector(
                IMarketRuleRegistry.activateMarketRule.selector,
                configs.marketRule.marketRuleConfigId,
                configs.marketRule.configHash
            )
        );
    }

    function _operation(address target, bytes memory data) private pure returns (DirectOperation memory) {
        return DirectOperation({target: target, data: data});
    }

    function _adapterActivation(CoreDeployment memory core, bytes32 configId, bytes32 configHash)
        private
        pure
        returns (DirectOperation memory)
    {
        return _operation(
            core.adapterRegistry.proxy,
            abi.encodeWithSelector(IAdapterRegistry.activateAdapter.selector, configId, configHash)
        );
    }
}
