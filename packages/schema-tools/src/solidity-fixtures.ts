import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { VECTOR_PATHS, schemaRepoPath } from "./paths.js";
import { checkFormattedSolidity, writeFormattedSolidity } from "./generated-solidity.js";
import { buildSchemaModel, type SchemaModel } from "./model.js";
import { buildBootstrapVectors } from "./vectors.js";

const FIXTURES_RELATIVE = "test/generated/SchemaFixtures.sol";

function enumName(model: SchemaModel, enumType: string, value: number): string {
  const member = model.enums[enumType]?.find((entry) => entry.value === value);
  if (!member) throw new Error(`Unknown ${enumType} value ${value}`);
  return `${enumType}.${member.name}`;
}

function bytes32Literal(value: string): string {
  const hex = value.toLowerCase();
  if (hex === `0x${"00".repeat(32)}`) return "bytes32(0)";
  const numeric = BigInt(hex);
  if (numeric > 0n && numeric < 0x10000n) return `bytes32(uint256(0x${numeric.toString(16)}))`;
  return hex;
}

function addressLiteral(value: string): string {
  const numeric = BigInt(value);
  return `address(0x${numeric.toString(16)})`;
}

function uintLiteral(value: string | number | bigint): string {
  const numeric = BigInt(`${value}`.replace(/n$/u, ""));
  if (numeric === 0n) return "0";
  const ether = 10n ** 18n;
  if (numeric % ether === 0n && numeric / ether <= 1000n) return `${numeric / ether} ether`;
  return numeric.toString();
}

export function renderSchemaFixtures(repositoryRoot: string): string {
  const model = buildSchemaModel(repositoryRoot);
  const vectors = buildBootstrapVectors(repositoryRoot);
  const firmQuote = (vectors[schemaRepoPath(VECTOR_PATHS.firmQuote)] as any).input;
  const snapshot = (vectors[schemaRepoPath(VECTOR_PATHS.tradeTermsSnapshot)] as any).input;
  const tradeIntent = (vectors[schemaRepoPath(VECTOR_PATHS.tradeIntent)] as any).input;
  const nonce = (vectors[schemaRepoPath(VECTOR_PATHS.nonceCancellation)] as any).input;
  const domain = (vectors[schemaRepoPath(VECTOR_PATHS.domain)] as any);
  const asset = (vectors[schemaRepoPath(VECTOR_PATHS.assetVersion)] as any).input;
  const settlement = (vectors[schemaRepoPath(VECTOR_PATHS.settlementToken)] as any).input;
  const adapter = (vectors[schemaRepoPath(VECTOR_PATHS.adapter)] as any);
  const principal = (vectors[schemaRepoPath(VECTOR_PATHS.principalCalculator)] as any).input;
  const marketRule = (vectors[schemaRepoPath(VECTOR_PATHS.marketRule)] as any).input;
  const fee = (vectors[schemaRepoPath(VECTOR_PATHS.fee)] as any);
  const fundTerms = (vectors[schemaRepoPath(VECTOR_PATHS.priceterms)] as any).fund.input;

  return `// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// GENERATED FILE — DO NOT EDIT.
// generatedFrom schema-tools SchemaModel + schema/v1/vectors
// typesSource derived from contracts/src/types/HTPTypes.sol AST
// solc ${model.solcLongVersion}

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
    bytes32 internal constant ASSET_VERSION_ID = ${bytes32Literal(firmQuote.assetVersionId)};
    bytes32 internal constant PRICE_TERMS_HASH = ${bytes32Literal(firmQuote.priceTermsHash)};
    bytes32 internal constant SETTLEMENT_TOKEN_CONFIG_ID =
        ${bytes32Literal(firmQuote.settlementTokenConfigId)};
    bytes32 internal constant FEE_VERSION_ID = ${bytes32Literal(firmQuote.feeVersionId)};
    bytes32 internal constant MATCHED_SCOPE_HASH = ${bytes32Literal(firmQuote.matchedScopeHash)};
    bytes32 internal constant FEE_CONSTRAINT_HASH = ${bytes32Literal(firmQuote.feeConstraintHash)};
    bytes32 internal constant QUOTE_HASH = ${bytes32Literal(snapshot.quoteHash)};
    bytes32 internal constant SNAPSHOT_HASH = ${bytes32Literal(tradeIntent.snapshotHash)};
    bytes32 internal constant ADAPTER_CONFIG_ID = ${bytes32Literal(adapter.config.input.adapterConfigId)};
    bytes32 internal constant PRINCIPAL_CONFIG_ID = ${bytes32Literal(principal.calculatorConfigId)};
    bytes32 internal constant MARKET_RULE_CONFIG_ID = ${bytes32Literal(marketRule.marketRuleConfigId)};
    bytes32 internal constant MARKET_RULE_CONFIG_HASH = ${bytes32Literal(
      (vectors[schemaRepoPath(VECTOR_PATHS.marketRule)] as any).hash,
    )};

    function priceData() internal pure returns (bytes memory) {
        return abi.encode(
            FundPriceTerms({
                navPerUnit: ${uintLiteral(fundTerms.navPerUnit)},
                navDate: ${uintLiteral(fundTerms.navDate)},
                navSourceHash: ${bytes32Literal(fundTerms.navSourceHash)}
            })
        );
    }

    function firmQuote() internal pure returns (FirmQuote memory) {
        return FirmQuote({
            schemaVersion: ${uintLiteral(firmQuote.schemaVersion)},
            rfqIdHash: ${bytes32Literal(firmQuote.rfqIdHash)},
            quoteIdHash: ${bytes32Literal(firmQuote.quoteIdHash)},
            tradeIdHash: ${bytes32Literal(firmQuote.tradeIdHash)},
            quoteVersion: ${uintLiteral(firmQuote.quoteVersion)},
            quotingMaker: ${addressLiteral(firmQuote.quotingMaker)},
            requester: ${addressLiteral(firmQuote.requester)},
            requesterType: ${enumName(model, "ParticipantType", firmQuote.requesterType)},
            assetVersionId: ASSET_VERSION_ID,
            requesterSide: ${enumName(model, "RequesterSide", firmQuote.requesterSide)},
            assetToken: ${addressLiteral(firmQuote.assetToken)},
            settlementToken: ${addressLiteral(firmQuote.settlementToken)},
            assetClass: ${enumName(model, "AssetClass", firmQuote.assetClass)},
            priceTermsHash: PRICE_TERMS_HASH,
            priceData: priceData(),
            principalCalculatorConfigId: ${bytes32Literal(firmQuote.principalCalculatorConfigId)},
            principalCalculatorConfigHash: ${bytes32Literal(firmQuote.principalCalculatorConfigHash)},
            adapterConfigId: ${bytes32Literal(firmQuote.adapterConfigId)},
            adapterConfigHash: ${bytes32Literal(firmQuote.adapterConfigHash)},
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: ${bytes32Literal(firmQuote.settlementTokenConfigHash)},
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            marketRuleConfigHash: MARKET_RULE_CONFIG_HASH,
            minExecutableQuantity: ${uintLiteral(firmQuote.minExecutableQuantity)},
            maxExecutableQuantity: ${uintLiteral(firmQuote.maxExecutableQuantity)},
            stepQuantity: ${uintLiteral(firmQuote.stepQuantity)},
            feePolicyEpoch: ${uintLiteral(firmQuote.feePolicyEpoch)},
            feeVersionId: FEE_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            quoteNonce: ${uintLiteral(firmQuote.quoteNonce)},
            expiresAt: ${uintLiteral(firmQuote.expiresAt)}
        });
    }

    function snapshot() internal pure returns (TradeTermsSnapshot memory) {
        return TradeTermsSnapshot({
            schemaVersion: ${uintLiteral(snapshot.schemaVersion)},
            tradeIdHash: ${bytes32Literal(snapshot.tradeIdHash)},
            quoteHash: QUOTE_HASH,
            chainId: ${uintLiteral(snapshot.chainId)},
            dvpContract: ${addressLiteral(snapshot.dvpContract)},
            requester: ${addressLiteral(snapshot.requester)},
            requesterType: ${enumName(model, "ParticipantType", snapshot.requesterType)},
            quotingMaker: ${addressLiteral(snapshot.quotingMaker)},
            requesterSide: ${enumName(model, "RequesterSide", snapshot.requesterSide)},
            buyer: ${addressLiteral(snapshot.buyer)},
            seller: ${addressLiteral(snapshot.seller)},
            assetVersionId: ASSET_VERSION_ID,
            assetToken: ${addressLiteral(snapshot.assetToken)},
            settlementToken: ${addressLiteral(snapshot.settlementToken)},
            assetDecimals: ${uintLiteral(snapshot.assetDecimals)},
            settlementTokenDecimals: ${uintLiteral(snapshot.settlementTokenDecimals)},
            executedQuantity: ${uintLiteral(snapshot.executedQuantity)},
            assetClass: ${enumName(model, "AssetClass", snapshot.assetClass)},
            priceTermsHash: PRICE_TERMS_HASH,
            priceData: priceData(),
            principalCalculatorConfigId: ${bytes32Literal(snapshot.principalCalculatorConfigId)},
            principalCalculatorConfigHash: ${bytes32Literal(snapshot.principalCalculatorConfigHash)},
            adapterConfigId: ${bytes32Literal(snapshot.adapterConfigId)},
            adapterConfigHash: ${bytes32Literal(snapshot.adapterConfigHash)},
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: ${bytes32Literal(snapshot.settlementTokenConfigHash)},
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            marketRuleConfigHash: MARKET_RULE_CONFIG_HASH,
            cashPrincipal: ${uintLiteral(snapshot.cashPrincipal)},
            buyerFee: ${uintLiteral(snapshot.buyerFee)},
            sellerFee: ${uintLiteral(snapshot.sellerFee)},
            buyerDebit: ${uintLiteral(snapshot.buyerDebit)},
            sellerCredit: ${uintLiteral(snapshot.sellerCredit)},
            collectorCredit: ${uintLiteral(snapshot.collectorCredit)},
            collector: ${addressLiteral(snapshot.collector)},
            feePolicyEpoch: ${uintLiteral(snapshot.feePolicyEpoch)},
            feeVersionId: FEE_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            roundingMode: ${enumName(model, "RoundingMode", snapshot.roundingMode)},
            makerQuoteNonce: ${uintLiteral(snapshot.makerQuoteNonce)},
            requesterTradeNonce: ${uintLiteral(snapshot.requesterTradeNonce)},
            quoteExpiresAt: ${uintLiteral(snapshot.quoteExpiresAt)},
            tradeDeadline: ${uintLiteral(snapshot.tradeDeadline)},
            createdAt: ${uintLiteral(snapshot.createdAt)}
        });
    }

    function tradeIntent() internal pure returns (TradeIntent memory) {
        TradeTermsSnapshot memory value = snapshot();
        return TradeIntent({
            schemaVersion: ${uintLiteral(tradeIntent.schemaVersion)},
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
        return NonceCancellation({
            signer: ${addressLiteral(nonce.signer)},
            nonceType: ${enumName(model, "NonceType", nonce.nonceType)},
            nonce: ${uintLiteral(nonce.nonce)},
            deadline: ${uintLiteral(nonce.deadline)}
        });
    }

    function assetVersionConfig() internal pure returns (AssetVersionConfig memory) {
        return AssetVersionConfig({
            schemaVersion: ${uintLiteral(asset.schemaVersion)},
            economicAssetIdHash: ${bytes32Literal(asset.economicAssetIdHash)},
            assetVersionId: ASSET_VERSION_ID,
            chainId: ${uintLiteral(asset.chainId)},
            versionNo: ${uintLiteral(asset.versionNo)},
            assetToken: ${addressLiteral(asset.assetToken)},
            tokenStandard: ${enumName(model, "TokenStandard", asset.tokenStandard)},
            tokenDeploymentKind: ${enumName(model, "TokenDeploymentKind", asset.tokenDeploymentKind)},
            assetDecimals: ${uintLiteral(asset.assetDecimals)},
            tokenCodeHash: ${bytes32Literal(asset.tokenCodeHash)},
            implementation: ${addressLiteral(asset.implementation)},
            implementationCodeHash: ${bytes32Literal(asset.implementationCodeHash)},
            assetPermitCapability: ${enumName(model, "PermitCapability", asset.assetPermitCapability)},
            assetClass: ${enumName(model, "AssetClass", asset.assetClass)},
            principalCalculatorConfigId: PRINCIPAL_CONFIG_ID,
            principalCalculatorConfigHash: ${bytes32Literal(asset.principalCalculatorConfigHash)},
            adapterConfigId: ADAPTER_CONFIG_ID,
            adapterConfigHash: ${bytes32Literal(asset.adapterConfigHash)},
            restrictionMode: ${enumName(model, "RestrictionMode", asset.restrictionMode)},
            settlementToken: ${addressLiteral(asset.settlementToken)},
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: ${bytes32Literal(asset.settlementTokenConfigHash)},
            dvpContract: ${addressLiteral(asset.dvpContract)},
            deploymentVersionHash: ${bytes32Literal(domain.deploymentVersionHash)},
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function settlementTokenConfig() internal pure returns (SettlementTokenConfig memory) {
        return SettlementTokenConfig({
            schemaVersion: ${uintLiteral(settlement.schemaVersion)},
            configId: SETTLEMENT_TOKEN_CONFIG_ID,
            revision: ${uintLiteral(settlement.revision)},
            chainId: ${uintLiteral(settlement.chainId)},
            settlementToken: ${addressLiteral(settlement.settlementToken)},
            tokenDeploymentKind: ${enumName(model, "TokenDeploymentKind", settlement.tokenDeploymentKind)},
            settlementTokenDecimals: ${uintLiteral(settlement.settlementTokenDecimals)},
            tokenCodeHash: ${bytes32Literal(settlement.tokenCodeHash)},
            implementation: ${addressLiteral(settlement.implementation)},
            implementationCodeHash: ${bytes32Literal(settlement.implementationCodeHash)},
            adapterConfigId: ADAPTER_CONFIG_ID,
            adapterConfigHash: ${bytes32Literal(settlement.adapterConfigHash)},
            permitCapability: ${enumName(model, "PermitCapability", settlement.permitCapability)},
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function adapterCapabilities() internal pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: ${enumName(model, "TokenStandard", adapter.capabilities.input.tokenStandard)},
            restrictionMode: ${enumName(model, "RestrictionMode", adapter.capabilities.input.restrictionMode)},
            precheckMethod: ${enumName(model, "PrecheckMethod", adapter.capabilities.input.precheckMethod)},
            transferLegMask: ${uintLiteral(adapter.capabilities.input.transferLegMask)}
        });
    }

    function providerSet() internal pure returns (RestrictionProviderSet memory result) {
        result.providers = new RestrictionProvider[](2);
        result.providers[0] = RestrictionProvider({
            provider: ${addressLiteral(adapter.providerSet.input.providers[0].provider)},
            selector: ${adapter.providerSet.input.providers[0].selector},
            codeHash: ${bytes32Literal(adapter.providerSet.input.providers[0].codeHash)}
        });
        result.providers[1] = RestrictionProvider({
            provider: ${addressLiteral(adapter.providerSet.input.providers[1].provider)},
            selector: ${adapter.providerSet.input.providers[1].selector},
            codeHash: ${bytes32Literal(adapter.providerSet.input.providers[1].codeHash)}
        });
    }

    function adapterConfig() internal pure returns (AdapterConfig memory) {
        return AdapterConfig({
            schemaVersion: ${uintLiteral(adapter.config.input.schemaVersion)},
            adapterConfigId: ADAPTER_CONFIG_ID,
            revision: ${uintLiteral(adapter.config.input.revision)},
            chainId: ${uintLiteral(adapter.config.input.chainId)},
            adapter: ${addressLiteral(adapter.config.input.adapter)},
            interfaceVersion: ${bytes32Literal(adapter.config.input.interfaceVersion)},
            codeHash: ${bytes32Literal(adapter.config.input.codeHash)},
            capabilities: adapterCapabilities(),
            capabilityHash: ${bytes32Literal(adapter.config.input.capabilityHash)},
            providerHash: ${bytes32Literal(adapter.config.input.providerHash)},
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function principalConfig() internal pure returns (PrincipalCalculatorConfig memory) {
        return PrincipalCalculatorConfig({
            schemaVersion: ${uintLiteral(principal.schemaVersion)},
            calculatorConfigId: PRINCIPAL_CONFIG_ID,
            revision: ${uintLiteral(principal.revision)},
            chainId: ${uintLiteral(principal.chainId)},
            assetClass: ${enumName(model, "AssetClass", principal.assetClass)},
            calculator: ${addressLiteral(principal.calculator)},
            interfaceVersion: ${bytes32Literal(principal.interfaceVersion)},
            codeHash: ${bytes32Literal(principal.codeHash)},
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function feePolicyEpochConfig() internal pure returns (FeePolicyEpochConfig memory) {
        return FeePolicyEpochConfig({
            schemaVersion: ${uintLiteral(fee.policyEpoch.input.schemaVersion)},
            feePolicyEpoch: ${uintLiteral(fee.policyEpoch.input.feePolicyEpoch)},
            chainId: ${uintLiteral(fee.policyEpoch.input.chainId)},
            quoteValidFrom: ${uintLiteral(fee.policyEpoch.input.quoteValidFrom)},
            quoteValidUntil: ${uintLiteral(fee.policyEpoch.input.quoteValidUntil)},
            settlementValidUntil: ${uintLiteral(fee.policyEpoch.input.settlementValidUntil)},
            configHash: bytes32(0)
        });
    }

    function feeConfig() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            schemaVersion: ${uintLiteral(fee.config.input.schemaVersion)},
            feeVersionId: FEE_VERSION_ID,
            revision: ${uintLiteral(fee.config.input.revision)},
            chainId: ${uintLiteral(fee.config.input.chainId)},
            feePolicyEpoch: ${uintLiteral(fee.config.input.feePolicyEpoch)},
            scopeType: ${enumName(model, "ScopeType", fee.config.input.scopeType)},
            scopeKeyHash: ASSET_VERSION_ID,
            matchedScopeHash: MATCHED_SCOPE_HASH,
            investorRateBps: ${uintLiteral(fee.config.input.investorRateBps)},
            investorHasCap: ${fee.config.input.investorHasCap},
            investorCapAmount: ${uintLiteral(fee.config.input.investorCapAmount)},
            makerRateBps: ${uintLiteral(fee.config.input.makerRateBps)},
            makerHasCap: ${fee.config.input.makerHasCap},
            makerCapAmount: ${uintLiteral(fee.config.input.makerCapAmount)},
            roundingMode: ${enumName(model, "RoundingMode", fee.config.input.roundingMode)},
            settlementToken: ${addressLiteral(fee.config.input.settlementToken)},
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: ${bytes32Literal(fee.config.input.settlementTokenConfigHash)},
            collector: ${addressLiteral(fee.config.input.collector)},
            validFrom: ${uintLiteral(fee.config.input.validFrom)},
            validUntil: ${uintLiteral(fee.config.input.validUntil)},
            feeConstraintHash: FEE_CONSTRAINT_HASH,
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function marketRuleConfig() internal pure returns (MarketRuleConfig memory) {
        return MarketRuleConfig({
            schemaVersion: ${uintLiteral(marketRule.schemaVersion)},
            marketRuleConfigId: MARKET_RULE_CONFIG_ID,
            revision: ${uintLiteral(marketRule.revision)},
            chainId: ${uintLiteral(marketRule.chainId)},
            assetVersionId: ASSET_VERSION_ID,
            settlementToken: ${addressLiteral(marketRule.settlementToken)},
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: ${bytes32Literal(marketRule.settlementTokenConfigHash)},
            minCashPrincipal: ${uintLiteral(marketRule.minCashPrincipal)},
            minExecutableQuantity: ${uintLiteral(marketRule.minExecutableQuantity)},
            quantityStep: ${uintLiteral(marketRule.quantityStep)},
            priceTick: ${uintLiteral(marketRule.priceTick)},
            priceDecimals: ${uintLiteral(marketRule.priceDecimals)},
            quantityDecimals: ${uintLiteral(marketRule.quantityDecimals)},
            quoteValidFrom: ${uintLiteral(marketRule.quoteValidFrom)},
            quoteValidUntil: ${uintLiteral(marketRule.quoteValidUntil)},
            settlementValidUntil: ${uintLiteral(marketRule.settlementValidUntil)},
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
    }
}
`;
}

export function writeSchemaFixtures(repositoryRoot: string): string {
  return writeFormattedSolidity(repositoryRoot, FIXTURES_RELATIVE, renderSchemaFixtures(repositoryRoot));
}

export function checkSchemaFixtures(repositoryRoot: string): void {
  checkFormattedSolidity(repositoryRoot, FIXTURES_RELATIVE, renderSchemaFixtures(repositoryRoot));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const repositoryRoot = resolve(import.meta.dirname, "../../..");
  const path = writeSchemaFixtures(repositoryRoot);
  console.log(`Wrote ${path}`);
}
