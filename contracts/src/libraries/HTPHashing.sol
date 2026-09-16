// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DeploymentVersion} from "./DeploymentVersion.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AssetVersionConfig,
    BondPriceTerms,
    FeeConfig,
    FeePolicyEpochConfig,
    FirmQuote,
    FundPriceTerms,
    MarketRuleConfig,
    NonceCancellation,
    PrincipalCalculatorConfig,
    RestrictionProvider,
    RestrictionProviderSet,
    SettlementTokenConfig,
    StockPriceTerms,
    TradeIntent,
    TradeTermsSnapshot
} from "../types/HTPTypes.sol";

/// @notice EIP-712 struct hashing aligned with signed settlement payloads.
library HTPHashing {
    string internal constant EIP712_NAME = "HTP DvP Settlement";
    bytes32 internal constant EIP712_NAME_HASH = keccak256("HTP DvP Settlement");

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant FIRM_QUOTE_TYPEHASH = keccak256(
        "FirmQuote(uint32 schemaVersion,bytes32 rfqIdHash,bytes32 quoteIdHash,uint32 quoteVersion,address quotingMaker,address requester,uint8 requesterType,bytes32 assetVersionId,uint8 requesterSide,address assetToken,address settlementToken,uint8 assetClass,bytes32 priceTermsHash,bytes priceData,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,uint256 minExecutableQuantity,uint256 maxExecutableQuantity,uint256 stepQuantity,uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,bytes32 feeConstraintHash,uint256 quoteNonce,uint64 expiresAt)"
    );

    bytes32 internal constant TRADE_INTENT_TYPEHASH = keccak256(
        "TradeIntent(uint32 schemaVersion,bytes32 tradeIdHash,bytes32 quoteHash,bytes32 snapshotHash,address requester,uint8 requesterType,address quotingMaker,bytes32 assetVersionId,uint8 requesterSide,address buyer,address seller,address assetToken,address settlementToken,uint256 executedQuantity,uint8 assetClass,bytes32 priceTermsHash,bytes priceData,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,uint256 cashPrincipal,uint256 buyerFee,uint256 sellerFee,uint256 buyerDebit,uint256 sellerCredit,uint256 collectorCredit,address collector,uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,bytes32 feeConstraintHash,uint8 roundingMode,uint256 tradeNonce,uint64 deadline)"
    );

    bytes32 internal constant NONCE_CANCELLATION_TYPEHASH =
        keccak256("NonceCancellation(address signer,uint8 nonceType,uint256 nonce,uint64 deadline)");

    bytes32 internal constant TRADE_TERMS_SNAPSHOT_TYPEHASH = keccak256(
        "TradeTermsSnapshot(uint32 schemaVersion,bytes32 tradeIdHash,bytes32 quoteHash,uint256 chainId,address dvpContract,address requester,uint8 requesterType,address quotingMaker,uint8 requesterSide,address buyer,address seller,bytes32 assetVersionId,address assetToken,address settlementToken,uint8 assetDecimals,uint8 settlementTokenDecimals,uint256 executedQuantity,uint8 assetClass,bytes32 priceTermsHash,bytes priceData,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,uint256 cashPrincipal,uint256 buyerFee,uint256 sellerFee,uint256 buyerDebit,uint256 sellerCredit,uint256 collectorCredit,address collector,uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,bytes32 feeConstraintHash,uint8 roundingMode,uint256 makerQuoteNonce,uint256 requesterTradeNonce,uint64 quoteExpiresAt,uint64 tradeDeadline,uint64 createdAt)"
    );

    bytes32 internal constant STOCK_PRICE_TERMS_TYPEHASH = keccak256(
        "StockPriceTerms(uint256 unitPrice,uint64 priceAsOf,bytes32 referenceMarketHash,bytes32 priceSourceHash)"
    );

    bytes32 internal constant FUND_PRICE_TERMS_TYPEHASH =
        keccak256("FundPriceTerms(uint256 navPerUnit,uint32 navDate,bytes32 navSourceHash)");

    bytes32 internal constant BOND_PRICE_TERMS_TYPEHASH = keccak256(
        "BondPriceTerms(uint256 cleanPricePerUnit,uint256 accruedInterestPerUnit,uint32 settlementDate,bytes32 sourceHash)"
    );

    bytes32 internal constant ASSET_VERSION_CONFIG_TYPEHASH = keccak256(
        "AssetVersionConfig(uint32 schemaVersion,bytes32 economicAssetIdHash,bytes32 assetVersionId,uint256 chainId,uint32 versionNo,address assetToken,uint8 tokenStandard,uint8 tokenDeploymentKind,uint8 assetDecimals,bytes32 tokenCodeHash,address implementation,bytes32 implementationCodeHash,uint8 assetPermitCapability,uint8 assetClass,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,uint8 restrictionMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address dvpContract,bytes32 deploymentVersionHash,bytes32 replacesAssetVersionId)"
    );

    bytes32 internal constant SETTLEMENT_TOKEN_CONFIG_TYPEHASH = keccak256(
        "SettlementTokenConfig(uint32 schemaVersion,bytes32 configId,uint32 revision,uint256 chainId,address settlementToken,uint8 tokenDeploymentKind,uint8 settlementTokenDecimals,bytes32 tokenCodeHash,address implementation,bytes32 implementationCodeHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,uint8 permitCapability,bytes32 replacesConfigId)"
    );

    bytes32 internal constant ADAPTER_CAPABILITIES_TYPEHASH = keccak256(
        "AdapterCapabilities(uint8 tokenStandard,uint8 restrictionMode,uint8 precheckMethod,uint256 transferLegMask)"
    );

    bytes32 internal constant RESTRICTION_PROVIDER_TYPEHASH =
        keccak256("RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)");

    bytes32 internal constant RESTRICTION_PROVIDER_SET_TYPEHASH = keccak256(
        "RestrictionProviderSet(RestrictionProvider[] providers)RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)"
    );

    bytes32 internal constant ADAPTER_CONFIG_TYPEHASH = keccak256(
        "AdapterConfig(uint32 schemaVersion,bytes32 adapterConfigId,uint32 revision,uint256 chainId,address adapter,bytes32 interfaceVersion,bytes32 codeHash,AdapterCapabilities capabilities,bytes32 capabilityHash,bytes32 providerHash,bytes32 replacesId)AdapterCapabilities(uint8 tokenStandard,uint8 restrictionMode,uint8 precheckMethod,uint256 transferLegMask)"
    );

    bytes32 internal constant PRINCIPAL_CALCULATOR_CONFIG_TYPEHASH = keccak256(
        "PrincipalCalculatorConfig(uint32 schemaVersion,bytes32 calculatorConfigId,uint32 revision,uint256 chainId,uint8 assetClass,address calculator,bytes32 interfaceVersion,bytes32 codeHash,bytes32 replacesId)"
    );

    bytes32 internal constant MARKET_RULE_CONFIG_TYPEHASH = keccak256(
        "MarketRuleConfig(uint32 schemaVersion,bytes32 marketRuleConfigId,uint32 revision,uint256 chainId,bytes32 assetVersionId,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,uint256 minCashPrincipal,uint256 minExecutableQuantity,uint256 quantityStep,uint256 priceTick,uint8 priceDecimals,uint8 quantityDecimals,uint64 quoteValidFrom,uint64 quoteValidUntil,uint64 settlementValidUntil,bytes32 replacesConfigId)"
    );

    bytes32 internal constant FEE_CONSTRAINT_TYPEHASH = keccak256(
        "FeeConstraint(uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,uint16 investorRateBps,bool investorHasCap,uint256 investorCapAmount,uint16 makerRateBps,bool makerHasCap,uint256 makerCapAmount,uint8 roundingMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address collector,uint64 validFrom,uint64 validUntil)"
    );

    bytes32 internal constant FEE_POLICY_EPOCH_CONFIG_TYPEHASH = keccak256(
        "FeePolicyEpochConfig(uint32 schemaVersion,uint64 feePolicyEpoch,uint256 chainId,uint64 quoteValidFrom,uint64 quoteValidUntil,uint64 settlementValidUntil)"
    );

    bytes32 internal constant FEE_CONFIG_TYPEHASH = keccak256(
        "FeeConfig(uint32 schemaVersion,bytes32 feeVersionId,uint32 revision,uint256 chainId,uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash,bytes32 matchedScopeHash,uint16 investorRateBps,bool investorHasCap,uint256 investorCapAmount,uint16 makerRateBps,bool makerHasCap,uint256 makerCapAmount,uint8 roundingMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address collector,uint64 validFrom,uint64 validUntil,bytes32 feeConstraintHash,bytes32 replacesFeeVersionId)"
    );

    /// @notice EIP-712 domain separator for this DvP deployment.
    function domainSeparator(bytes memory deploymentVersion, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        string memory major = DeploymentVersion.domainVersion(deploymentVersion);
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, keccak256(bytes(major)), chainId, verifyingContract)
        );
    }

    /// @dev EIP-191: 0x1901 || domainSeparator || structHash.
    function toTypedDataDigest(bytes32 separator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", separator, structHash));
    }

    function hashFirmQuote(FirmQuote memory quote) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](32);
        words[0] = FIRM_QUOTE_TYPEHASH;
        words[1] = bytes32(uint256(quote.schemaVersion));
        words[2] = quote.rfqIdHash;
        words[3] = quote.quoteIdHash;
        words[4] = bytes32(uint256(quote.quoteVersion));
        words[5] = _addressWord(quote.quotingMaker);
        words[6] = _addressWord(quote.requester);
        words[7] = bytes32(uint256(quote.requesterType));
        words[8] = quote.assetVersionId;
        words[9] = bytes32(uint256(quote.requesterSide));
        words[10] = _addressWord(quote.assetToken);
        words[11] = _addressWord(quote.settlementToken);
        words[12] = bytes32(uint256(quote.assetClass));
        words[13] = quote.priceTermsHash;
        words[14] = keccak256(quote.priceData);
        words[15] = quote.principalCalculatorConfigId;
        words[16] = quote.principalCalculatorConfigHash;
        words[17] = quote.adapterConfigId;
        words[18] = quote.adapterConfigHash;
        words[19] = quote.settlementTokenConfigId;
        words[20] = quote.settlementTokenConfigHash;
        words[21] = quote.marketRuleConfigId;
        words[22] = quote.marketRuleConfigHash;
        words[23] = bytes32(quote.minExecutableQuantity);
        words[24] = bytes32(quote.maxExecutableQuantity);
        words[25] = bytes32(quote.stepQuantity);
        words[26] = bytes32(uint256(quote.feePolicyEpoch));
        words[27] = quote.feeVersionId;
        words[28] = quote.matchedScopeHash;
        words[29] = quote.feeConstraintHash;
        words[30] = bytes32(quote.quoteNonce);
        words[31] = bytes32(uint256(quote.expiresAt));
        return _hashWords(words);
    }

    function hashFirmQuoteDigest(bytes32 separator, FirmQuote memory quote) internal pure returns (bytes32) {
        return toTypedDataDigest(separator, hashFirmQuote(quote));
    }

    function hashTradeIntent(TradeIntent memory intent) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](40);
        words[0] = TRADE_INTENT_TYPEHASH;
        words[1] = bytes32(uint256(intent.schemaVersion));
        words[2] = intent.tradeIdHash;
        words[3] = intent.quoteHash;
        words[4] = intent.snapshotHash;
        words[5] = _addressWord(intent.requester);
        words[6] = bytes32(uint256(intent.requesterType));
        words[7] = _addressWord(intent.quotingMaker);
        words[8] = intent.assetVersionId;
        words[9] = bytes32(uint256(intent.requesterSide));
        words[10] = _addressWord(intent.buyer);
        words[11] = _addressWord(intent.seller);
        words[12] = _addressWord(intent.assetToken);
        words[13] = _addressWord(intent.settlementToken);
        words[14] = bytes32(intent.executedQuantity);
        words[15] = bytes32(uint256(intent.assetClass));
        words[16] = intent.priceTermsHash;
        words[17] = keccak256(intent.priceData);
        words[18] = intent.principalCalculatorConfigId;
        words[19] = intent.principalCalculatorConfigHash;
        words[20] = intent.adapterConfigId;
        words[21] = intent.adapterConfigHash;
        words[22] = intent.settlementTokenConfigId;
        words[23] = intent.settlementTokenConfigHash;
        words[24] = intent.marketRuleConfigId;
        words[25] = intent.marketRuleConfigHash;
        words[26] = bytes32(intent.cashPrincipal);
        words[27] = bytes32(intent.buyerFee);
        words[28] = bytes32(intent.sellerFee);
        words[29] = bytes32(intent.buyerDebit);
        words[30] = bytes32(intent.sellerCredit);
        words[31] = bytes32(intent.collectorCredit);
        words[32] = _addressWord(intent.collector);
        words[33] = bytes32(uint256(intent.feePolicyEpoch));
        words[34] = intent.feeVersionId;
        words[35] = intent.matchedScopeHash;
        words[36] = intent.feeConstraintHash;
        words[37] = bytes32(uint256(intent.roundingMode));
        words[38] = bytes32(intent.tradeNonce);
        words[39] = bytes32(uint256(intent.deadline));
        return _hashWords(words);
    }

    function hashTradeIntentDigest(bytes32 separator, TradeIntent memory intent) internal pure returns (bytes32) {
        return toTypedDataDigest(separator, hashTradeIntent(intent));
    }

    function hashNonceCancellation(NonceCancellation memory cancellation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                NONCE_CANCELLATION_TYPEHASH,
                cancellation.signer,
                cancellation.nonceType,
                cancellation.nonce,
                cancellation.deadline
            )
        );
    }

    function hashNonceCancellationDigest(bytes32 separator, NonceCancellation memory cancellation)
        internal
        pure
        returns (bytes32)
    {
        return toTypedDataDigest(separator, hashNonceCancellation(cancellation));
    }

    function hashTradeTermsSnapshot(TradeTermsSnapshot memory snapshot) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](46);
        words[0] = TRADE_TERMS_SNAPSHOT_TYPEHASH;
        words[1] = bytes32(uint256(snapshot.schemaVersion));
        words[2] = snapshot.tradeIdHash;
        words[3] = snapshot.quoteHash;
        words[4] = bytes32(snapshot.chainId);
        words[5] = _addressWord(snapshot.dvpContract);
        words[6] = _addressWord(snapshot.requester);
        words[7] = bytes32(uint256(snapshot.requesterType));
        words[8] = _addressWord(snapshot.quotingMaker);
        words[9] = bytes32(uint256(snapshot.requesterSide));
        words[10] = _addressWord(snapshot.buyer);
        words[11] = _addressWord(snapshot.seller);
        words[12] = snapshot.assetVersionId;
        words[13] = _addressWord(snapshot.assetToken);
        words[14] = _addressWord(snapshot.settlementToken);
        words[15] = bytes32(uint256(snapshot.assetDecimals));
        words[16] = bytes32(uint256(snapshot.settlementTokenDecimals));
        words[17] = bytes32(snapshot.executedQuantity);
        words[18] = bytes32(uint256(snapshot.assetClass));
        words[19] = snapshot.priceTermsHash;
        words[20] = keccak256(snapshot.priceData);
        words[21] = snapshot.principalCalculatorConfigId;
        words[22] = snapshot.principalCalculatorConfigHash;
        words[23] = snapshot.adapterConfigId;
        words[24] = snapshot.adapterConfigHash;
        words[25] = snapshot.settlementTokenConfigId;
        words[26] = snapshot.settlementTokenConfigHash;
        words[27] = snapshot.marketRuleConfigId;
        words[28] = snapshot.marketRuleConfigHash;
        words[29] = bytes32(snapshot.cashPrincipal);
        words[30] = bytes32(snapshot.buyerFee);
        words[31] = bytes32(snapshot.sellerFee);
        words[32] = bytes32(snapshot.buyerDebit);
        words[33] = bytes32(snapshot.sellerCredit);
        words[34] = bytes32(snapshot.collectorCredit);
        words[35] = _addressWord(snapshot.collector);
        words[36] = bytes32(uint256(snapshot.feePolicyEpoch));
        words[37] = snapshot.feeVersionId;
        words[38] = snapshot.matchedScopeHash;
        words[39] = snapshot.feeConstraintHash;
        words[40] = bytes32(uint256(snapshot.roundingMode));
        words[41] = bytes32(snapshot.makerQuoteNonce);
        words[42] = bytes32(snapshot.requesterTradeNonce);
        words[43] = bytes32(uint256(snapshot.quoteExpiresAt));
        words[44] = bytes32(uint256(snapshot.tradeDeadline));
        words[45] = bytes32(uint256(snapshot.createdAt));
        return _hashWords(words);
    }

    function hashStockPriceTerms(StockPriceTerms memory terms) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STOCK_PRICE_TERMS_TYPEHASH,
                terms.unitPrice,
                terms.priceAsOf,
                terms.referenceMarketHash,
                terms.priceSourceHash
            )
        );
    }

    function hashFundPriceTerms(FundPriceTerms memory terms) internal pure returns (bytes32) {
        return keccak256(abi.encode(FUND_PRICE_TERMS_TYPEHASH, terms.navPerUnit, terms.navDate, terms.navSourceHash));
    }

    function hashBondPriceTerms(BondPriceTerms memory terms) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BOND_PRICE_TERMS_TYPEHASH,
                terms.cleanPricePerUnit,
                terms.accruedInterestPerUnit,
                terms.settlementDate,
                terms.sourceHash
            )
        );
    }

    function hashAssetVersionConfig(AssetVersionConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](26);
        words[0] = ASSET_VERSION_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.economicAssetIdHash;
        words[3] = config.assetVersionId;
        words[4] = bytes32(config.chainId);
        words[5] = bytes32(uint256(config.versionNo));
        words[6] = _addressWord(config.assetToken);
        words[7] = bytes32(uint256(config.tokenStandard));
        words[8] = bytes32(uint256(config.tokenDeploymentKind));
        words[9] = bytes32(uint256(config.assetDecimals));
        words[10] = config.tokenCodeHash;
        words[11] = _addressWord(config.implementation);
        words[12] = config.implementationCodeHash;
        words[13] = bytes32(uint256(config.assetPermitCapability));
        words[14] = bytes32(uint256(config.assetClass));
        words[15] = config.principalCalculatorConfigId;
        words[16] = config.principalCalculatorConfigHash;
        words[17] = config.adapterConfigId;
        words[18] = config.adapterConfigHash;
        words[19] = bytes32(uint256(config.restrictionMode));
        words[20] = _addressWord(config.settlementToken);
        words[21] = config.settlementTokenConfigId;
        words[22] = config.settlementTokenConfigHash;
        words[23] = _addressWord(config.dvpContract);
        words[24] = config.deploymentVersionHash;
        words[25] = config.replacesAssetVersionId;
        return _hashWords(words);
    }

    function hashSettlementTokenConfig(SettlementTokenConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](15);
        words[0] = SETTLEMENT_TOKEN_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.configId;
        words[3] = bytes32(uint256(config.revision));
        words[4] = bytes32(config.chainId);
        words[5] = _addressWord(config.settlementToken);
        words[6] = bytes32(uint256(config.tokenDeploymentKind));
        words[7] = bytes32(uint256(config.settlementTokenDecimals));
        words[8] = config.tokenCodeHash;
        words[9] = _addressWord(config.implementation);
        words[10] = config.implementationCodeHash;
        words[11] = config.adapterConfigId;
        words[12] = config.adapterConfigHash;
        words[13] = bytes32(uint256(config.permitCapability));
        words[14] = config.replacesConfigId;
        return _hashWords(words);
    }

    function hashAdapterCapabilities(AdapterCapabilities memory capabilities) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ADAPTER_CAPABILITIES_TYPEHASH,
                capabilities.tokenStandard,
                capabilities.restrictionMode,
                capabilities.precheckMethod,
                capabilities.transferLegMask
            )
        );
    }

    function hashRestrictionProvider(RestrictionProvider memory provider) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(RESTRICTION_PROVIDER_TYPEHASH, provider.provider, provider.selector, provider.codeHash)
            );
    }

    function hashRestrictionProviderSet(RestrictionProviderSet memory providerSet) internal pure returns (bytes32) {
        bytes32[] memory providerHashes = new bytes32[](providerSet.providers.length);
        for (uint256 index; index < providerSet.providers.length; ++index) {
            if (index != 0 && !_providerLess(providerSet.providers[index - 1], providerSet.providers[index])) {
                revert HTPErrors.InvalidRestrictionProviderOrder(index);
            }
            providerHashes[index] = hashRestrictionProvider(providerSet.providers[index]);
        }
        return keccak256(abi.encode(RESTRICTION_PROVIDER_SET_TYPEHASH, _hashWords(providerHashes)));
    }

    function hashAdapterConfig(AdapterConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](12);
        words[0] = ADAPTER_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.adapterConfigId;
        words[3] = bytes32(uint256(config.revision));
        words[4] = bytes32(config.chainId);
        words[5] = _addressWord(config.adapter);
        words[6] = config.interfaceVersion;
        words[7] = config.codeHash;
        words[8] = hashAdapterCapabilities(config.capabilities);
        words[9] = config.capabilityHash;
        words[10] = config.providerHash;
        words[11] = config.replacesId;
        return _hashWords(words);
    }

    function hashPrincipalCalculatorConfig(PrincipalCalculatorConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](10);
        words[0] = PRINCIPAL_CALCULATOR_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.calculatorConfigId;
        words[3] = bytes32(uint256(config.revision));
        words[4] = bytes32(config.chainId);
        words[5] = bytes32(uint256(config.assetClass));
        words[6] = _addressWord(config.calculator);
        words[7] = config.interfaceVersion;
        words[8] = config.codeHash;
        words[9] = config.replacesId;
        return _hashWords(words);
    }

    function hashMarketRuleConfig(MarketRuleConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](19);
        words[0] = MARKET_RULE_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.marketRuleConfigId;
        words[3] = bytes32(uint256(config.revision));
        words[4] = bytes32(config.chainId);
        words[5] = config.assetVersionId;
        words[6] = _addressWord(config.settlementToken);
        words[7] = config.settlementTokenConfigId;
        words[8] = config.settlementTokenConfigHash;
        words[9] = bytes32(config.minCashPrincipal);
        words[10] = bytes32(config.minExecutableQuantity);
        words[11] = bytes32(config.quantityStep);
        words[12] = bytes32(config.priceTick);
        words[13] = bytes32(uint256(config.priceDecimals));
        words[14] = bytes32(uint256(config.quantityDecimals));
        words[15] = bytes32(uint256(config.quoteValidFrom));
        words[16] = bytes32(uint256(config.quoteValidUntil));
        words[17] = bytes32(uint256(config.settlementValidUntil));
        words[18] = config.replacesConfigId;
        return _hashWords(words);
    }

    function hashFeePolicyEpochConfig(FeePolicyEpochConfig memory config) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FEE_POLICY_EPOCH_CONFIG_TYPEHASH,
                config.schemaVersion,
                config.feePolicyEpoch,
                config.chainId,
                config.quoteValidFrom,
                config.quoteValidUntil,
                config.settlementValidUntil
            )
        );
    }

    function hashFeeConstraint(FeeConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](17);
        words[0] = FEE_CONSTRAINT_TYPEHASH;
        words[1] = bytes32(uint256(config.feePolicyEpoch));
        words[2] = config.feeVersionId;
        words[3] = config.matchedScopeHash;
        words[4] = bytes32(uint256(config.investorRateBps));
        words[5] = _boolWord(config.investorHasCap);
        words[6] = bytes32(config.investorCapAmount);
        words[7] = bytes32(uint256(config.makerRateBps));
        words[8] = _boolWord(config.makerHasCap);
        words[9] = bytes32(config.makerCapAmount);
        words[10] = bytes32(uint256(config.roundingMode));
        words[11] = _addressWord(config.settlementToken);
        words[12] = config.settlementTokenConfigId;
        words[13] = config.settlementTokenConfigHash;
        words[14] = _addressWord(config.collector);
        words[15] = bytes32(uint256(config.validFrom));
        words[16] = bytes32(uint256(config.validUntil));
        return _hashWords(words);
    }

    function hashFeeConfig(FeeConfig memory config) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](24);
        words[0] = FEE_CONFIG_TYPEHASH;
        words[1] = bytes32(uint256(config.schemaVersion));
        words[2] = config.feeVersionId;
        words[3] = bytes32(uint256(config.revision));
        words[4] = bytes32(config.chainId);
        words[5] = bytes32(uint256(config.feePolicyEpoch));
        words[6] = bytes32(uint256(config.scopeType));
        words[7] = config.scopeKeyHash;
        words[8] = config.matchedScopeHash;
        words[9] = bytes32(uint256(config.investorRateBps));
        words[10] = _boolWord(config.investorHasCap);
        words[11] = bytes32(config.investorCapAmount);
        words[12] = bytes32(uint256(config.makerRateBps));
        words[13] = _boolWord(config.makerHasCap);
        words[14] = bytes32(config.makerCapAmount);
        words[15] = bytes32(uint256(config.roundingMode));
        words[16] = _addressWord(config.settlementToken);
        words[17] = config.settlementTokenConfigId;
        words[18] = config.settlementTokenConfigHash;
        words[19] = _addressWord(config.collector);
        words[20] = bytes32(uint256(config.validFrom));
        words[21] = bytes32(uint256(config.validUntil));
        words[22] = config.feeConstraintHash;
        words[23] = config.replacesFeeVersionId;
        return _hashWords(words);
    }

    function _addressWord(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    /// @dev EIP-712 bool encoding: false=0, true=1.
    function _boolWord(bool value) private pure returns (bytes32) {
        return value ? bytes32(uint256(1)) : bytes32(0);
    }

    function _providerLess(RestrictionProvider memory left, RestrictionProvider memory right)
        private
        pure
        returns (bool)
    {
        if (left.provider != right.provider) {
            return uint160(left.provider) < uint160(right.provider);
        }
        if (left.selector != right.selector) {
            return uint32(left.selector) < uint32(right.selector);
        }
        return uint256(left.codeHash) < uint256(right.codeHash);
    }

    function _hashWords(bytes32[] memory words) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := keccak256(add(words, 0x20), mul(mload(words), 0x20))
        }
    }
}
