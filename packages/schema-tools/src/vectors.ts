import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  encodeAbiParameters,
  hashDomain,
  hashStruct,
  hashTypedData,
  keccak256,
  pad,
  stringToHex,
  toHex,
} from "viem";

import { encodeEip712TypeString, mergeEip712Types, type Eip712Types } from "./eip712.js";
import { buildSchemaModel } from "./model.js";
import { VECTOR_PATHS, schemaRepoPath } from "./paths.js";

function typedVector(primaryType: string, vector: object) {
  return {
    schemaVersion: 1,
    status: "candidate",
    primaryType,
    ...vector,
  };
}

export type VectorMap = Record<string, unknown>;

function word(value: number | bigint): `0x${string}` {
  return pad(toHex(BigInt(value)), { size: 32 });
}

function address(value: number | bigint | string): `0x${string}` {
  return `0x${BigInt(value).toString(16).padStart(40, "0")}`;
}

function hashText(value: string): `0x${string}` {
  return keccak256(stringToHex(value));
}

function json(value: unknown): string {
  return `${JSON.stringify(value, (_key, nested) => typeof nested === "bigint" ? nested.toString() : nested, 2)}\n`;
}

function changedValue(types: Eip712Types, solidityType: string, value: any): any {
  if (solidityType.endsWith("[]")) {
    const itemType = solidityType.slice(0, -2);
    const changed = structuredClone(value);
    changed[0] = changedValue(types, itemType, changed[0]);
    return changed;
  }
  if (types[solidityType] !== undefined) {
    const changed = structuredClone(value);
    const first = types[solidityType]![0]!;
    changed[first.name] = changedValue(types, first.type, changed[first.name]);
    return changed;
  }
  if (solidityType === "address") return address(BigInt(value) + 1n);
  if (solidityType === "bool") return !value;
  if (solidityType === "string") return `${value}x`;
  if (solidityType === "bytes") return value === "0x" ? "0x01" : `${value}00`;
  if (solidityType.startsWith("bytes")) {
    const size = Number(solidityType.slice(5));
    return pad(toHex(BigInt(value) ^ 1n), { size });
  }
  if (solidityType.startsWith("uint")) return BigInt(value) + 1n;
  throw new Error(`No mutation strategy for ${solidityType}.`);
}

function mutations(
  types: Eip712Types,
  primaryType: string,
  input: Record<string, any>,
  hash: (value: any) => string,
) {
  return Object.fromEntries(
    (types[primaryType] ?? []).map((field) => {
      const mutated = structuredClone(input);
      mutated[field.name] = changedValue(types, field.type, mutated[field.name]);
      return [field.name, hash(mutated)];
    }),
  );
}

function structVector(types: Eip712Types, primaryType: string, input: Record<string, any>) {
  const hash = (value: any) => hashStruct({ data: value, primaryType, types });
  const canonicalType = encodeEip712TypeString(primaryType, types);
  return {
    typeString: canonicalType,
    typeHash: hashText(canonicalType),
    input,
    hash: hash(input),
    mutations: mutations(types, primaryType, input, hash),
  };
}

function genericId(namespace: string, chainId: bigint, subject: `0x${string}`, revision = 1) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "uint32" },
        { type: "uint256" },
        { type: "bytes32" },
        { type: "uint32" },
      ],
      [hashText(namespace), 1, chainId, subject, revision],
    ),
  );
}

export function buildBootstrapVectors(repositoryRoot: string): VectorMap {
  const model = buildSchemaModel(repositoryRoot);
  const types = mergeEip712Types([
    ...Object.values(model.typehashes).map((entry) => entry.typeString),
    model.feeScope.typeString,
  ]);
  const scopeMembers = [...(model.enums.ScopeType ?? [])]
    .filter((member) => member.name !== "NONE")
    .sort((left, right) => right.value - left.value);
  const scopeTypeByName = Object.fromEntries(
    (model.enums.ScopeType ?? []).map((member) => [member.name, member.value]),
  );
  if (scopeTypeByName.ASSET_VERSION === undefined) {
    throw new Error("ScopeType.ASSET_VERSION is missing from the HTPTypes AST");
  }
  const namespace = (name: keyof typeof model.configIdNamespaces) => {
    const value = model.configIdNamespaces[name];
    if (!value) throw new Error(`Missing ConfigId namespace ${name}`);
    return value.preimage;
  };

  const domain = {
    name: model.domain.name,
    version: "1",
    chainId: 31_337n,
    verifyingContract: address(0xd001),
  };
  const deploymentVersion = "1.2.3";
  const deploymentVersionDomain = hashText(model.deploymentVersionDomain.preimage);
  const deploymentVersionHash = keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [deploymentVersionDomain, hashText(deploymentVersion)],
    ),
  );
  const domainSeparator = hashDomain({ domain, types });
  const domainTypeString = encodeEip712TypeString("EIP712Domain", types);
  const domainVector = {
    deploymentVersion,
    deploymentVersionDomain,
    deploymentVersionHash,
    typeString: domainTypeString,
    typeHash: hashText(domainTypeString),
    input: domain,
    separator: domainSeparator,
    mutations: {
      name: hashDomain({ domain: { ...domain, name: `${domain.name}x` }, types }),
      version: hashDomain({ domain: { ...domain, version: "2" }, types }),
      chainId: hashDomain({ domain: { ...domain, chainId: domain.chainId + 1n }, types }),
      verifyingContract: hashDomain({
        domain: { ...domain, verifyingContract: address(BigInt(domain.verifyingContract) + 1n) },
        types,
      }),
    },
  };

  const fundPriceTerms = {
    navPerUnit: 1_140_000n,
    navDate: 20_260_810,
    navSourceHash: word(0x201),
  };
  const priceData = encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint32" }, { type: "bytes32" }],
    [fundPriceTerms.navPerUnit, fundPriceTerms.navDate, fundPriceTerms.navSourceHash],
  );
  const priceTermsHash = hashStruct({ data: fundPriceTerms, primaryType: "FundPriceTerms", types });
  const assetVersionId = keccak256(
    encodeAbiParameters(
      [
        { type: "uint32" },
        { type: "bytes32" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint32" },
      ],
      [1, word(0x101), domain.chainId, address(0xa001), 1],
    ),
  );
  const feeScope = {
    feePolicyEpoch: 7n,
    scopeType: scopeTypeByName.ASSET_VERSION,
    scopeKeyHash: assetVersionId,
  };
  const matchedScopeHash = hashStruct({ data: feeScope, primaryType: "FeeScope", types });
  const settlementToken = address(0xc001);
  const settlementTokenConfigId = genericId(
    namespace("SETTLEMENT_TOKEN_NAMESPACE"),
    domain.chainId,
    word(BigInt(settlementToken)),
  );
  const settlementTokenConfigHash = word(0x301);
  const marketRuleConfigId = genericId(
    namespace("MARKET_RULE_NAMESPACE"),
    domain.chainId,
    assetVersionId,
  );
  const marketRuleConfig = {
    schemaVersion: 1,
    marketRuleConfigId,
    revision: 1,
    chainId: domain.chainId,
    assetVersionId,
    settlementToken,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    minCashPrincipal: 1n,
    minExecutableQuantity: 1_000_000_000_000_000_000n,
    quantityStep: 1_000_000_000_000_000_000n,
    priceTick: 10_000n,
    priceDecimals: 2,
    quantityDecimals: 18,
    quoteValidFrom: 1_780_000_000n,
    quoteValidUntil: 1_785_000_000n,
    settlementValidUntil: 1_790_000_000n,
    replacesConfigId: word(0),
  };
  const marketRuleConfigHash = hashStruct({
    data: marketRuleConfig,
    primaryType: "MarketRuleConfig",
    types,
  });
  const feeVersionId = genericId(namespace("FEE_NAMESPACE"), domain.chainId, matchedScopeHash);
  const feeConstraint = {
    feePolicyEpoch: 7n,
    feeVersionId,
    matchedScopeHash,
    investorRateBps: 25,
    investorHasCap: true,
    investorCapAmount: 50_000n,
    makerRateBps: 15,
    makerHasCap: false,
    makerCapAmount: 0n,
    roundingMode: 1,
    settlementToken,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    collector: address(0xc011),
    validFrom: 1_780_000_000n,
    validUntil: 1_790_000_000n,
  };
  const feeConstraintHash = hashStruct({ data: feeConstraint, primaryType: "FeeConstraint", types });
  const principalCalculatorConfigId = word(0x401);
  const principalCalculatorConfigHash = word(0x402);
  const boundAdapterConfigId = word(0x403);
  const adapterConfigHash = word(0x404);
  const tradeIdHash = word(0x501);

  const firmQuote = {
    schemaVersion: 1,
    rfqIdHash: word(0x601),
    quoteIdHash: word(0x602),
    quoteVersion: 1,
    quotingMaker: address(0xb001),
    requester: address(0xb002),
    requesterType: 1,
    assetVersionId,
    requesterSide: 1,
    assetToken: address(0xa001),
    settlementToken,
    assetClass: 2,
    priceTermsHash,
    priceData,
    principalCalculatorConfigId,
    principalCalculatorConfigHash,
    adapterConfigId: boundAdapterConfigId,
    adapterConfigHash,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    marketRuleConfigId,
    marketRuleConfigHash,
    minExecutableQuantity: 1_000_000_000_000_000_000n,
    maxExecutableQuantity: 100_000_000_000_000_000_000n,
    stepQuantity: 1_000_000_000_000_000_000n,
    feePolicyEpoch: 7n,
    feeVersionId,
    matchedScopeHash,
    feeConstraintHash,
    quoteNonce: 41n,
    expiresAt: 1_785_000_000n,
  };
  const quoteStructHash = hashStruct({ data: firmQuote, primaryType: "FirmQuote", types });
  const quoteDigest = hashTypedData({ domain, primaryType: "FirmQuote", types, message: firmQuote });
  const firmQuoteTypeString = encodeEip712TypeString("FirmQuote", types);
  const firmQuoteVector = {
    typeString: firmQuoteTypeString,
    typeHash: hashText(firmQuoteTypeString),
    input: firmQuote,
    structHash: quoteStructHash,
    domainSeparator,
    digest: quoteDigest,
    domainMutations: {
      major: hashTypedData({
        domain: { ...domain, version: "2" },
        primaryType: "FirmQuote",
        types,
        message: firmQuote,
      }),
      chainId: hashTypedData({
        domain: { ...domain, chainId: domain.chainId + 1n },
        primaryType: "FirmQuote",
        types,
        message: firmQuote,
      }),
      verifyingContract: hashTypedData({
        domain: { ...domain, verifyingContract: address(BigInt(domain.verifyingContract) + 1n) },
        primaryType: "FirmQuote",
        types,
        message: firmQuote,
      }),
    },
    mutations: mutations(types, "FirmQuote", firmQuote, (value) =>
      hashTypedData({ domain, primaryType: "FirmQuote", types, message: value })
    ),
  };

  const snapshot = {
    schemaVersion: 1,
    tradeIdHash,
    quoteHash: quoteDigest,
    chainId: domain.chainId,
    dvpContract: domain.verifyingContract,
    requester: firmQuote.requester,
    requesterType: firmQuote.requesterType,
    quotingMaker: firmQuote.quotingMaker,
    requesterSide: firmQuote.requesterSide,
    buyer: firmQuote.requester,
    seller: firmQuote.quotingMaker,
    assetVersionId,
    assetToken: firmQuote.assetToken,
    settlementToken,
    assetDecimals: 18,
    settlementTokenDecimals: 6,
    executedQuantity: 10_000_000_000_000_000_000n,
    assetClass: 2,
    priceTermsHash,
    priceData,
    principalCalculatorConfigId,
    principalCalculatorConfigHash,
    adapterConfigId: boundAdapterConfigId,
    adapterConfigHash,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    marketRuleConfigId,
    marketRuleConfigHash,
    cashPrincipal: 11_400_000n,
    buyerFee: 28_500n,
    sellerFee: 17_100n,
    buyerDebit: 11_428_500n,
    sellerCredit: 11_382_900n,
    collectorCredit: 45_600n,
    collector: feeConstraint.collector,
    feePolicyEpoch: 7n,
    feeVersionId,
    matchedScopeHash,
    feeConstraintHash,
    roundingMode: 1,
    makerQuoteNonce: firmQuote.quoteNonce,
    requesterTradeNonce: 52n,
    quoteExpiresAt: firmQuote.expiresAt,
    tradeDeadline: 1_784_900_000n,
    createdAt: 1_780_000_100n,
  };
  const snapshotVector = {
    ...structVector(types, "TradeTermsSnapshot", snapshot),
    eip712DigestIfMisused: hashTypedData({
      domain,
      primaryType: "TradeTermsSnapshot",
      types,
      message: snapshot,
    }),
  };

  const tradeIntent = {
    schemaVersion: 1,
    tradeIdHash,
    quoteHash: quoteDigest,
    snapshotHash: snapshotVector.hash,
    requester: snapshot.requester,
    requesterType: snapshot.requesterType,
    quotingMaker: snapshot.quotingMaker,
    assetVersionId,
    requesterSide: snapshot.requesterSide,
    buyer: snapshot.buyer,
    seller: snapshot.seller,
    assetToken: snapshot.assetToken,
    settlementToken,
    executedQuantity: snapshot.executedQuantity,
    assetClass: snapshot.assetClass,
    priceTermsHash,
    priceData,
    principalCalculatorConfigId,
    principalCalculatorConfigHash,
    adapterConfigId: boundAdapterConfigId,
    adapterConfigHash,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    marketRuleConfigId,
    marketRuleConfigHash,
    cashPrincipal: snapshot.cashPrincipal,
    buyerFee: snapshot.buyerFee,
    sellerFee: snapshot.sellerFee,
    buyerDebit: snapshot.buyerDebit,
    sellerCredit: snapshot.sellerCredit,
    collectorCredit: snapshot.collectorCredit,
    collector: snapshot.collector,
    feePolicyEpoch: 7n,
    feeVersionId,
    matchedScopeHash,
    feeConstraintHash,
    roundingMode: 1,
    tradeNonce: snapshot.requesterTradeNonce,
    deadline: snapshot.tradeDeadline,
  };
  const tradeIntentTypeString = encodeEip712TypeString("TradeIntent", types);
  const tradeIntentVector: Record<string, any> = {
    typeString: tradeIntentTypeString,
    typeHash: hashText(tradeIntentTypeString),
    input: tradeIntent,
    structHash: hashStruct({ data: tradeIntent, primaryType: "TradeIntent", types }),
    domainSeparator,
    digest: hashTypedData({ domain, primaryType: "TradeIntent", types, message: tradeIntent }),
    mutations: mutations(types, "TradeIntent", tradeIntent, (value) =>
      hashTypedData({ domain, primaryType: "TradeIntent", types, message: value })
    ),
  };
  const noRoundingTradeIntent = structuredClone(tradeIntent);
  noRoundingTradeIntent.roundingMode = 0;
  tradeIntentVector.mutations.roundingMode = hashTypedData({
    domain,
    primaryType: "TradeIntent",
    types,
    message: noRoundingTradeIntent,
  });

  const nonceCancellation = {
    signer: firmQuote.quotingMaker,
    nonceType: 1,
    nonce: firmQuote.quoteNonce,
    deadline: 1_784_000_000n,
  };
  const nonceTypeString = encodeEip712TypeString("NonceCancellation", types);
  const nonceVector = {
    typeString: nonceTypeString,
    typeHash: hashText(nonceTypeString),
    input: nonceCancellation,
    structHash: hashStruct({ data: nonceCancellation, primaryType: "NonceCancellation", types }),
    domainSeparator,
    digest: hashTypedData({
      domain,
      primaryType: "NonceCancellation",
      types,
      message: nonceCancellation,
    }),
    domainMutations: {
      major: hashTypedData({
        domain: { ...domain, version: "2" },
        primaryType: "NonceCancellation",
        types,
        message: nonceCancellation,
      }),
      chainId: hashTypedData({
        domain: { ...domain, chainId: domain.chainId + 1n },
        primaryType: "NonceCancellation",
        types,
        message: nonceCancellation,
      }),
      verifyingContract: hashTypedData({
        domain: { ...domain, verifyingContract: address(BigInt(domain.verifyingContract) + 1n) },
        primaryType: "NonceCancellation",
        types,
        message: nonceCancellation,
      }),
    },
    mutations: mutations(types, "NonceCancellation", nonceCancellation, (value) =>
      hashTypedData({ domain, primaryType: "NonceCancellation", types, message: value })
    ),
  };

  const stockPriceTerms = {
    unitPrice: 2_345_678n,
    priceAsOf: 1_780_000_000n,
    referenceMarketHash: word(0x701),
    priceSourceHash: word(0x702),
  };
  const bondPriceTerms = {
    cleanPricePerUnit: 980_000n,
    accruedInterestPerUnit: 12_500n,
    settlementDate: 20_260_812,
    sourceHash: word(0x703),
  };
  const adapterCapabilities = {
    tokenStandard: 1,
    restrictionMode: 2,
    precheckMethod: 3,
    transferLegMask: 14n,
  };
  const capabilityHash = hashStruct({
    data: adapterCapabilities,
    primaryType: "AdapterCapabilities",
    types,
  });
  const providerSet = {
    providers: [
      { provider: address(0xe001), selector: "0x01020304", codeHash: word(0x801) },
      { provider: address(0xe002), selector: "0x05060708", codeHash: word(0x802) },
    ],
  };
  const providerHash = hashStruct({ data: providerSet, primaryType: "RestrictionProviderSet", types });
  const providerSetVector: Record<string, any> = structVector(types, "RestrictionProviderSet", providerSet);
  const providerMutationHash = (field: "provider" | "selector" | "codeHash", solidityType: string) => {
    const mutated = structuredClone(providerSet);
    mutated.providers[0]![field] = changedValue(types, solidityType, mutated.providers[0]![field]);
    return hashStruct({ data: mutated, primaryType: "RestrictionProviderSet", types });
  };
  providerSetVector.mutations = {
    provider: providerMutationHash("provider", "address"),
    selector: providerMutationHash("selector", "bytes4"),
    codeHash: providerMutationHash("codeHash", "bytes32"),
  };
  const adapterConfigId = genericId(namespace("ADAPTER_NAMESPACE"), domain.chainId, capabilityHash);
  const adapterConfig = {
    schemaVersion: 1,
    adapterConfigId,
    revision: 1,
    chainId: domain.chainId,
    adapter: address(0xe101),
    interfaceVersion: word(0x803),
    codeHash: word(0x804),
    capabilities: adapterCapabilities,
    capabilityHash,
    providerHash,
    replacesId: word(0),
  };
  const principalConfigId = genericId(namespace("PRINCIPAL_CALCULATOR_NAMESPACE"), domain.chainId, word(2));
  const principalConfig = {
    schemaVersion: 1,
    calculatorConfigId: principalConfigId,
    revision: 1,
    chainId: domain.chainId,
    assetClass: 2,
    calculator: address(0xf001),
    interfaceVersion: model.interfaceVersions.PRINCIPAL_CALCULATOR_V1!.value,
    codeHash: word(0x902),
    replacesId: word(0),
  };
  const settlementConfig = {
    schemaVersion: 1,
    configId: settlementTokenConfigId,
    revision: 1,
    chainId: domain.chainId,
    settlementToken,
    tokenDeploymentKind: 2,
    settlementTokenDecimals: 6,
    tokenCodeHash: word(0xa01),
    implementation: address(0xc002),
    implementationCodeHash: word(0xa02),
    adapterConfigId,
    adapterConfigHash: word(0xa03),
    permitCapability: 2,
    replacesConfigId: word(0),
  };
  const assetConfig = {
    schemaVersion: 1,
    economicAssetIdHash: word(0x101),
    assetVersionId,
    chainId: domain.chainId,
    versionNo: 1,
    assetToken: address(0xa001),
    tokenStandard: 1,
    tokenDeploymentKind: 2,
    assetDecimals: 18,
    tokenCodeHash: word(0xb01),
    implementation: address(0xa002),
    implementationCodeHash: word(0xb02),
    assetPermitCapability: 2,
    assetClass: 2,
    principalCalculatorConfigId: principalConfigId,
    principalCalculatorConfigHash: word(0xb03),
    adapterConfigId,
    adapterConfigHash: word(0xb04),
    restrictionMode: 2,
    settlementToken,
    settlementTokenConfigId,
    settlementTokenConfigHash: word(0xb05),
    dvpContract: domain.verifyingContract,
    deploymentVersionHash,
    replacesAssetVersionId: word(0),
  };
  const epochConfig = {
    schemaVersion: 1,
    feePolicyEpoch: 7n,
    chainId: domain.chainId,
    quoteValidFrom: 1_780_000_000n,
    quoteValidUntil: 1_785_000_000n,
    settlementValidUntil: 1_790_000_000n,
  };
  const feeConfig = {
    schemaVersion: 1,
    feeVersionId,
    revision: 1,
    chainId: domain.chainId,
    feePolicyEpoch: feeConstraint.feePolicyEpoch,
    scopeType: feeScope.scopeType,
    scopeKeyHash: feeScope.scopeKeyHash,
    matchedScopeHash,
    investorRateBps: feeConstraint.investorRateBps,
    investorHasCap: feeConstraint.investorHasCap,
    investorCapAmount: feeConstraint.investorCapAmount,
    makerRateBps: feeConstraint.makerRateBps,
    makerHasCap: feeConstraint.makerHasCap,
    makerCapAmount: feeConstraint.makerCapAmount,
    roundingMode: feeConstraint.roundingMode,
    settlementToken,
    settlementTokenConfigId,
    settlementTokenConfigHash,
    collector: feeConstraint.collector,
    validFrom: feeConstraint.validFrom,
    validUntil: feeConstraint.validUntil,
    feeConstraintHash,
    replacesFeeVersionId: word(0),
  };
  const feeScopes = scopeMembers.map((member) => {
    const scopeKeyHash = member.name === "ASSET_VERSION"
      ? assetVersionId
      : member.name === "INSTRUMENT"
      ? assetConfig.economicAssetIdHash
      : member.name === "ASSET_CLASS"
      ? word(assetConfig.assetClass)
      : member.name === "CHAIN"
      ? word(domain.chainId)
      : word(0);
    const scopeType = member.value;
    return {
      scopeType,
      scopeKeyHash,
      matchedScopeHash: hashStruct({
        data: { feePolicyEpoch: 7n, scopeType, scopeKeyHash },
        primaryType: "FeeScope",
        types,
      }),
    };
  });

  return {
    [schemaRepoPath(VECTOR_PATHS.domain)]: typedVector("EIP712Domain", domainVector),
    [schemaRepoPath(VECTOR_PATHS.firmQuote)]: typedVector("FirmQuote", firmQuoteVector),
    [schemaRepoPath(VECTOR_PATHS.tradeIntent)]: typedVector("TradeIntent", tradeIntentVector),
    [schemaRepoPath(VECTOR_PATHS.nonceCancellation)]: typedVector("NonceCancellation", nonceVector),
    [schemaRepoPath(VECTOR_PATHS.tradeTermsSnapshot)]: typedVector("TradeTermsSnapshot", snapshotVector),
    [schemaRepoPath(VECTOR_PATHS.priceterms)]: {
      stock: structVector(types, "StockPriceTerms", stockPriceTerms),
      fund: structVector(types, "FundPriceTerms", fundPriceTerms),
      bond: structVector(types, "BondPriceTerms", bondPriceTerms),
    },
    [schemaRepoPath(VECTOR_PATHS.configIds)]: {
      input: {
        schemaVersion: 1,
        chainId: domain.chainId,
        assetToken: assetConfig.assetToken,
        economicAssetIdHash: assetConfig.economicAssetIdHash,
        versionNo: assetConfig.versionNo,
      },
      namespaces: {
        fee: hashText(namespace("FEE_NAMESPACE")),
        settlementToken: hashText(namespace("SETTLEMENT_TOKEN_NAMESPACE")),
        adapter: hashText(namespace("ADAPTER_NAMESPACE")),
        principalCalculator: hashText(namespace("PRINCIPAL_CALCULATOR_NAMESPACE")),
        marketRule: hashText(namespace("MARKET_RULE_NAMESPACE")),
      },
      ids: {
        assetVersion: assetVersionId,
        fee: genericId(namespace("FEE_NAMESPACE"), domain.chainId, matchedScopeHash),
        settlementToken: genericId(
          namespace("SETTLEMENT_TOKEN_NAMESPACE"),
          domain.chainId,
          word(BigInt(settlementToken)),
        ),
        adapter: genericId(namespace("ADAPTER_NAMESPACE"), domain.chainId, capabilityHash),
        principalCalculator: genericId(namespace("PRINCIPAL_CALCULATOR_NAMESPACE"), domain.chainId, word(2)),
        marketRule: marketRuleConfigId,
      },
    },
    [schemaRepoPath(VECTOR_PATHS.feeScope)]: {
      typeString: encodeEip712TypeString("FeeScope", types),
      typeHash: hashText(encodeEip712TypeString("FeeScope", types)),
      priority: scopeMembers.map((member) => member.value),
      feePolicyEpoch: 7n,
      scopes: feeScopes,
    },
    [schemaRepoPath(VECTOR_PATHS.assetVersion)]: structVector(types, "AssetVersionConfig", assetConfig),
    [schemaRepoPath(VECTOR_PATHS.settlementToken)]: structVector(
      types,
      "SettlementTokenConfig",
      settlementConfig,
    ),
    [schemaRepoPath(VECTOR_PATHS.adapter)]: {
      capabilities: structVector(types, "AdapterCapabilities", adapterCapabilities),
      providerSet: providerSetVector,
      config: structVector(types, "AdapterConfig", adapterConfig),
    },
    [schemaRepoPath(VECTOR_PATHS.principalCalculator)]: structVector(
      types,
      "PrincipalCalculatorConfig",
      principalConfig,
    ),
    [schemaRepoPath(VECTOR_PATHS.marketRule)]: structVector(types, "MarketRuleConfig", marketRuleConfig),
    [schemaRepoPath(VECTOR_PATHS.fee)]: {
      policyEpoch: structVector(types, "FeePolicyEpochConfig", epochConfig),
      constraint: structVector(types, "FeeConstraint", feeConstraint),
      config: structVector(types, "FeeConfig", feeConfig),
    },
  };
}

export function writeOrCheckVectors(repositoryRoot: string, write: boolean): void {
  const outputs = buildBootstrapVectors(repositoryRoot);
  let drift = false;
  for (const [relativePath, output] of Object.entries(outputs)) {
    const path = resolve(repositoryRoot, relativePath);
    const expected = json(output);
    if (write) {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, expected);
    } else if (!existsSync(path) || readFileSync(path, "utf8") !== expected) {
      process.stderr.write(`vector drift detected: ${relativePath}\n`);
      drift = true;
    }
  }
  if (drift) throw new Error("vector drift detected");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const repositoryRoot = resolve(import.meta.dirname, "../../..");
  writeOrCheckVectors(repositoryRoot, process.argv.includes("--write"));
}
