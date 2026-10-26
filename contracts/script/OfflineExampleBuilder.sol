// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {CoreDeployment, ExampleBusinessInputs, ExampleConfigs, ExampleImplementations} from "./DeployTypes.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";
import {IAssetAdapter} from "../src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "../src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "../src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "../src/libraries/ConfigId.sol";
import {FeeScope} from "../src/libraries/FeeScope.sol";
import {HTPHashing} from "../src/libraries/HTPHashing.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    Decision,
    EligibilityInput,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    ParticipantInput,
    ParticipantType,
    PermitCapability,
    PrincipalCalculatorConfig,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard
} from "../src/types/HTPTypes.sol";

contract OfflineExampleBuilder {
    error AssetDecimalsOutOfRange(uint8 actual, uint8 maximum);
    error InvalidOfflineExampleInput();

    uint8 public constant MAX_ASSET_DECIMALS = 36;

    function buildConfigs(
        CoreDeployment calldata core,
        ExampleImplementations calldata implementations,
        ExampleBusinessInputs calldata inputs
    ) external view returns (ExampleConfigs memory configs) {
        _validate(inputs);
        configs.calculators = _calculatorConfigs(implementations);
        configs.adapters = _adapterConfigs(implementations);
        configs.settlementToken = _settlementTokenConfig(inputs, configs.adapters[0]);
        configs.assetVersion =
            _assetVersionConfig(core, inputs, configs.calculators[1], configs.adapters[0], configs.settlementToken);
        configs.marketRule = _marketRuleConfig(inputs, configs.assetVersion.assetVersionId, configs.settlementToken);
        (configs.participants, configs.eligibilities) =
            _identityAndEligibility(inputs, configs.assetVersion.assetVersionId);
        (configs.feeEpoch, configs.fee) =
            _feeConfigs(inputs, configs.assetVersion.assetVersionId, configs.settlementToken);
    }

    function _calculatorConfigs(ExampleImplementations calldata implementations)
        private
        view
        returns (PrincipalCalculatorConfig[3] memory configs)
    {
        address[3] memory calculators =
            [implementations.stockCalculator, implementations.fundCalculator, implementations.bondCalculator];
        for (uint256 i = 0; i < calculators.length; ++i) {
            AssetClass assetClass = IPrincipalCalculator(calculators[i]).assetClass();
            configs[i] = PrincipalCalculatorConfig({
                schemaVersion: 1,
                calculatorConfigId: ConfigId.derive(
                    ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(assetClass)), 1
                ),
                revision: 1,
                chainId: block.chainid,
                assetClass: assetClass,
                calculator: calculators[i],
                interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
                codeHash: calculators[i].codehash,
                replacesId: bytes32(0),
                configHash: bytes32(0)
            });
            configs[i].configHash = HTPHashing.hashPrincipalCalculatorConfig(configs[i]);
        }
    }

    function _adapterConfigs(ExampleImplementations calldata implementations)
        private
        view
        returns (AdapterConfig[4] memory configs)
    {
        address[4] memory adapters = [
            implementations.unrestrictedAdapter,
            implementations.erc1404Adapter,
            implementations.usdyAdapter,
            implementations.ondoGmAdapter
        ];
        for (uint256 i = 0; i < adapters.length; ++i) {
            IAssetAdapter adapter = IAssetAdapter(adapters[i]);
            AdapterCapabilities memory capabilities = adapter.capabilities();
            bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
            uint32 revision = i == 3 ? 2 : 1;
            configs[i] = AdapterConfig({
                schemaVersion: 1,
                adapterConfigId: ConfigId.derive(
                    ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, revision
                ),
                revision: revision,
                chainId: block.chainid,
                adapter: adapters[i],
                interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
                codeHash: adapters[i].codehash,
                capabilities: capabilities,
                capabilityHash: capabilityHash,
                providerHash: adapter.providerHash(),
                replacesId: i == 3 ? configs[2].adapterConfigId : bytes32(0),
                configHash: bytes32(0)
            });
            configs[i].configHash = HTPHashing.hashAdapterConfig(configs[i]);
        }
    }

    function _settlementTokenConfig(ExampleBusinessInputs calldata inputs, AdapterConfig memory adapter)
        private
        view
        returns (SettlementTokenConfig memory config)
    {
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
                1,
                block.chainid,
                bytes32(uint256(uint160(inputs.settlementToken))),
                1
            ),
            revision: 1,
            chainId: block.chainid,
            settlementToken: inputs.settlementToken,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: inputs.settlementTokenDecimals,
            tokenCodeHash: inputs.settlementToken.codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapter.adapterConfigId,
            adapterConfigHash: adapter.configHash,
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }

    function _assetVersionConfig(
        CoreDeployment calldata core,
        ExampleBusinessInputs calldata inputs,
        PrincipalCalculatorConfig memory calculator,
        AdapterConfig memory adapter,
        SettlementTokenConfig memory settlementToken
    ) private view returns (AssetVersionConfig memory config) {
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: inputs.economicAssetIdHash,
            assetVersionId: ConfigId.assetVersion(1, inputs.economicAssetIdHash, block.chainid, inputs.assetToken, 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: inputs.assetToken,
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            assetDecimals: inputs.assetDecimals,
            tokenCodeHash: inputs.assetToken.codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            assetPermitCapability: PermitCapability.EIP2612,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculator.calculatorConfigId,
            principalCalculatorConfigHash: calculator.configHash,
            adapterConfigId: adapter.adapterConfigId,
            adapterConfigHash: adapter.configHash,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            settlementToken: inputs.settlementToken,
            settlementTokenConfigId: settlementToken.configId,
            settlementTokenConfigHash: settlementToken.configHash,
            dvpContract: core.dvp,
            deploymentVersionHash: DvPSettlement(core.dvp).deploymentVersionHash(),
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }

    function _identityAndEligibility(ExampleBusinessInputs calldata inputs, bytes32 assetVersionId)
        private
        pure
        returns (ParticipantInput[2] memory participants, EligibilityInput[2] memory eligibilities)
    {
        participants[0] = ParticipantInput({
            wallet: inputs.maker,
            participantIdHash: keccak256("OFFLINE_EXAMPLE_MAKER"),
            participantType: ParticipantType.MAKER,
            validUntil: inputs.settlementValidUntil,
            evidenceHash: inputs.evidenceHash
        });
        participants[1] = ParticipantInput({
            wallet: inputs.requester,
            participantIdHash: keccak256("OFFLINE_EXAMPLE_REQUESTER"),
            participantType: ParticipantType.INVESTOR,
            validUntil: inputs.settlementValidUntil,
            evidenceHash: inputs.evidenceHash
        });

        eligibilities[0] = _eligibility(inputs, inputs.maker, assetVersionId);
        eligibilities[1] = _eligibility(inputs, inputs.requester, assetVersionId);
    }

    function _marketRuleConfig(
        ExampleBusinessInputs calldata inputs,
        bytes32 assetVersionId,
        SettlementTokenConfig memory settlementToken
    ) private view returns (MarketRuleConfig memory config) {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, assetVersionId, 1),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: assetVersionId,
            settlementToken: inputs.settlementToken,
            settlementTokenConfigId: settlementToken.configId,
            settlementTokenConfigHash: settlementToken.configHash,
            minCashPrincipal: 1,
            minExecutableQuantity: 1,
            quantityStep: 1,
            priceTick: 1,
            priceDecimals: inputs.settlementTokenDecimals,
            quantityDecimals: inputs.assetDecimals,
            quoteValidFrom: inputs.quoteValidFrom,
            quoteValidUntil: inputs.quoteValidUntil,
            settlementValidUntil: inputs.settlementValidUntil,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashMarketRuleConfig(config);
    }

    function _eligibility(ExampleBusinessInputs calldata inputs, address wallet, bytes32 assetVersionId)
        private
        pure
        returns (EligibilityInput memory)
    {
        return EligibilityInput({
            wallet: wallet,
            assetVersionId: assetVersionId,
            decision: Decision.PASS,
            validFrom: inputs.quoteValidFrom,
            validUntil: inputs.settlementValidUntil,
            kycDecisionVersion: keccak256("OFFLINE_EXAMPLE_KYC_V1"),
            permissionVersion: keccak256("OFFLINE_EXAMPLE_PERMISSION_V1"),
            evidenceHash: inputs.evidenceHash
        });
    }

    function _feeConfigs(
        ExampleBusinessInputs calldata inputs,
        bytes32 assetVersionId,
        SettlementTokenConfig memory settlementToken
    ) private view returns (FeePolicyEpochConfig memory epoch, FeeConfig memory fee) {
        epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: 1,
            chainId: block.chainid,
            quoteValidFrom: inputs.quoteValidFrom,
            quoteValidUntil: inputs.quoteValidUntil,
            settlementValidUntil: inputs.settlementValidUntil,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);

        bytes32 matchedScopeHash = FeeScope.matchedHash(1, ScopeType.ASSET_VERSION, assetVersionId);
        fee = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: 1,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: inputs.settlementToken,
            settlementTokenConfigId: settlementToken.configId,
            settlementTokenConfigHash: settlementToken.configHash,
            collector: inputs.collector,
            validFrom: inputs.quoteValidFrom,
            validUntil: inputs.settlementValidUntil,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        fee.feeConstraintHash = HTPHashing.hashFeeConstraint(fee);
        fee.configHash = HTPHashing.hashFeeConfig(fee);
    }

    function _validate(ExampleBusinessInputs calldata inputs) private view {
        if (
            inputs.assetToken.code.length == 0 || inputs.settlementToken.code.length == 0 || inputs.assetDecimals == 0
                || inputs.settlementTokenDecimals == 0 || inputs.economicAssetIdHash == bytes32(0)
                || inputs.maker == address(0) || inputs.requester == address(0) || inputs.maker == inputs.requester
                || inputs.collector == address(0) || inputs.evidenceHash == bytes32(0) || inputs.quoteValidFrom == 0
                || inputs.quoteValidFrom > inputs.quoteValidUntil
                || inputs.quoteValidUntil > inputs.settlementValidUntil
        ) {
            revert InvalidOfflineExampleInput();
        }
        if (inputs.assetDecimals > MAX_ASSET_DECIMALS) {
            revert AssetDecimalsOutOfRange(inputs.assetDecimals, MAX_ASSET_DECIMALS);
        }
    }
}
