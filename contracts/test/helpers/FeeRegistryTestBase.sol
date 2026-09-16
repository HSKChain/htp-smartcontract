// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DeploymentRoles} from "script/DeployTypes.sol";
import {RegistryDeploymentPrimitives} from "script/RegistryDeploymentPrimitives.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    PermitCapability,
    PrincipalCalculatorConfig,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "./RegistryTestBase.sol";

contract FeeAssetTokenFixture {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract FeeSettlementTokenFixture {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

abstract contract FeeRegistryTestBase is RegistryTestBase, RegistryDeploymentPrimitives {
    address internal constant PAUSER = address(0x2301);
    address internal constant CONFIGURER = address(0x3301);
    address internal constant COLLECTOR = address(0xC011);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE301));
    bytes32 internal constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0xA55E7));

    AdapterRegistry internal adapterRegistry;
    PrincipalCalculatorRegistry internal calculatorRegistry;
    SettlementTokenRegistry internal settlementTokenRegistry;
    AssetVersionRegistry internal assetVersionRegistry;
    FeeRegistry internal feeRegistry;
    IAssetAdapter internal adapter;
    IPrincipalCalculator internal calculator;
    FeeAssetTokenFixture internal assetToken;
    FeeSettlementTokenFixture internal settlementToken;
    AdapterConfig internal adapterConfig;
    PrincipalCalculatorConfig internal calculatorConfig;
    SettlementTokenConfig internal settlementTokenConfig;
    AssetVersionConfig internal assetVersionConfig;

    function setUp() public virtual override {
        super.setUp();
        DeploymentRoles memory roles = _feeGraphRoles();
        adapterRegistry = AdapterRegistry(_deployAdapterRegistry(roles).proxy);
        adapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dependentDvp))));
        adapterConfig = _adapterConfig();
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(adapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(adapterConfig.adapterConfigId, adapterConfig.configHash);

        calculatorRegistry = PrincipalCalculatorRegistry(_deployCalculatorRegistry(roles).proxy);
        calculator = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        calculatorConfig = _calculatorConfig();
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(calculatorConfig);
        vm.prank(address(timelock));
        calculatorRegistry.activatePrincipalCalculator(calculatorConfig.calculatorConfigId, calculatorConfig.configHash);

        settlementTokenRegistry =
            SettlementTokenRegistry(_deploySettlementTokenRegistry(roles, address(adapterRegistry)).proxy);
        settlementToken = new FeeSettlementTokenFixture();
        settlementTokenConfig = _settlementTokenConfig();
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(settlementTokenConfig);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(
            settlementTokenConfig.configId, settlementTokenConfig.configHash
        );

        assetVersionRegistry = AssetVersionRegistry(
            _deployAssetVersionRegistry(
                roles, address(settlementTokenRegistry), address(adapterRegistry), address(calculatorRegistry)
            )
            .proxy
        );
        vm.prank(address(timelock));
        assetVersionRegistry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        assetToken = new FeeAssetTokenFixture();
        assetVersionConfig = _assetVersionConfig();
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(assetVersionConfig);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(assetVersionConfig.assetVersionId, assetVersionConfig.configHash);

        feeRegistry = FeeRegistry(
            _deployFeeRegistry(roles, address(assetVersionRegistry), address(settlementTokenRegistry)).proxy
        );
    }

    function _feeGraphRoles() private view returns (DeploymentRoles memory roles) {
        roles = DeploymentRoles({
            defaultAdmin: address(timelock),
            governance: address(timelock),
            upgrader: address(timelock),
            pauser: PAUSER,
            executor: address(0x3001),
            configurer: CONFIGURER
        });
    }

    function _createEpoch(uint64 feePolicyEpoch) internal returns (FeePolicyEpochConfig memory config) {
        config = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: feePolicyEpoch,
            chainId: block.chainid,
            quoteValidFrom: uint64(block.timestamp + 1 days),
            quoteValidUntil: uint64(block.timestamp + 30 days),
            settlementValidUntil: uint64(block.timestamp + 60 days),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(config);
    }

    function _sealEpoch(FeePolicyEpochConfig memory config) internal {
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(config.feePolicyEpoch, config.configHash);
    }

    function _activateEpoch(FeePolicyEpochConfig memory config) internal {
        vm.warp(config.quoteValidFrom);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(config.feePolicyEpoch, config.configHash);
    }

    function _feeConfig(
        uint64 feePolicyEpoch,
        ScopeType scopeType,
        bytes32 scopeKeyHash,
        uint32 revision,
        bytes32 replacesFeeVersionId
    ) internal view returns (FeeConfig memory config) {
        FeePolicyEpochRecord memory epoch = feeRegistry.getFeePolicyEpoch(feePolicyEpoch);
        bytes32 matchedScopeHash = FeeScope.matchedHash(feePolicyEpoch, scopeType, scopeKeyHash);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, revision),
            revision: revision,
            chainId: block.chainid,
            feePolicyEpoch: feePolicyEpoch,
            scopeType: scopeType,
            scopeKeyHash: scopeKeyHash,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: epoch.config.quoteValidFrom,
            validUntil: epoch.config.settlementValidUntil,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: replacesFeeVersionId,
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
    }

    function _registerFee(FeeConfig memory config) internal {
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(config);
    }

    function _adapterConfig() private view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = adapter.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, 1),
            revision: 1,
            chainId: block.chainid,
            adapter: address(adapter),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(adapter).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: adapter.providerHash(),
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _calculatorConfig() private view returns (PrincipalCalculatorConfig memory config) {
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(calculator),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(calculator).codehash,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
    }

    function _settlementTokenConfig() private view returns (SettlementTokenConfig memory config) {
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
                1,
                block.chainid,
                bytes32(uint256(uint160(address(settlementToken)))),
                1
            ),
            revision: 1,
            chainId: block.chainid,
            settlementToken: address(settlementToken),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: 6,
            tokenCodeHash: address(settlementToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.UNSUPPORTED,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }

    function _assetVersionConfig() private view returns (AssetVersionConfig memory config) {
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: ECONOMIC_ASSET_ID_HASH,
            assetVersionId: ConfigId.assetVersion(1, ECONOMIC_ASSET_ID_HASH, block.chainid, address(assetToken), 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: address(assetToken),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            assetDecimals: 18,
            tokenCodeHash: address(assetToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            assetPermitCapability: PermitCapability.UNSUPPORTED,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            dvpContract: address(dependentDvp),
            deploymentVersionHash: DEPLOYMENT_VERSION_HASH,
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }
}
