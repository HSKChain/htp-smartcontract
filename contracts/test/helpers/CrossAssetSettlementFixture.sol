// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    PermitCapability,
    PrincipalCalculatorConfig,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {IntegrationERC20Token} from "test/fixtures/IntegrationTokens.sol";
import {UsdySettlementFixture} from "./UsdySettlementFixture.sol";

abstract contract CrossAssetSettlementFixture is UsdySettlementFixture {
    AssetVersionConfig internal integrationAssetConfig;
    PrincipalCalculatorConfig internal integrationCalculatorConfig;
    FeeConfig internal integrationFeeConfig;
    MarketRuleConfig internal integrationMarketRuleConfig;

    function _activateAndBuildAssetSettlement(
        AssetClass assetClass,
        IPrincipalCalculator selectedCalculator,
        IntegrationERC20Token selectedToken,
        AdapterConfig memory selectedAdapterConfig,
        TokenStandard tokenStandard,
        RestrictionMode restrictionMode,
        bytes memory priceData,
        bytes32 priceTermsHash,
        uint64 feeEpoch
    ) internal returns (SettlementParams memory params) {
        integrationCalculatorConfig = assetClass == AssetClass.FUND
            ? calculatorConfig
            : _registerCalculator(assetClass, selectedCalculator);
        integrationAssetConfig = _registerAsset(
            assetClass,
            selectedToken,
            selectedAdapterConfig,
            tokenStandard,
            restrictionMode,
            integrationCalculatorConfig,
            feeEpoch
        );
        integrationFeeConfig = _registerFee(integrationAssetConfig.assetVersionId, feeEpoch);
        integrationMarketRuleConfig = _registerMarketRule(integrationAssetConfig);

        _setEligibilityForAsset(integrationAssetConfig.assetVersionId, vm.addr(MAKER_KEY));
        _setEligibilityForAsset(integrationAssetConfig.assetVersionId, vm.addr(REQUESTER_KEY));

        selectedToken.setBalance(vm.addr(MAKER_KEY), 100 ether);
        selectedToken.setAllowance(vm.addr(MAKER_KEY), address(dvp), 10 ether);

        params = _validUsdyBuyParams();
        _bindConfiguration(params, integrationAssetConfig, selectedAdapterConfig, integrationFeeConfig);
        _bindMarketRule(params, integrationMarketRuleConfig);
        _bindPriceAndCalculator(params, assetClass, priceData, priceTermsHash, integrationCalculatorConfig);
        params.snapshot.createdAt = USDY_CREATED_AT + feeEpoch;
        _resign(params);
    }

    function _registerCalculator(AssetClass assetClass, IPrincipalCalculator selectedCalculator)
        private
        returns (PrincipalCalculatorConfig memory config)
    {
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(assetClass)), 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetClass: assetClass,
            calculator: address(selectedCalculator),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(selectedCalculator).codehash,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(config);
        vm.prank(address(timelock));
        calculatorRegistry.activatePrincipalCalculator(config.calculatorConfigId, config.configHash);
    }

    function _registerAsset(
        AssetClass assetClass,
        IntegrationERC20Token selectedToken,
        AdapterConfig memory selectedAdapterConfig,
        TokenStandard tokenStandard,
        RestrictionMode restrictionMode,
        PrincipalCalculatorConfig memory selectedCalculatorConfig,
        uint64 discriminator
    ) private returns (AssetVersionConfig memory config) {
        bytes32 economicAssetIdHash = bytes32(uint256(0xA55000 + discriminator));
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: economicAssetIdHash,
            assetVersionId: ConfigId.assetVersion(1, economicAssetIdHash, block.chainid, address(selectedToken), 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: address(selectedToken),
            tokenStandard: tokenStandard,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            assetDecimals: 18,
            tokenCodeHash: address(selectedToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            assetPermitCapability: PermitCapability.EIP2612,
            assetClass: assetClass,
            principalCalculatorConfigId: selectedCalculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: selectedCalculatorConfig.configHash,
            adapterConfigId: selectedAdapterConfig.adapterConfigId,
            adapterConfigHash: selectedAdapterConfig.configHash,
            restrictionMode: restrictionMode,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            dvpContract: address(dvp),
            deploymentVersionHash: DEPLOYMENT_VERSION_HASH,
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(config);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(config.assetVersionId, config.configHash);
    }

    function _registerFee(bytes32 assetVersionId, uint64 feeEpoch) private returns (FeeConfig memory config) {
        uint64 validFrom = USDY_CREATED_AT + feeEpoch;
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: feeEpoch,
            chainId: block.chainid,
            quoteValidFrom: validFrom,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash = FeeScope.matchedHash(feeEpoch, ScopeType.ASSET_VERSION, assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: feeEpoch,
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
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: validFrom,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(config);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(feeEpoch, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(validFrom);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(feeEpoch, epoch.configHash);
    }

    function _registerMarketRule(AssetVersionConfig memory asset) private returns (MarketRuleConfig memory config) {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, asset.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: asset.assetVersionId,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            minCashPrincipal: 1,
            minExecutableQuantity: 1,
            quantityStep: 1,
            priceTick: 10,
            priceDecimals: 6,
            quantityDecimals: 18,
            quoteValidFrom: QUOTE_VALID_FROM,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashMarketRuleConfig(config);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(config);
        vm.prank(address(timelock));
        marketRuleRegistry.sealMarketRule(config.marketRuleConfigId, config.configHash);
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(config.marketRuleConfigId, config.configHash);
    }

    function _bindPriceAndCalculator(
        SettlementParams memory params,
        AssetClass assetClass,
        bytes memory priceData,
        bytes32 priceTermsHash,
        PrincipalCalculatorConfig memory selectedCalculatorConfig
    ) private pure {
        params.firmQuote.assetClass = assetClass;
        params.firmQuote.priceData = priceData;
        params.firmQuote.priceTermsHash = priceTermsHash;
        params.firmQuote.principalCalculatorConfigId = selectedCalculatorConfig.calculatorConfigId;
        params.firmQuote.principalCalculatorConfigHash = selectedCalculatorConfig.configHash;

        params.tradeIntent.assetClass = assetClass;
        params.tradeIntent.priceData = priceData;
        params.tradeIntent.priceTermsHash = priceTermsHash;
        params.tradeIntent.principalCalculatorConfigId = selectedCalculatorConfig.calculatorConfigId;
        params.tradeIntent.principalCalculatorConfigHash = selectedCalculatorConfig.configHash;

        params.snapshot.assetClass = assetClass;
        params.snapshot.priceData = priceData;
        params.snapshot.priceTermsHash = priceTermsHash;
        params.snapshot.principalCalculatorConfigId = selectedCalculatorConfig.calculatorConfigId;
        params.snapshot.principalCalculatorConfigHash = selectedCalculatorConfig.configHash;
    }
}
