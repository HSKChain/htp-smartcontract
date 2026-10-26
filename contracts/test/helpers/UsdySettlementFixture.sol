// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
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
    ParticipantType,
    PermitCapability,
    RequesterSide,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {DeployFixture} from "./DeployFixture.sol";

abstract contract UsdySettlementFixture is DeployFixture {
    uint64 internal constant USDY_FEE_EPOCH = 2;
    uint64 internal constant USDY_CREATED_AT = CREATED_AT + 1;
    bytes32 internal constant USDY_ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0x55D7));

    AdapterConfig internal usdyAdapterConfig;
    AssetVersionConfig internal usdyAssetVersionConfig;
    FeeConfig internal usdyFeeConfig;
    MarketRuleConfig internal usdyMarketRuleConfig;

    function setUp() public virtual override {
        super.setUp();
        _allowUsdyParticipants();
        _activateUsdyConfiguration();
        _activateUsdyEligibility();
        _fundUsdyBuy();
        vm.warp(USDY_CREATED_AT);
    }

    function _validUsdyBuyParams() internal view returns (SettlementParams memory params) {
        params = _validPreCheckParams();
        _bindUsdyConfiguration(params);
        params.snapshot.createdAt = USDY_CREATED_AT;
        _resign(params);
    }

    function _validUsdySellParams() internal returns (SettlementParams memory params) {
        params = _validUsdyBuyParams();
        address maker = params.firmQuote.quotingMaker;
        address requester = params.firmQuote.requester;

        params.firmQuote.requesterSide = RequesterSide.SELL;
        params.tradeIntent.requesterSide = RequesterSide.SELL;
        params.snapshot.requesterSide = RequesterSide.SELL;
        params.tradeIntent.buyer = maker;
        params.snapshot.buyer = maker;
        params.tradeIntent.seller = requester;
        params.snapshot.seller = requester;
        _applyIdentityFeeAmounts(params, usdyFeeConfig);

        usdyToken.setBalance(requester, 100 ether);
        usdyToken.setAllowance(requester, address(dvp), params.snapshot.executedQuantity);
        settlementToken.setBalance(maker, 100_000_000);
        settlementToken.setAllowance(maker, address(dvp), params.snapshot.buyerDebit);
        _resign(params);
    }

    function _applyIdentityFeeAmounts(SettlementParams memory params, FeeConfig memory config) internal pure {
        ParticipantType buyerParticipantType;
        ParticipantType sellerParticipantType;
        if (params.firmQuote.requesterSide == RequesterSide.BUY) {
            buyerParticipantType = params.firmQuote.requesterType;
            sellerParticipantType = ParticipantType.MAKER;
        } else {
            buyerParticipantType = ParticipantType.MAKER;
            sellerParticipantType = params.firmQuote.requesterType;
        }
        (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            FeeMath.calculate(params.snapshot.cashPrincipal, buyerParticipantType, sellerParticipantType, config);
        params.tradeIntent.buyerFee = buyerFee;
        params.snapshot.buyerFee = buyerFee;
        params.tradeIntent.sellerFee = sellerFee;
        params.snapshot.sellerFee = sellerFee;
        params.tradeIntent.buyerDebit = buyerDebit;
        params.snapshot.buyerDebit = buyerDebit;
        params.tradeIntent.sellerCredit = sellerCredit;
        params.snapshot.sellerCredit = sellerCredit;
        params.tradeIntent.collectorCredit = collectorCredit;
        params.snapshot.collectorCredit = collectorCredit;
    }

    function _settleUsdy(SettlementParams memory params) internal {
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function _allowUsdyParticipants() private {
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);
        usdyAllowlist.setAllowed(maker, true);
        usdyAllowlist.setAllowed(requester, true);
        usdyAllowlist.setAllowed(address(dvp), true);
    }

    function _activateUsdyConfiguration() private {
        usdyAdapterConfig = _buildAdapterConfig(usdyAdapter, 1, bytes32(0));
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(usdyAdapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(usdyAdapterConfig.adapterConfigId, usdyAdapterConfig.configHash);

        usdyAssetVersionConfig = _buildUsdyAssetVersionConfig();
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(usdyAssetVersionConfig);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(
            usdyAssetVersionConfig.assetVersionId, usdyAssetVersionConfig.configHash
        );

        usdyMarketRuleConfig = _buildUsdyMarketRuleConfig();
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(usdyMarketRuleConfig);
        vm.prank(address(timelock));
        marketRuleRegistry.sealMarketRule(usdyMarketRuleConfig.marketRuleConfigId, usdyMarketRuleConfig.configHash);
        vm.warp(USDY_CREATED_AT);
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(usdyMarketRuleConfig.marketRuleConfigId, usdyMarketRuleConfig.configHash);

        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: USDY_FEE_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: USDY_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        usdyFeeConfig = _buildUsdyFeeConfig();
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(usdyFeeConfig);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(USDY_FEE_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(usdyFeeConfig.feeVersionId, usdyFeeConfig.configHash);
        vm.warp(USDY_CREATED_AT);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(USDY_FEE_EPOCH, epoch.configHash, usdyFeeConfig.feeVersionId);
    }

    function _activateUsdyEligibility() private {
        _setUsdyEligibility(vm.addr(MAKER_KEY));
        _setUsdyEligibility(vm.addr(REQUESTER_KEY));
    }

    function _usdyPermitCapability() internal pure virtual returns (PermitCapability) {
        return PermitCapability.EIP2612;
    }

    function _fundUsdyBuy() internal virtual {
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);
        usdyToken.setBalance(maker, 100 ether);
        usdyToken.setAllowance(maker, address(dvp), 10 ether);
        settlementToken.setBalance(requester, 100_000_000);
        settlementToken.setAllowance(requester, address(dvp), 11_428_500);
    }

    function _setUsdyEligibility(address wallet) internal {
        _setEligibilityForAsset(usdyAssetVersionConfig.assetVersionId, wallet);
    }

    function _setEligibilityForAsset(bytes32 assetVersionId, address wallet) internal {
        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: wallet,
                assetVersionId: assetVersionId,
                decision: Decision.PASS,
                validFrom: QUOTE_VALID_FROM,
                validUntil: SETTLEMENT_VALID_UNTIL,
                kycDecisionVersion: bytes32(uint256(0xD200)),
                permissionVersion: bytes32(uint256(0xD201)),
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _bindUsdyConfiguration(SettlementParams memory params) internal view {
        _bindConfiguration(params, usdyAssetVersionConfig, usdyAdapterConfig, usdyFeeConfig);
        _bindMarketRule(params, usdyMarketRuleConfig);
    }

    function _bindMarketRule(SettlementParams memory params, MarketRuleConfig memory config) internal pure {
        params.firmQuote.marketRuleConfigId = config.marketRuleConfigId;
        params.firmQuote.marketRuleConfigHash = config.configHash;
        params.tradeIntent.marketRuleConfigId = config.marketRuleConfigId;
        params.tradeIntent.marketRuleConfigHash = config.configHash;
        params.snapshot.marketRuleConfigId = config.marketRuleConfigId;
        params.snapshot.marketRuleConfigHash = config.configHash;
    }

    function _bindConfiguration(
        SettlementParams memory params,
        AssetVersionConfig memory assetConfig,
        AdapterConfig memory assetAdapterConfig,
        FeeConfig memory selectedFeeConfig
    ) internal pure {
        params.firmQuote.assetVersionId = assetConfig.assetVersionId;
        params.firmQuote.assetToken = assetConfig.assetToken;
        params.firmQuote.adapterConfigId = assetAdapterConfig.adapterConfigId;
        params.firmQuote.adapterConfigHash = assetAdapterConfig.configHash;
        params.firmQuote.feePolicyEpoch = selectedFeeConfig.feePolicyEpoch;
        params.firmQuote.feeVersionId = selectedFeeConfig.feeVersionId;
        params.firmQuote.matchedScopeHash = selectedFeeConfig.matchedScopeHash;
        params.firmQuote.feeConstraintHash = selectedFeeConfig.feeConstraintHash;

        params.tradeIntent.assetVersionId = assetConfig.assetVersionId;
        params.tradeIntent.assetToken = assetConfig.assetToken;
        params.tradeIntent.adapterConfigId = assetAdapterConfig.adapterConfigId;
        params.tradeIntent.adapterConfigHash = assetAdapterConfig.configHash;
        params.tradeIntent.feePolicyEpoch = selectedFeeConfig.feePolicyEpoch;
        params.tradeIntent.feeVersionId = selectedFeeConfig.feeVersionId;
        params.tradeIntent.matchedScopeHash = selectedFeeConfig.matchedScopeHash;
        params.tradeIntent.feeConstraintHash = selectedFeeConfig.feeConstraintHash;

        params.snapshot.assetVersionId = assetConfig.assetVersionId;
        params.snapshot.assetToken = assetConfig.assetToken;
        params.snapshot.adapterConfigId = assetAdapterConfig.adapterConfigId;
        params.snapshot.adapterConfigHash = assetAdapterConfig.configHash;
        params.snapshot.feePolicyEpoch = selectedFeeConfig.feePolicyEpoch;
        params.snapshot.feeVersionId = selectedFeeConfig.feeVersionId;
        params.snapshot.matchedScopeHash = selectedFeeConfig.matchedScopeHash;
        params.snapshot.feeConstraintHash = selectedFeeConfig.feeConstraintHash;
    }

    function _buildAdapterConfig(IAssetAdapter implementation, uint32 revision, bytes32 replacesId)
        internal
        view
        returns (AdapterConfig memory config)
    {
        AdapterCapabilities memory capabilities = implementation.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, revision),
            revision: revision,
            chainId: block.chainid,
            adapter: address(implementation),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(implementation).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: implementation.providerHash(),
            replacesId: replacesId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _buildUsdyAssetVersionConfig() internal view returns (AssetVersionConfig memory config) {
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: USDY_ECONOMIC_ASSET_ID_HASH,
            assetVersionId: ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: address(usdyToken),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.ERC1967_PROXY,
            assetDecimals: 18,
            tokenCodeHash: address(usdyToken).codehash,
            implementation: usdyTokenImplementation,
            implementationCodeHash: usdyTokenImplementation.codehash,
            assetPermitCapability: _usdyPermitCapability(),
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: usdyAdapterConfig.adapterConfigId,
            adapterConfigHash: usdyAdapterConfig.configHash,
            restrictionMode: RestrictionMode.TOKEN_ENFORCED,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            dvpContract: address(dvp),
            deploymentVersionHash: DEPLOYMENT_VERSION_HASH,
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }

    function _buildUsdyFeeConfig() private view returns (FeeConfig memory config) {
        bytes32 matchedScopeHash =
            FeeScope.matchedHash(USDY_FEE_EPOCH, ScopeType.ASSET_VERSION, usdyAssetVersionConfig.assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: USDY_FEE_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: usdyAssetVersionConfig.assetVersionId,
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
            validFrom: USDY_CREATED_AT,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
    }

    function _buildUsdyMarketRuleConfig() private view returns (MarketRuleConfig memory config) {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, usdyAssetVersionConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: usdyAssetVersionConfig.assetVersionId,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            minCashPrincipal: 1_000_000,
            minExecutableQuantity: 1 ether,
            quantityStep: 1 ether,
            priceTick: 10_000,
            priceDecimals: 2,
            quantityDecimals: 1,
            quoteValidFrom: USDY_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashMarketRuleConfig(config);
    }
}
