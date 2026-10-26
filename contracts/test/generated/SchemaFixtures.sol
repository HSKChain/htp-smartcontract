// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// GENERATED FILE — DO NOT EDIT.
// generatedFrom schema-tools SchemaModel + schema/v1/vectors
// typesSource derived from contracts/src/types/HTPTypes.sol AST
// solc 0.8.36

import {
    AdapterCapabilities,
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    FirmQuote,
    FundPriceTerms,
    MarketRuleConfig,
    NonceCancellation,
    NonceType,
    ParticipantType,
    PermitCapability,
    PrecheckMethod,
    PrincipalCalculatorConfig,
    RequesterSide,
    RestrictionMode,
    RestrictionProvider,
    RestrictionProviderSet,
    RoundingMode,
    ScopeType,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard,
    TradeIntent,
    TradeTermsSnapshot
} from "src/types/HTPTypes.sol";

library SchemaFixtures {
    bytes32 internal constant ASSET_VERSION_ID = 0xa1421a5caa47ea05360cbc0daf6605b6316cb7d099be0e5fee8e69ad6fe25ab2;
    bytes32 internal constant PRICE_TERMS_HASH = 0x43dd8313df1b71f18f367e8a41d0af124cb97d0297aae168e2d9a0132a7dd439;
    bytes32 internal constant SETTLEMENT_TOKEN_CONFIG_ID =
        0x93a9f7e8cc087fd5094f4e896464b19fc0eb27f721df6ed7946a19a38dc8139b;
    bytes32 internal constant FEE_VERSION_ID = 0x57f01ad65f5298cf3b333b2d1c4302ea6285f78353c2058b734a4f1fbddb684e;
    bytes32 internal constant MATCHED_SCOPE_HASH = 0xf3b89e35fb08387e5b0aec59820139c4570d7a1e89bd9807e0f2e2cd294c69ce;
    bytes32 internal constant FEE_CONSTRAINT_HASH = 0x96fd3a47b56b27d4bf98c87953437d926ac54b6da606e58bcf17cc646793488a;
    bytes32 internal constant QUOTE_HASH = 0xc2b38ad8616829b7dd6eb761130f83f955c460c5b93608bbea086c1aa7a17104;
    bytes32 internal constant SNAPSHOT_HASH = 0x8f21d2562a755fffbca93d82bf27bc3ec4aa4ac1879211220984b8faf447ecaf;
    bytes32 internal constant ADAPTER_CONFIG_ID = 0x3432fb32089eac8af610b2a9f6f6fa6cc95f1f9baca25badc2cbd7a611c1d49b;
    bytes32 internal constant PRINCIPAL_CONFIG_ID = 0xb01a2f54f4e1dd8b1a05725f2ce09ebcc2ba38546cf712b66ebe69722c923f62;
    bytes32 internal constant MARKET_RULE_CONFIG_ID =
        0x9e5e9f8f126c16a513f05f4f409d388199e11ee1397380ec944c8f38eed581f6;
    bytes32 internal constant MARKET_RULE_CONFIG_HASH =
        0xe2ad1f625696336153488019c07802d5f894dc0bb0d8b2087cd7646fd2a704ba;

    function priceData() internal pure returns (bytes memory) {
        return
            abi.encode(FundPriceTerms({navPerUnit: 1140000, navDate: 20260810, navSourceHash: bytes32(uint256(0x201))}));
    }

    function firmQuote() internal pure returns (FirmQuote memory) {
        return FirmQuote({
            schemaVersion: 1,
            rfqIdHash: bytes32(uint256(0x601)),
            quoteIdHash: bytes32(uint256(0x602)),
            tradeIdHash: bytes32(uint256(0x501)),
            quoteVersion: 1,
            quotingMaker: address(0xb001),
            requester: address(0xb002),
            requesterType: ParticipantType.INVESTOR,
            assetVersionId: ASSET_VERSION_ID,
            requesterSide: RequesterSide.BUY,
            assetToken: address(0xa001),
            settlementToken: address(0xc001),
            assetClass: AssetClass.FUND,
            priceTermsHash: PRICE_TERMS_HASH,
            priceData: priceData(),
            principalCalculatorConfigId: bytes32(uint256(0x401)),
            principalCalculatorConfigHash: bytes32(uint256(0x402)),
            adapterConfigId: bytes32(uint256(0x403)),
            adapterConfigHash: bytes32(uint256(0x404)),
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: bytes32(uint256(0x301)),
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            marketRuleConfigHash: MARKET_RULE_CONFIG_HASH,
            minExecutableQuantity: 1 ether,
            maxExecutableQuantity: 100 ether,
            stepQuantity: 1 ether,
            feePolicyEpoch: 7,
            feeVersionId: FEE_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            quoteNonce: 41,
            expiresAt: 1785000000
        });
    }

    function snapshot() internal pure returns (TradeTermsSnapshot memory) {
        return TradeTermsSnapshot({
            schemaVersion: 1,
            tradeIdHash: bytes32(uint256(0x501)),
            quoteHash: QUOTE_HASH,
            chainId: 31337,
            dvpContract: address(0xd001),
            requester: address(0xb002),
            requesterType: ParticipantType.INVESTOR,
            quotingMaker: address(0xb001),
            requesterSide: RequesterSide.BUY,
            buyer: address(0xb002),
            seller: address(0xb001),
            assetVersionId: ASSET_VERSION_ID,
            assetToken: address(0xa001),
            settlementToken: address(0xc001),
            assetDecimals: 18,
            settlementTokenDecimals: 6,
            executedQuantity: 10 ether,
            assetClass: AssetClass.FUND,
            priceTermsHash: PRICE_TERMS_HASH,
            priceData: priceData(),
            principalCalculatorConfigId: bytes32(uint256(0x401)),
            principalCalculatorConfigHash: bytes32(uint256(0x402)),
            adapterConfigId: bytes32(uint256(0x403)),
            adapterConfigHash: bytes32(uint256(0x404)),
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: bytes32(uint256(0x301)),
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            marketRuleConfigHash: MARKET_RULE_CONFIG_HASH,
            cashPrincipal: 11400000,
            buyerFee: 28500,
            sellerFee: 17100,
            buyerDebit: 11428500,
            sellerCredit: 11382900,
            collectorCredit: 45600,
            collector: address(0xc011),
            feePolicyEpoch: 7,
            feeVersionId: FEE_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            roundingMode: RoundingMode.DOWN,
            makerQuoteNonce: 41,
            requesterTradeNonce: 52,
            quoteExpiresAt: 1785000000,
            tradeDeadline: 1784900000,
            createdAt: 1780000100
        });
    }

    function tradeIntent() internal pure returns (TradeIntent memory) {
        TradeTermsSnapshot memory value = snapshot();
        return TradeIntent({
            schemaVersion: 1,
            tradeIdHash: value.tradeIdHash,
            quoteHash: QUOTE_HASH,
            snapshotHash: SNAPSHOT_HASH,
            requester: value.requester,
            requesterType: value.requesterType,
            quotingMaker: value.quotingMaker,
            assetVersionId: value.assetVersionId,
            requesterSide: value.requesterSide,
            buyer: value.buyer,
            seller: value.seller,
            assetToken: value.assetToken,
            settlementToken: value.settlementToken,
            executedQuantity: value.executedQuantity,
            assetClass: value.assetClass,
            priceTermsHash: value.priceTermsHash,
            priceData: value.priceData,
            principalCalculatorConfigId: value.principalCalculatorConfigId,
            principalCalculatorConfigHash: value.principalCalculatorConfigHash,
            adapterConfigId: value.adapterConfigId,
            adapterConfigHash: value.adapterConfigHash,
            settlementTokenConfigId: value.settlementTokenConfigId,
            settlementTokenConfigHash: value.settlementTokenConfigHash,
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            marketRuleConfigHash: MARKET_RULE_CONFIG_HASH,
            cashPrincipal: value.cashPrincipal,
            buyerFee: value.buyerFee,
            sellerFee: value.sellerFee,
            buyerDebit: value.buyerDebit,
            sellerCredit: value.sellerCredit,
            collectorCredit: value.collectorCredit,
            collector: value.collector,
            feePolicyEpoch: value.feePolicyEpoch,
            feeVersionId: value.feeVersionId,
            matchedScopeHash: value.matchedScopeHash,
            feeConstraintHash: value.feeConstraintHash,
            roundingMode: value.roundingMode,
            tradeNonce: value.requesterTradeNonce,
            deadline: value.tradeDeadline
        });
    }

    function nonceCancellation() internal pure returns (NonceCancellation memory) {
        return
            NonceCancellation({
                signer: address(0xb001), nonceType: NonceType.MAKER_QUOTE, nonce: 41, deadline: 1784000000
            });
    }

    function assetVersionConfig() internal pure returns (AssetVersionConfig memory) {
        return AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: bytes32(uint256(0x101)),
            assetVersionId: ASSET_VERSION_ID,
            chainId: 31337,
            versionNo: 1,
            assetToken: address(0xa001),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.ERC1967_PROXY,
            assetDecimals: 18,
            tokenCodeHash: bytes32(uint256(0xb01)),
            implementation: address(0xa002),
            implementationCodeHash: bytes32(uint256(0xb02)),
            assetPermitCapability: PermitCapability.EIP2612,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: PRINCIPAL_CONFIG_ID,
            principalCalculatorConfigHash: bytes32(uint256(0xb03)),
            adapterConfigId: ADAPTER_CONFIG_ID,
            adapterConfigHash: bytes32(uint256(0xb04)),
            restrictionMode: RestrictionMode.PLATFORM,
            settlementToken: address(0xc001),
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: bytes32(uint256(0xb05)),
            dvpContract: address(0xd001),
            deploymentVersionHash: 0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42,
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function settlementTokenConfig() internal pure returns (SettlementTokenConfig memory) {
        return SettlementTokenConfig({
            schemaVersion: 1,
            configId: SETTLEMENT_TOKEN_CONFIG_ID,
            revision: 1,
            chainId: 31337,
            settlementToken: address(0xc001),
            tokenDeploymentKind: TokenDeploymentKind.ERC1967_PROXY,
            settlementTokenDecimals: 6,
            tokenCodeHash: bytes32(uint256(0xa01)),
            implementation: address(0xc002),
            implementationCodeHash: bytes32(uint256(0xa02)),
            adapterConfigId: ADAPTER_CONFIG_ID,
            adapterConfigHash: bytes32(uint256(0xa03)),
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function adapterCapabilities() internal pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.PLATFORM,
            precheckMethod: PrecheckMethod.TOKEN_SPECIFIC_CHECK,
            transferLegMask: 14
        });
    }

    function providerSet() internal pure returns (RestrictionProviderSet memory result) {
        result.providers = new RestrictionProvider[](2);
        result.providers[0] =
            RestrictionProvider({provider: address(0xe001), selector: 0x01020304, codeHash: bytes32(uint256(0x801))});
        result.providers[1] =
            RestrictionProvider({provider: address(0xe002), selector: 0x05060708, codeHash: bytes32(uint256(0x802))});
    }

    function adapterConfig() internal pure returns (AdapterConfig memory) {
        return AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ADAPTER_CONFIG_ID,
            revision: 1,
            chainId: 31337,
            adapter: address(0xe101),
            interfaceVersion: bytes32(uint256(0x803)),
            codeHash: bytes32(uint256(0x804)),
            capabilities: adapterCapabilities(),
            capabilityHash: 0x152063e52bb5922fd31769b05858b799d3603b488d6a5c64f177daf11189aa22,
            providerHash: 0x96298c997293e6def5721fe524fa1d21ad5a4e65a3b7a93e8001494e23685d43,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function principalConfig() internal pure returns (PrincipalCalculatorConfig memory) {
        return PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: PRINCIPAL_CONFIG_ID,
            revision: 1,
            chainId: 31337,
            assetClass: AssetClass.FUND,
            calculator: address(0xf001),
            interfaceVersion: 0x79b97198c84fbb044cdda584716b22b5f0da3a199307ca0dea63b2e03e72f10f,
            codeHash: bytes32(uint256(0x902)),
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function feePolicyEpochConfig() internal pure returns (FeePolicyEpochConfig memory) {
        return FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: 7,
            chainId: 31337,
            quoteValidFrom: 1780000000,
            quoteValidUntil: 1785000000,
            settlementValidUntil: 1790000000,
            configHash: bytes32(0)
        });
    }

    function feeConfig() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            schemaVersion: 1,
            feeVersionId: FEE_VERSION_ID,
            revision: 1,
            chainId: 31337,
            feePolicyEpoch: 7,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: ASSET_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(0xc001),
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: bytes32(uint256(0x301)),
            collector: address(0xc011),
            validFrom: 1780000000,
            validUntil: 1790000000,
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function marketRuleConfig() internal pure returns (MarketRuleConfig memory) {
        return MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            revision: 1,
            chainId: 31337,
            assetVersionId: ASSET_VERSION_ID,
            settlementToken: address(0xc001),
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: bytes32(uint256(0x301)),
            minCashPrincipal: 1,
            minExecutableQuantity: 1 ether,
            quantityStep: 1 ether,
            priceTick: 10000,
            priceDecimals: 2,
            quantityDecimals: 18,
            quoteValidFrom: 1780000000,
            quoteValidUntil: 1785000000,
            settlementValidUntil: 1790000000,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
    }
}
