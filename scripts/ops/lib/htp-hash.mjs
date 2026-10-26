// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
import { concat, encodeAbiParameters, keccak256, pad, toBytes, toHex } from "viem";

export const SCHEMA_VERSION = 1;

export const Enum = Object.freeze({
  AssetClass: { NONE: 0, STOCK: 1, FUND: 2, BOND: 3 },
  TokenStandard: { NONE: 0, ERC20: 1, ERC1404: 2 },
  TokenDeploymentKind: { NONE: 0, DIRECT: 1, ERC1967_PROXY: 2 },
  ParticipantType: { NONE: 0, INVESTOR: 1, MAKER: 2 },
  ParticipantStatus: { NONE: 0, ACTIVE: 1, PAUSED: 2, REVOKED: 3 },
  PrecheckMethod: { NONE: 0, NO_PRECHECK: 1, ERC1404_CHECK: 2, TOKEN_SPECIFIC_CHECK: 3 },
  RestrictionMode: {
    NONE: 0,
    UNRESTRICTED: 1,
    PLATFORM: 2,
    ISSUER_EXTERNAL: 3,
    TOKEN_ENFORCED: 4,
  },
  PermitCapability: { NONE: 0, UNSUPPORTED: 1, EIP2612: 2 },
  RoundingMode: { NONE: 0, DOWN: 1 },
  Decision: { NONE: 0, PASS: 1, BLOCK: 2, UNKNOWN: 3 },
  ScopeType: {
    NONE: 0,
    GLOBAL: 1,
    CHAIN: 2,
    ASSET_CLASS: 3,
    INSTRUMENT: 4,
    ASSET_VERSION: 5,
  },
  AdapterStatus: { NONE: 0, REGISTERED: 1, ACTIVE: 2, PAUSED: 3, DEPRECATED: 4 },
  AssetVersionStatus: { NONE: 0, REGISTERED: 1, ACTIVE: 2, PAUSED: 3, DEPRECATED: 4 },
  SettlementTokenStatus: { NONE: 0, REGISTERED: 1, ACTIVE: 2, PAUSED: 3, DEPRECATED: 4 },
  CalculatorStatus: { NONE: 0, REGISTERED: 1, ACTIVE: 2, PAUSED: 3, DEPRECATED: 4 },
  FeeVersionStatus: { NONE: 0, REGISTERED: 1, ACTIVE: 2, PAUSED: 3, DEPRECATED: 4, DEPRECATED_PAUSED: 5 },
  FeePolicyEpochStatus: { NONE: 0, DRAFT: 1, ACTIVE: 2, LEGACY_SERVING: 3, CLOSED: 4 },
  MarketRuleStatus: { NONE: 0, DRAFT: 1, ACTIVE: 2, LEGACY_SERVING: 3, CLOSED: 4 },
});

export function keccakUtf8(value) {
  return keccak256(toBytes(value));
}

export const Namespace = Object.freeze({
  FEE: keccakUtf8("HTP_FEE_CONFIG"),
  SETTLEMENT_TOKEN: keccakUtf8("HTP_SETTLEMENT_TOKEN_CONFIG"),
  ADAPTER: keccakUtf8("HTP_ADAPTER_CONFIG"),
  PRINCIPAL_CALCULATOR: keccakUtf8("HTP_PRINCIPAL_CALCULATOR_CONFIG"),
  MARKET_RULE: keccakUtf8("HTP_MARKET_RULE_CONFIG"),
  DEPLOYMENT_VERSION: keccakUtf8("HTP_DEPLOYMENT_VERSION"),
});

export const InterfaceVersion = Object.freeze({
  ASSET_ADAPTER_V1: keccakUtf8("HTP_IASSET_ADAPTER_V1"),
  PRINCIPAL_CALCULATOR_V1: keccakUtf8("HTP_IPRINCIPAL_CALCULATOR_V1"),
});

export const Typehash = Object.freeze({
  ADAPTER_CAPABILITIES: keccakUtf8(
    "AdapterCapabilities(uint8 tokenStandard,uint8 restrictionMode,uint8 precheckMethod,uint256 transferLegMask)",
  ),
  ADAPTER_CONFIG: keccakUtf8(
    "AdapterConfig(uint32 schemaVersion,bytes32 adapterConfigId,uint32 revision,uint256 chainId,address adapter,bytes32 interfaceVersion,bytes32 codeHash,AdapterCapabilities capabilities,bytes32 capabilityHash,bytes32 providerHash,bytes32 replacesId)AdapterCapabilities(uint8 tokenStandard,uint8 restrictionMode,uint8 precheckMethod,uint256 transferLegMask)",
  ),
  PRINCIPAL_CALCULATOR_CONFIG: keccakUtf8(
    "PrincipalCalculatorConfig(uint32 schemaVersion,bytes32 calculatorConfigId,uint32 revision,uint256 chainId,uint8 assetClass,address calculator,bytes32 interfaceVersion,bytes32 codeHash,bytes32 replacesId)",
  ),
  SETTLEMENT_TOKEN_CONFIG: keccakUtf8(
    "SettlementTokenConfig(uint32 schemaVersion,bytes32 configId,uint32 revision,uint256 chainId,address settlementToken,uint8 tokenDeploymentKind,uint8 settlementTokenDecimals,bytes32 tokenCodeHash,address implementation,bytes32 implementationCodeHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,uint8 permitCapability,bytes32 replacesConfigId)",
  ),
  ASSET_VERSION_CONFIG: keccakUtf8(
    "AssetVersionConfig(uint32 schemaVersion,bytes32 economicAssetIdHash,bytes32 assetVersionId,uint256 chainId,uint32 versionNo,address assetToken,uint8 tokenStandard,uint8 tokenDeploymentKind,uint8 assetDecimals,bytes32 tokenCodeHash,address implementation,bytes32 implementationCodeHash,uint8 assetPermitCapability,uint8 assetClass,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,uint8 restrictionMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address dvpContract,bytes32 deploymentVersionHash,bytes32 replacesAssetVersionId)",
  ),
  MARKET_RULE_CONFIG: keccakUtf8(
    "MarketRuleConfig(uint32 schemaVersion,bytes32 marketRuleConfigId,uint32 revision,uint256 chainId,bytes32 assetVersionId,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,uint256 minCashPrincipal,uint256 minExecutableQuantity,uint256 quantityStep,uint256 priceTick,uint8 priceDecimals,uint8 quantityDecimals,uint64 quoteValidFrom,uint64 quoteValidUntil,uint64 settlementValidUntil,bytes32 replacesConfigId)",
  ),
  FEE_POLICY_EPOCH_CONFIG: keccakUtf8(
    "FeePolicyEpochConfig(uint32 schemaVersion,uint64 feePolicyEpoch,uint256 chainId,uint64 quoteValidFrom,uint64 quoteValidUntil,uint64 settlementValidUntil)",
  ),
  FEE_CONSTRAINT: keccakUtf8(
    "FeeConstraint(uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,uint16 investorRateBps,bool investorHasCap,uint256 investorCapAmount,uint16 makerRateBps,bool makerHasCap,uint256 makerCapAmount,uint8 roundingMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address collector,uint64 validFrom,uint64 validUntil)",
  ),
  FEE_CONFIG: keccakUtf8(
    "FeeConfig(uint32 schemaVersion,bytes32 feeVersionId,uint32 revision,uint256 chainId,uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash,bytes32 matchedScopeHash,uint16 investorRateBps,bool investorHasCap,uint256 investorCapAmount,uint16 makerRateBps,bool makerHasCap,uint256 makerCapAmount,uint8 roundingMode,address settlementToken,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,address collector,uint64 validFrom,uint64 validUntil,bytes32 feeConstraintHash,bytes32 replacesFeeVersionId)",
  ),
  FEE_SCOPE: keccakUtf8("FeeScope(uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash)"),
});

export const ZERO_BYTES32 = `0x${"00".repeat(32)}`;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export function wordUint(value) {
  return pad(toHex(typeof value === "bigint" ? value : BigInt(value)), { size: 32 });
}

export function wordAddress(value) {
  return pad(value, { size: 32 });
}

export function wordBool(value) {
  return wordUint(value ? 1n : 0n);
}

export function wordBytes32(value) {
  return pad(value, { size: 32 });
}

export function hashWords(words) {
  return keccak256(concat(words));
}

export function deriveConfigId(namespaceHash, schemaVersion, chainId, subjectKey, revision) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "uint32" },
        { type: "uint256" },
        { type: "bytes32" },
        { type: "uint32" },
      ],
      [namespaceHash, schemaVersion, chainId, subjectKey, revision],
    ),
  );
}

export function deriveAssetVersionId(schemaVersion, economicAssetIdHash, chainId, assetToken, versionNo) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint32" },
        { type: "bytes32" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint32" },
      ],
      [schemaVersion, economicAssetIdHash, chainId, assetToken, versionNo],
    ),
  );
}

export function hashDeploymentVersion(version) {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [Namespace.DEPLOYMENT_VERSION, keccakUtf8(version)],
    ),
  );
}

export function tokenSubject(token) {
  return wordAddress(token);
}

export function assetClassSubject(assetClass) {
  return wordUint(assetClass);
}

export function matchedScopeHash(feePolicyEpoch, scopeType, scopeKeyHash) {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint64" }, { type: "uint8" }, { type: "bytes32" }],
      [Typehash.FEE_SCOPE, feePolicyEpoch, scopeType, scopeKeyHash],
    ),
  );
}

export function hashAdapterCapabilities(capabilities) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "uint8" },
        { type: "uint8" },
        { type: "uint8" },
        { type: "uint256" },
      ],
      [
        Typehash.ADAPTER_CAPABILITIES,
        capabilities.tokenStandard,
        capabilities.restrictionMode,
        capabilities.precheckMethod,
        capabilities.transferLegMask,
      ],
    ),
  );
}

export function hashAdapterConfig(config) {
  return hashWords([
    Typehash.ADAPTER_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.adapterConfigId),
    wordUint(config.revision),
    wordUint(config.chainId),
    wordAddress(config.adapter),
    wordBytes32(config.interfaceVersion),
    wordBytes32(config.codeHash),
    wordBytes32(hashAdapterCapabilities(config.capabilities)),
    wordBytes32(config.capabilityHash),
    wordBytes32(config.providerHash),
    wordBytes32(config.replacesId),
  ]);
}

export function hashPrincipalCalculatorConfig(config) {
  return hashWords([
    Typehash.PRINCIPAL_CALCULATOR_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.calculatorConfigId),
    wordUint(config.revision),
    wordUint(config.chainId),
    wordUint(config.assetClass),
    wordAddress(config.calculator),
    wordBytes32(config.interfaceVersion),
    wordBytes32(config.codeHash),
    wordBytes32(config.replacesId),
  ]);
}

export function hashSettlementTokenConfig(config) {
  return hashWords([
    Typehash.SETTLEMENT_TOKEN_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.configId),
    wordUint(config.revision),
    wordUint(config.chainId),
    wordAddress(config.settlementToken),
    wordUint(config.tokenDeploymentKind),
    wordUint(config.settlementTokenDecimals),
    wordBytes32(config.tokenCodeHash),
    wordAddress(config.implementation),
    wordBytes32(config.implementationCodeHash),
    wordBytes32(config.adapterConfigId),
    wordBytes32(config.adapterConfigHash),
    wordUint(config.permitCapability),
    wordBytes32(config.replacesConfigId),
  ]);
}

export function hashAssetVersionConfig(config) {
  return hashWords([
    Typehash.ASSET_VERSION_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.economicAssetIdHash),
    wordBytes32(config.assetVersionId),
    wordUint(config.chainId),
    wordUint(config.versionNo),
    wordAddress(config.assetToken),
    wordUint(config.tokenStandard),
    wordUint(config.tokenDeploymentKind),
    wordUint(config.assetDecimals),
    wordBytes32(config.tokenCodeHash),
    wordAddress(config.implementation),
    wordBytes32(config.implementationCodeHash),
    wordUint(config.assetPermitCapability),
    wordUint(config.assetClass),
    wordBytes32(config.principalCalculatorConfigId),
    wordBytes32(config.principalCalculatorConfigHash),
    wordBytes32(config.adapterConfigId),
    wordBytes32(config.adapterConfigHash),
    wordUint(config.restrictionMode),
    wordAddress(config.settlementToken),
    wordBytes32(config.settlementTokenConfigId),
    wordBytes32(config.settlementTokenConfigHash),
    wordAddress(config.dvpContract),
    wordBytes32(config.deploymentVersionHash),
    wordBytes32(config.replacesAssetVersionId),
  ]);
}

export function hashMarketRuleConfig(config) {
  return hashWords([
    Typehash.MARKET_RULE_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.marketRuleConfigId),
    wordUint(config.revision),
    wordUint(config.chainId),
    wordBytes32(config.assetVersionId),
    wordAddress(config.settlementToken),
    wordBytes32(config.settlementTokenConfigId),
    wordBytes32(config.settlementTokenConfigHash),
    wordUint(config.minCashPrincipal),
    wordUint(config.minExecutableQuantity),
    wordUint(config.quantityStep),
    wordUint(config.priceTick),
    wordUint(config.priceDecimals),
    wordUint(config.quantityDecimals),
    wordUint(config.quoteValidFrom),
    wordUint(config.quoteValidUntil),
    wordUint(config.settlementValidUntil),
    wordBytes32(config.replacesConfigId),
  ]);
}

export function hashFeePolicyEpochConfig(config) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "uint32" },
        { type: "uint64" },
        { type: "uint256" },
        { type: "uint64" },
        { type: "uint64" },
        { type: "uint64" },
      ],
      [
        Typehash.FEE_POLICY_EPOCH_CONFIG,
        config.schemaVersion,
        config.feePolicyEpoch,
        config.chainId,
        config.quoteValidFrom,
        config.quoteValidUntil,
        config.settlementValidUntil,
      ],
    ),
  );
}

export function hashFeeConstraint(config) {
  return hashWords([
    Typehash.FEE_CONSTRAINT,
    wordUint(config.feePolicyEpoch),
    wordBytes32(config.feeVersionId),
    wordBytes32(config.matchedScopeHash),
    wordUint(config.investorRateBps),
    wordBool(config.investorHasCap),
    wordUint(config.investorCapAmount),
    wordUint(config.makerRateBps),
    wordBool(config.makerHasCap),
    wordUint(config.makerCapAmount),
    wordUint(config.roundingMode),
    wordAddress(config.settlementToken),
    wordBytes32(config.settlementTokenConfigId),
    wordBytes32(config.settlementTokenConfigHash),
    wordAddress(config.collector),
    wordUint(config.validFrom),
    wordUint(config.validUntil),
  ]);
}

export function hashFeeConfig(config) {
  return hashWords([
    Typehash.FEE_CONFIG,
    wordUint(config.schemaVersion),
    wordBytes32(config.feeVersionId),
    wordUint(config.revision),
    wordUint(config.chainId),
    wordUint(config.feePolicyEpoch),
    wordUint(config.scopeType),
    wordBytes32(config.scopeKeyHash),
    wordBytes32(config.matchedScopeHash),
    wordUint(config.investorRateBps),
    wordBool(config.investorHasCap),
    wordUint(config.investorCapAmount),
    wordUint(config.makerRateBps),
    wordBool(config.makerHasCap),
    wordUint(config.makerCapAmount),
    wordUint(config.roundingMode),
    wordAddress(config.settlementToken),
    wordBytes32(config.settlementTokenConfigId),
    wordBytes32(config.settlementTokenConfigHash),
    wordAddress(config.collector),
    wordUint(config.validFrom),
    wordUint(config.validUntil),
    wordBytes32(config.feeConstraintHash),
    wordBytes32(config.replacesFeeVersionId),
  ]);
}

export const PINNED_INTERFACE_VERSIONS = Object.freeze({
  ASSET_ADAPTER_V1: "0xcf9367d3ea4eeeafb16085ddb317f5531635ff94317ed7bf61d9dbb13cc3b152",
  PRINCIPAL_CALCULATOR_V1: "0x79b97198c84fbb044cdda584716b22b5f0da3a199307ca0dea63b2e03e72f10f",
});

export function assertPinnedHashes() {
  if (InterfaceVersion.ASSET_ADAPTER_V1 !== PINNED_INTERFACE_VERSIONS.ASSET_ADAPTER_V1) {
    throw new Error("ASSET_ADAPTER_V1 hash drift");
  }
  if (InterfaceVersion.PRINCIPAL_CALCULATOR_V1 !== PINNED_INTERFACE_VERSIONS.PRINCIPAL_CALCULATOR_V1) {
    throw new Error("PRINCIPAL_CALCULATOR_V1 hash drift");
  }
}
