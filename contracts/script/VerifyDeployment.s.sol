// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {CoreDeployment, RegistryDeployment} from "./DeployTypes.sol";
import {IDvPSettlement} from "../src/interfaces/IDvPSettlement.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IAssetAdapter} from "../src/interfaces/IAssetAdapter.sol";
import {IAssetVersionRegistry} from "../src/interfaces/IAssetVersionRegistry.sol";
import {IFeeRegistry} from "../src/interfaces/IFeeRegistry.sol";
import {IPrincipalCalculator} from "../src/interfaces/IPrincipalCalculator.sol";
import {IPrincipalCalculatorRegistry} from "../src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "../src/interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "../src/libraries/ConfigId.sol";
import {HTPHashing} from "../src/libraries/HTPHashing.sol";
import {
    AdapterRecord,
    AdapterStatus,
    AssetVersionRecord,
    AssetVersionStatus,
    CalculatorStatus,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    PrincipalCalculatorRecord,
    SettlementTokenRecord,
    SettlementTokenStatus
} from "../src/types/HTPTypes.sol";

interface IERC20DecimalsView {
    function decimals() external view returns (uint8);
}

/// @notice Read-only post-deployment checks. The implementation slot is read
/// through Foundry's standard RPC/storage cheatcode; no production getter is required.
contract VerifyDeployment is Script {
    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error VerificationFailed(bytes32 check, address target);

    function verifyCore(
        CoreDeployment calldata core,
        bytes32 expectedDvpCodeHash,
        bytes32 expectedDeploymentVersionHash
    ) external view {
        _requireCode(core.currentStateValidatorFactory, "CURRENT_STATE_VALIDATOR_FACTORY");
        _requireCode(core.dvp, "DVP_CODE");
        if (core.dvp.codehash != expectedDvpCodeHash) revert VerificationFailed("DVP_CODE_HASH", core.dvp);

        _verifyRegistry(core.adapterRegistry);
        _verifyRegistry(core.calculatorRegistry);
        _verifyRegistry(core.settlementTokenRegistry);
        _verifyRegistry(core.assetVersionRegistry);
        _verifyRegistry(core.eligibilityRegistry);
        _verifyRegistry(core.feeRegistry);
        _verifyRegistry(core.marketRuleRegistry);
        _verifyRegistry(core.participantRegistry);

        IDvPSettlement dvp = IDvPSettlement(core.dvp);
        if (dvp.deploymentVersionHash() != expectedDeploymentVersionHash) {
            revert VerificationFailed("DVP_DEPLOYMENT_VERSION", core.dvp);
        }
        if (address(dvp.adapterRegistry()) != core.adapterRegistry.proxy) {
            revert VerificationFailed("DVP_ADAPTER_REGISTRY", core.dvp);
        }
        if (address(dvp.principalCalculatorRegistry()) != core.calculatorRegistry.proxy) {
            revert VerificationFailed("DVP_CALCULATOR_REGISTRY", core.dvp);
        }
        if (address(dvp.settlementTokenRegistry()) != core.settlementTokenRegistry.proxy) {
            revert VerificationFailed("DVP_SETTLEMENT_REGISTRY", core.dvp);
        }
        if (address(dvp.assetVersionRegistry()) != core.assetVersionRegistry.proxy) {
            revert VerificationFailed("DVP_ASSET_REGISTRY", core.dvp);
        }
        if (address(dvp.eligibilityRegistry()) != core.eligibilityRegistry.proxy) {
            revert VerificationFailed("DVP_ELIGIBILITY_REGISTRY", core.dvp);
        }
        if (address(dvp.feeRegistry()) != core.feeRegistry.proxy) {
            revert VerificationFailed("DVP_FEE_REGISTRY", core.dvp);
        }
        if (address(dvp.marketRuleRegistry()) != core.marketRuleRegistry.proxy) {
            revert VerificationFailed("DVP_MARKET_RULE_REGISTRY", core.dvp);
        }
        if (address(dvp.participantRegistry()) != core.participantRegistry.proxy) {
            revert VerificationFailed("DVP_PARTICIPANT_REGISTRY", core.dvp);
        }
    }

    function verifyDependentDvpRegistrations(CoreDeployment calldata core) external view {
        _verifyOnlyDependent(core.adapterRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.calculatorRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.settlementTokenRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.assetVersionRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.eligibilityRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.feeRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.marketRuleRegistry.proxy, core.dvp);
        _verifyOnlyDependent(core.participantRegistry.proxy, core.dvp);
    }

    function verifyAdapter(address registry, bytes32 configId, bytes32 capabilityHash, AdapterStatus expectedStatus)
        external
        view
    {
        AdapterRecord memory record = IAdapterRegistry(registry).getAdapter(configId);
        if (!record.exists || record.config.adapterConfigId != configId) {
            revert VerificationFailed("ADAPTER_CONFIG_ID", registry);
        }
        if (record.config.configHash != HTPHashing.hashAdapterConfig(record.config)) {
            revert VerificationFailed("ADAPTER_CONFIG_HASH", registry);
        }
        if (record.config.codeHash != record.config.adapter.codehash) {
            revert VerificationFailed("ADAPTER_RUNTIME_HASH", record.config.adapter);
        }
        if (IAssetAdapter(record.config.adapter).interfaceVersion() != record.config.interfaceVersion) {
            revert VerificationFailed("ADAPTER_INTERFACE_VERSION", record.config.adapter);
        }
        if (record.status != expectedStatus) revert VerificationFailed("ADAPTER_STATUS", registry);
        AdapterRecord memory current = IAdapterRegistry(registry).getCurrentAdapter(capabilityHash);
        if (current.config.adapterConfigId != configId) revert VerificationFailed("ADAPTER_CURRENT", registry);
        bytes32 derived = ConfigId.derive(
            ConfigId.ADAPTER_NAMESPACE,
            record.config.schemaVersion,
            block.chainid,
            capabilityHash,
            record.config.revision
        );
        if (derived != configId) revert VerificationFailed("ADAPTER_DERIVED_ID", registry);
    }

    function verifyCalculator(address registry, bytes32 configId, CalculatorStatus expectedStatus) external view {
        PrincipalCalculatorRecord memory record =
            IPrincipalCalculatorRegistry(registry).getPrincipalCalculator(configId);
        if (!record.exists || record.config.calculatorConfigId != configId) {
            revert VerificationFailed("CALCULATOR_CONFIG_ID", registry);
        }
        if (record.config.configHash != HTPHashing.hashPrincipalCalculatorConfig(record.config)) {
            revert VerificationFailed("CALCULATOR_CONFIG_HASH", registry);
        }
        if (record.config.codeHash != record.config.calculator.codehash) {
            revert VerificationFailed("CALCULATOR_RUNTIME_HASH", record.config.calculator);
        }
        if (IPrincipalCalculator(record.config.calculator).interfaceVersion() != record.config.interfaceVersion) {
            revert VerificationFailed("CALCULATOR_INTERFACE_VERSION", record.config.calculator);
        }
        if (record.status != expectedStatus) revert VerificationFailed("CALCULATOR_STATUS", registry);
        PrincipalCalculatorRecord memory current =
            IPrincipalCalculatorRegistry(registry).getCurrentPrincipalCalculator(record.config.assetClass);
        if (current.config.calculatorConfigId != configId) revert VerificationFailed("CALCULATOR_CURRENT", registry);
        bytes32 derived = ConfigId.derive(
            ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE,
            record.config.schemaVersion,
            block.chainid,
            bytes32(uint256(record.config.assetClass)),
            record.config.revision
        );
        if (derived != configId) revert VerificationFailed("CALCULATOR_DERIVED_ID", registry);
    }

    function verifySettlementToken(address registry, bytes32 configId, SettlementTokenStatus expectedStatus)
        external
        view
    {
        SettlementTokenRecord memory record = ISettlementTokenRegistry(registry).getSettlementToken(configId);
        if (!record.exists || record.config.configId != configId) {
            revert VerificationFailed("SETTLEMENT_CONFIG_ID", registry);
        }
        if (record.config.configHash != HTPHashing.hashSettlementTokenConfig(record.config)) {
            revert VerificationFailed("SETTLEMENT_CONFIG_HASH", registry);
        }
        bytes32 derived = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            record.config.schemaVersion,
            block.chainid,
            bytes32(uint256(uint160(record.config.settlementToken))),
            record.config.revision
        );
        if (derived != configId) revert VerificationFailed("SETTLEMENT_DERIVED_ID", registry);
        _verifyToken(record.config.settlementToken, record.config.settlementTokenDecimals, record.config.tokenCodeHash);
        if (record.config.implementation != address(0)) {
            _verifyImplementation(
                record.config.settlementToken, record.config.implementation, record.config.implementationCodeHash
            );
        }
        if (record.status != expectedStatus) revert VerificationFailed("SETTLEMENT_STATUS", registry);
        SettlementTokenRecord memory current =
            ISettlementTokenRegistry(registry).getCurrentSettlementToken(record.config.settlementToken);
        if (current.config.configId != configId) revert VerificationFailed("SETTLEMENT_CURRENT", registry);
    }

    function verifyFee(
        address registry,
        uint64 feePolicyEpoch,
        bytes32 feeVersionId,
        bytes32 assetVersionId,
        FeePolicyEpochStatus expectedEpochStatus,
        FeeVersionStatus expectedVersionStatus
    ) external view {
        FeePolicyEpochRecord memory epoch = IFeeRegistry(registry).getFeePolicyEpoch(feePolicyEpoch);
        if (!epoch.exists || epoch.config.feePolicyEpoch != feePolicyEpoch) {
            revert VerificationFailed("FEE_EPOCH_ID", registry);
        }
        if (epoch.config.configHash != HTPHashing.hashFeePolicyEpochConfig(epoch.config)) {
            revert VerificationFailed("FEE_EPOCH_HASH", registry);
        }
        if (epoch.status != expectedEpochStatus) revert VerificationFailed("FEE_EPOCH_STATUS", registry);

        FeeVersionRecord memory version = IFeeRegistry(registry).getFeeVersion(feeVersionId);
        if (!version.exists || version.config.feeVersionId != feeVersionId) {
            revert VerificationFailed("FEE_VERSION_ID", registry);
        }
        if (version.config.configHash != HTPHashing.hashFeeConfig(version.config)) {
            revert VerificationFailed("FEE_VERSION_HASH", registry);
        }
        bytes32 derived = ConfigId.derive(
            ConfigId.FEE_NAMESPACE,
            version.config.schemaVersion,
            block.chainid,
            version.config.matchedScopeHash,
            version.config.revision
        );
        if (derived != feeVersionId) revert VerificationFailed("FEE_DERIVED_ID", registry);
        if (version.status != expectedVersionStatus) revert VerificationFailed("FEE_VERSION_STATUS", registry);
        (bytes32 currentId, bytes32 matchedScopeHash) =
            IFeeRegistry(registry).resolveApplicableFee(feePolicyEpoch, assetVersionId);
        if (currentId != feeVersionId || matchedScopeHash != version.config.matchedScopeHash) {
            revert VerificationFailed("FEE_CURRENT", registry);
        }
    }

    function verifyAssetVersion(
        address registry,
        bytes32 assetVersionId,
        AssetVersionStatus expectedStatus,
        address expectedDvp,
        bytes32 expectedDeploymentVersionHash
    ) external view {
        AssetVersionRecord memory record = IAssetVersionRegistry(registry).getAssetVersion(assetVersionId);
        if (!record.exists || record.config.assetVersionId != assetVersionId) {
            revert VerificationFailed("ASSET_VERSION_ID", registry);
        }
        if (record.config.configHash != HTPHashing.hashAssetVersionConfig(record.config)) {
            revert VerificationFailed("ASSET_CONFIG_HASH", registry);
        }
        bytes32 derived = ConfigId.assetVersion(
            record.config.schemaVersion,
            record.config.economicAssetIdHash,
            block.chainid,
            record.config.assetToken,
            record.config.versionNo
        );
        if (derived != assetVersionId) revert VerificationFailed("ASSET_DERIVED_ID", registry);
        _verifyToken(record.config.assetToken, record.config.assetDecimals, record.config.tokenCodeHash);
        if (record.config.implementation != address(0)) {
            _verifyImplementation(
                record.config.assetToken, record.config.implementation, record.config.implementationCodeHash
            );
        }
        if (
            record.config.dvpContract != expectedDvp
                || record.config.deploymentVersionHash != expectedDeploymentVersionHash
        ) {
            revert VerificationFailed("ASSET_DVP_DOMAIN", registry);
        }
        if (record.status != expectedStatus) revert VerificationFailed("ASSET_STATUS", registry);
        AssetVersionRecord memory current =
            IAssetVersionRegistry(registry).getCurrentAssetVersion(record.config.assetToken);
        if (current.config.assetVersionId != assetVersionId) revert VerificationFailed("ASSET_CURRENT", registry);
    }

    function _verifyRegistry(RegistryDeployment calldata deployment) private view {
        _requireCode(deployment.proxy, "PROXY_CODE");
        _verifyImplementation(deployment.proxy, deployment.implementation, deployment.implementationCodeHash);
    }

    function _verifyImplementation(address proxy, address implementation, bytes32 expectedCodeHash) private view {
        address slotImplementation = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
        if (slotImplementation != implementation) revert VerificationFailed("ERC1967_IMPLEMENTATION", proxy);
        if (implementation.codehash != expectedCodeHash) {
            revert VerificationFailed("IMPLEMENTATION_CODE_HASH", implementation);
        }
    }

    function _verifyOnlyDependent(address registry, address expectedDvp) private view {
        (bool countSuccess, bytes memory countData) =
            registry.staticcall(abi.encodeWithSignature("getDependentDvpCount()"));
        if (!countSuccess || countData.length != 32 || abi.decode(countData, (uint256)) != 1) {
            revert VerificationFailed("DEPENDENT_DVP_COUNT", registry);
        }
        (bool entrySuccess, bytes memory entryData) =
            registry.staticcall(abi.encodeWithSignature("getDependentDvp(uint256)", 0));
        if (!entrySuccess || entryData.length != 64) revert VerificationFailed("DEPENDENT_DVP_ABI", registry);
        (address dvp, bool retiredExempt) = abi.decode(entryData, (address, bool));
        if (dvp != expectedDvp || retiredExempt) revert VerificationFailed("DEPENDENT_DVP_ENTRY", registry);
    }

    function _verifyToken(address token, uint8 expectedDecimals, bytes32 expectedCodeHash) private view {
        if (token.codehash != expectedCodeHash) revert VerificationFailed("TOKEN_CODE_HASH", token);
        try IERC20DecimalsView(token).decimals() returns (uint8 actualDecimals) {
            if (actualDecimals != expectedDecimals) revert VerificationFailed("TOKEN_DECIMALS", token);
        } catch {
            revert VerificationFailed("TOKEN_DECIMALS_ABI", token);
        }
    }

    function _requireCode(address target, bytes32 check) private view {
        if (target == address(0) || target.code.length == 0) revert VerificationFailed(check, target);
    }
}
