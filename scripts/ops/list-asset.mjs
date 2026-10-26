#!/usr/bin/env node
// @ts-nocheck
// ponytail: Asset revisions beyond the initial listing need a separate migration workflow.
/**
 * 使用平台报告里已经激活的 Adapter / Calculator / SettlementToken 上架一个资产。
 * 只发送 AssetVersion 和 MarketRule 的登记/激活交易；不会部署、登记或激活 Adapter。
 */

import { existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  keccak256,
  parseAbi,
  stringToHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  ACCESS_ABI,
  ANVIL_KEYS,
  DVP_VIEW_ABI,
  ONDO_GM_IDENTIFIER,
  ROLE_ID,
  acquireLock,
  asPrivateKey,
  assertMainnetOndoEvidence,
  assertRpcUrl,
  createChainClients,
  detectTokenDeployment,
  deployPlatform,
  ensureBuild,
  loadArtifact,
  loadState,
  printStatus,
  readJson,
  readRestrictedBinding,
  requireAddress,
  runSteps,
  withAnvil,
  writeJsonAtomic,
} from "./deploy-platform.mjs";
import {
  Enum,
  Namespace,
  SCHEMA_VERSION,
  ZERO_BYTES32,
  deriveAssetVersionId,
  deriveConfigId,
  hashAssetVersionConfig,
  hashDeploymentVersion,
  hashMarketRuleConfig,
} from "./lib/htp-hash.mjs";
import { loadTmpEnv, safeErrorMessage } from "./lib/env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const tmpOutRoot = join(repoRoot, "tmp", "out");
const UINT256_MAX = (1n << 256n) - 1n;
const HSK_CHAIN_IDS = new Set([133, 177]);
const ERC20_META_ABI = parseAbi(["function decimals() view returns (uint8)"]);
const FAMILY_FIELDS = Object.freeze([
  "tokenCodeHash",
  "complianceView",
  "complianceViewCodeHash",
  "compliance",
  "complianceCodeHash",
  "gmIdentifier",
  "pauseManager",
  "pauseManagerCodeHash",
  "blocklist",
  "blocklistCodeHash",
  "sanctionsList",
  "sanctionsListCodeHash",
]);

function usage() {
  return `node scripts/ops/list-asset.mjs --config <path> [options]

选项：
  --config <path>     资产与市场规则 JSON
  --report <path>     平台精简报告，默认 tmp/out/platform-summary.json
  --rpc <url>         RPC，也可用 HTP_RPC_URL
  --state <path>      状态文件，默认 tmp/out/asset-state.<chainId>.<token>.json
  --out <path>        资产汇总，默认 tmp/out/assets.<chainId>.json
  --status            只打印进度，不发交易
  --self-test         在 127.0.0.1 拉起 Anvil 验证同族多资产上架
  --help              显示帮助`;
}

function parseArgs(argv) {
  const allowed = new Set(["config", "report", "rpc", "state", "out", "status", "self-test", "help"]);
  const flags = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) throw new Error(`未知参数: ${token}`);
    const key = token.slice(2);
    if (!allowed.has(key)) throw new Error(`未知选项: --${key}\n\n${usage()}`);
    const next = argv[index + 1];
    if (next === undefined || next.startsWith("--")) flags[key] = true;
    else {
      flags[key] = next;
      index += 1;
    }
  }
  return flags;
}

function object(value, label, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} 必须是对象`);
  for (const key of Object.keys(value)) {
    if (!keys.includes(key)) throw new Error(`${label} 包含未知字段: ${key}`);
  }
  return value;
}

function bytes32(value, label) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/u.test(value) || /^0x0{64}$/u.test(value)) {
    throw new Error(`${label} 必须是非零 bytes32`);
  }
  return value.toLowerCase();
}

function enumValue(values, value, label) {
  const name = String(value ?? "").toUpperCase();
  if (!(name in values) || name === "NONE") throw new Error(`${label} 不受支持: ${String(value)}`);
  return values[name];
}

function uint(value, label, { allowZero = false } = {}) {
  if (typeof value !== "string" || !/^(0|[1-9]\d*)$/u.test(value)) {
    throw new Error(`${label} 必须是不含前导零的十进制字符串`);
  }
  const parsed = BigInt(value);
  if (parsed > UINT256_MAX || (!allowZero && parsed === 0n)) throw new Error(`${label} 超出允许范围`);
  return parsed;
}

function optionalUnix(value, label) {
  if (value === null || value === undefined) return null;
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${label} 必须是非负安全整数或 null`);
  return value;
}

export function normalizeAssetConfig(raw) {
  object(raw, "config", [
    "expectedChainId",
    "economicAssetIdHash",
    "assetToken",
    "deploymentKind",
    "implementation",
    "permitCapability",
    "assetClass",
    "adapter",
    "calculator",
    "marketRule",
  ]);
  const expectedChainId = raw.expectedChainId;
  if (!Number.isSafeInteger(expectedChainId) || expectedChainId <= 0) throw new Error("expectedChainId 必须是正整数");
  const assetClassName = String(raw.assetClass ?? "").toUpperCase();
  const adapter = String(raw.adapter ?? "");
  const calculator = String(raw.calculator ?? "").toUpperCase();
  if (!["unrestricted", "usdyRestricted", "ondoGm", "erc1404"].includes(adapter)) {
    throw new Error("adapter 只能是 unrestricted / usdyRestricted / ondoGm / erc1404");
  }
  if (!["STOCK", "FUND", "BOND"].includes(calculator)) throw new Error("calculator 只能是 STOCK / FUND / BOND");
  if (calculator !== assetClassName) throw new Error("calculator 必须与 assetClass 相同");
  if (adapter === "ondoGm" && assetClassName !== "STOCK") throw new Error("Ondo GM 资产必须使用 STOCK");
  if (adapter === "usdyRestricted" && assetClassName !== "FUND") throw new Error("USDY 资产必须使用 FUND");
  if (HSK_CHAIN_IDS.has(expectedChainId) && adapter !== "usdyRestricted") {
    throw new Error("HSK 只允许上架 USDY");
  }

  const deploymentKind = enumValue(Enum.TokenDeploymentKind, raw.deploymentKind, "deploymentKind");
  const implementation =
    raw.implementation === null || raw.implementation === undefined
      ? null
      : requireAddress(raw.implementation, "implementation");
  if (deploymentKind === Enum.TokenDeploymentKind.DIRECT && implementation !== null) {
    throw new Error("DIRECT 资产的 implementation 必须为空");
  }
  if (deploymentKind === Enum.TokenDeploymentKind.ERC1967_PROXY && implementation === null) {
    throw new Error("ERC1967_PROXY 资产必须提供 implementation");
  }

  const market = object(raw.marketRule, "marketRule", [
    "minCashPrincipal",
    "minExecutableQuantity",
    "quantityStep",
    "priceTick",
    "priceDecimals",
    "quantityDecimals",
    "quoteValidFrom",
    "quoteValidUntil",
    "settlementValidUntil",
  ]);
  for (const name of ["priceDecimals", "quantityDecimals"]) {
    if (!Number.isInteger(market[name]) || market[name] < 0 || market[name] > 36) {
      throw new Error(`marketRule.${name} 必须是 0-36 的整数`);
    }
  }
  return {
    expectedChainId,
    economicAssetIdHash: bytes32(raw.economicAssetIdHash, "economicAssetIdHash"),
    assetToken: requireAddress(raw.assetToken, "assetToken"),
    deploymentKind,
    implementation,
    permitCapability: enumValue(Enum.PermitCapability, raw.permitCapability, "permitCapability"),
    assetClass: enumValue(Enum.AssetClass, assetClassName, "assetClass"),
    assetClassName,
    adapter,
    calculator,
    marketRule: {
      minCashPrincipal: uint(market.minCashPrincipal, "marketRule.minCashPrincipal"),
      minExecutableQuantity: uint(market.minExecutableQuantity, "marketRule.minExecutableQuantity"),
      quantityStep: uint(market.quantityStep, "marketRule.quantityStep"),
      priceTick: uint(market.priceTick, "marketRule.priceTick"),
      priceDecimals: market.priceDecimals,
      quantityDecimals: market.quantityDecimals,
      quoteValidFrom: optionalUnix(market.quoteValidFrom, "marketRule.quoteValidFrom"),
      quoteValidUntil: optionalUnix(market.quoteValidUntil, "marketRule.quoteValidUntil"),
      settlementValidUntil: optionalUnix(market.settlementValidUntil, "marketRule.settlementValidUntil"),
    },
  };
}

function platformParts(report) {
  const full = Boolean(report.metadata);
  const configuration = full ? report.configuration : report.configs;
  return {
    chainId: full ? report.metadata.chainId : report.chainId,
    finalityConfirmations: full ? report.metadata.finalityConfirmations : report.finalityConfirmations,
    deploymentVersion: full ? report.metadata.deploymentVersion : report.deploymentVersion,
    platformReady: full ? report.metadata.platformReady : report.platformReady,
    dvp: full ? report.addresses.dvp : report.contracts?.dvp,
    settlementToken: full ? report.addresses.settlementToken : report.contracts?.settlementToken,
    registries: full ? report.addresses.registries : report.contracts?.registries,
    roles: report.roles,
    adapters: configuration?.assetAdapters,
    calculators: configuration?.calculators,
    settlement: configuration?.settlementToken,
    feeEpoch: configuration?.feeEpoch,
  };
}

export function loadAssetPlatform(reportPath, config) {
  if (!existsSync(reportPath)) throw new Error(`找不到平台报告 ${reportPath}`);
  const platform = platformParts(readJson(reportPath));
  if (
    !Number.isSafeInteger(platform.chainId)
    || platform.chainId <= 0
    || !Number.isSafeInteger(platform.finalityConfirmations)
    || platform.finalityConfirmations <= 0
    || !platform.platformReady
  ) {
    throw new Error(`${reportPath} 不是已就绪的平台报告`);
  }
  if (platform.chainId !== config.expectedChainId) {
    throw new Error(`平台 chainId=${platform.chainId}，配置 expectedChainId=${config.expectedChainId}`);
  }
  const adapter = platform.adapters?.[config.adapter];
  const calculator = platform.calculators?.[config.calculator];
  if (!adapter || !calculator || !platform.settlement) {
    throw new Error(`平台报告缺少 ${config.adapter} Adapter、${config.calculator} Calculator 或 SettlementToken 配置`);
  }
  const normalized = {
    ...platform,
    dvp: requireAddress(platform.dvp, "报告中的 dvp"),
    settlementToken: requireAddress(platform.settlementToken, "报告中的 settlementToken"),
    registries: Object.fromEntries(
      ["adapter", "calculator", "settlementToken", "assetVersion", "marketRule"].map((key) => [
        key,
        requireAddress(platform.registries?.[key], `报告中的 registries.${key}`),
      ]),
    ),
    adapter: {
      id: adapter.id ?? adapter.adapterConfigId,
      hash: adapter.hash ?? adapter.configHash,
      token: requireAddress(adapter.token ?? adapter.binding?.token, "报告中的 Adapter 参考 token"),
      tokenStandard: enumValue(Enum.TokenStandard, adapter.tokenStandard ?? adapter.capabilities?.tokenStandard, "Adapter tokenStandard"),
      restrictionMode: enumValue(
        Enum.RestrictionMode,
        adapter.restrictionMode ?? adapter.capabilities?.restrictionMode,
        "Adapter restrictionMode",
      ),
    },
    calculator: {
      id: calculator.id ?? calculator.calculatorConfigId,
      hash: calculator.hash ?? calculator.configHash,
    },
    settlement: {
      id: platform.settlement.id ?? platform.settlement.configId,
      hash: platform.settlement.hash ?? platform.settlement.configHash,
      decimals: platform.settlement.decimals ?? platform.settlement.settlementTokenDecimals,
    },
    feeEpoch: {
      quoteValidFrom: platform.feeEpoch?.quoteValidFrom?.unix ?? platform.feeEpoch?.quoteValidFrom,
      quoteValidUntil: platform.feeEpoch?.quoteValidUntil?.unix ?? platform.feeEpoch?.quoteValidUntil,
      settlementValidUntil:
        platform.feeEpoch?.settlementValidUntil?.unix ?? platform.feeEpoch?.settlementValidUntil,
    },
  };
  for (const [label, value] of [
    ["adapter.id", normalized.adapter.id],
    ["adapter.hash", normalized.adapter.hash],
    ["calculator.id", normalized.calculator.id],
    ["calculator.hash", normalized.calculator.hash],
    ["settlement.id", normalized.settlement.id],
    ["settlement.hash", normalized.settlement.hash],
  ]) {
    if (!/^0x[0-9a-fA-F]{64}$/u.test(String(value))) throw new Error(`平台报告中的 ${label} 不是 bytes32`);
  }
  return normalized;
}

export function assertSameOndoFamily(reference, candidate) {
  for (const field of FAMILY_FIELDS) {
    if (reference[field] !== candidate[field]) {
      throw new Error(`资产 token 与 Ondo GM 参考 token 不属于同一合约族：${field} 不一致`);
    }
  }
}

export function buildListingConfigs(config, platform, deployment, assetDecimals) {
  if (!Number.isInteger(assetDecimals) || assetDecimals < 1 || assetDecimals > 36) {
    throw new Error("资产 decimals 必须是 1-36 的整数");
  }
  const market = config.marketRule;
  const epoch = platform.feeEpoch;
  const quoteValidFrom = market.quoteValidFrom ?? epoch.quoteValidFrom;
  const quoteValidUntil = market.quoteValidUntil ?? epoch.quoteValidUntil;
  const settlementValidUntil = market.settlementValidUntil ?? epoch.settlementValidUntil;
  if (
    !(quoteValidFrom <= quoteValidUntil && quoteValidUntil <= settlementValidUntil)
    || quoteValidFrom < epoch.quoteValidFrom
    || settlementValidUntil > epoch.settlementValidUntil
  ) {
    throw new Error("MarketRule 窗口必须有序且落在平台 Fee Epoch 窗口内");
  }
  if (market.priceDecimals !== platform.settlement.decimals || market.quantityDecimals !== assetDecimals) {
    throw new Error("MarketRule priceDecimals 必须等于结算币 decimals，quantityDecimals 必须等于资产 decimals");
  }

  const assetVersionId = deriveAssetVersionId(
    SCHEMA_VERSION,
    config.economicAssetIdHash,
    platform.chainId,
    config.assetToken,
    1,
  );
  const asset = {
    schemaVersion: SCHEMA_VERSION,
    economicAssetIdHash: config.economicAssetIdHash,
    assetVersionId,
    chainId: platform.chainId,
    versionNo: 1,
    assetToken: config.assetToken,
    tokenStandard: platform.adapter.tokenStandard,
    tokenDeploymentKind: deployment.kind,
    assetDecimals,
    tokenCodeHash: deployment.tokenCodeHash,
    implementation: deployment.implementation,
    implementationCodeHash: deployment.implementationCodeHash,
    assetPermitCapability: config.permitCapability,
    assetClass: config.assetClass,
    principalCalculatorConfigId: platform.calculator.id,
    principalCalculatorConfigHash: platform.calculator.hash,
    adapterConfigId: platform.adapter.id,
    adapterConfigHash: platform.adapter.hash,
    restrictionMode: platform.adapter.restrictionMode,
    settlementToken: platform.settlementToken,
    settlementTokenConfigId: platform.settlement.id,
    settlementTokenConfigHash: platform.settlement.hash,
    dvpContract: platform.dvp,
    deploymentVersionHash: hashDeploymentVersion(platform.deploymentVersion),
    replacesAssetVersionId: ZERO_BYTES32,
    configHash: ZERO_BYTES32,
  };
  asset.configHash = hashAssetVersionConfig(asset);

  const marketRule = {
    schemaVersion: SCHEMA_VERSION,
    marketRuleConfigId: deriveConfigId(Namespace.MARKET_RULE, SCHEMA_VERSION, platform.chainId, assetVersionId, 1),
    revision: 1,
    chainId: platform.chainId,
    assetVersionId,
    settlementToken: platform.settlementToken,
    settlementTokenConfigId: platform.settlement.id,
    settlementTokenConfigHash: platform.settlement.hash,
    minCashPrincipal: market.minCashPrincipal,
    minExecutableQuantity: market.minExecutableQuantity,
    quantityStep: market.quantityStep,
    priceTick: market.priceTick,
    priceDecimals: market.priceDecimals,
    quantityDecimals: market.quantityDecimals,
    quoteValidFrom,
    quoteValidUntil,
    settlementValidUntil,
    replacesConfigId: ZERO_BYTES32,
    configHash: ZERO_BYTES32,
  };
  marketRule.configHash = hashMarketRuleConfig(marketRule);
  return { asset, marketRule };
}

async function assertAssetBindingCurrent(ctx) {
  const [adapter, deployment] = await Promise.all([
    ctx.publicClient.readContract({
      address: ctx.platform.registries.adapter,
      abi: loadArtifact("AdapterRegistry").abi,
      functionName: "getAdapter",
      args: [ctx.platform.adapter.id],
    }),
    detectTokenDeployment(ctx.publicClient, ctx.config.assetToken, {
      deploymentKind: ctx.config.deploymentKind,
      implementation: ctx.config.implementation,
    }),
  ]);
  if (
    Number(adapter.status) !== Enum.AdapterStatus.ACTIVE
    || adapter.config.configHash !== ctx.platform.adapter.hash
    || deployment.tokenCodeHash !== ctx.configs.asset.tokenCodeHash
    || deployment.implementation !== ctx.configs.asset.implementation
    || deployment.implementationCodeHash !== ctx.configs.asset.implementationCodeHash
  ) {
    throw new Error("资产激活前 Token 或 Adapter 基线发生变化");
  }
  if (ctx.config.adapter === "unrestricted") return;

  const spec = (token) => ({ token, providerCallGas: 100_000 });
  if (ctx.config.adapter === "ondoGm") {
    const [reference, candidate] = await Promise.all([
      readRestrictedBinding(ctx.publicClient, "ondoGm", spec(ctx.platform.adapter.token)),
      readRestrictedBinding(ctx.publicClient, "ondoGm", spec(ctx.config.assetToken)),
    ]);
    if (reference.providerHash !== adapter.config.providerHash) {
      throw new Error("Ondo GM 参考 token 的 provider graph 与已登记 Adapter 不一致");
    }
    assertSameOndoFamily(reference, candidate);
    return;
  }
  const binding = await readRestrictedBinding(ctx.publicClient, ctx.config.adapter, spec(ctx.config.assetToken));
  if (ctx.config.assetToken !== ctx.platform.adapter.token || binding.providerHash !== adapter.config.providerHash) {
    throw new Error(`${ctx.config.adapter} Adapter 不再匹配资产 token`);
  }
}

export function listingSteps() {
  const assetAbi = () => loadArtifact("AssetVersionRegistry").abi;
  const marketAbi = () => loadArtifact("MarketRuleRegistry").abi;
  const storedHash = (label, record, expected) => {
    if (record.exists && record.config.configHash !== expected) {
      throw new Error(`${label} 已存在但 configHash 不同`);
    }
    return Boolean(record.exists);
  };
  const assetRecord = (ctx) =>
    ctx.publicClient.readContract({
      address: ctx.platform.registries.assetVersion,
      abi: assetAbi(),
      functionName: "getAssetVersion",
      args: [ctx.configs.asset.assetVersionId],
    });
  const marketRecord = (ctx) =>
    ctx.publicClient.readContract({
      address: ctx.platform.registries.marketRule,
      abi: marketAbi(),
      functionName: "getMarketRule",
      args: [ctx.configs.marketRule.marketRuleConfigId],
    });
  return [
    {
      id: "asset.register",
      phase: "asset",
      title: "registerAssetVersion",
      kind: "write",
      signer: "configurer",
      build: (ctx) => ({
        address: ctx.platform.registries.assetVersion,
        abi: assetAbi(),
        functionName: "registerAssetVersion",
        args: [ctx.configs.asset],
      }),
      check: async (ctx) => storedHash("AssetVersion", await assetRecord(ctx), ctx.configs.asset.configHash),
    },
    {
      id: "asset.activate",
      phase: "asset",
      title: "activateAssetVersion",
      kind: "write",
      signer: "governance",
      build: async (ctx) => {
        await assertAssetBindingCurrent(ctx);
        return {
          address: ctx.platform.registries.assetVersion,
          abi: assetAbi(),
          functionName: "activateAssetVersion",
          args: [ctx.configs.asset.assetVersionId, ctx.configs.asset.configHash],
        };
      },
      check: async (ctx) => Number((await assetRecord(ctx)).status) === Enum.AssetVersionStatus.ACTIVE,
    },
    {
      id: "market.register",
      phase: "market",
      title: "registerMarketRule",
      kind: "write",
      signer: "configurer",
      build: (ctx) => ({
        address: ctx.platform.registries.marketRule,
        abi: marketAbi(),
        functionName: "registerMarketRule",
        args: [ctx.configs.marketRule],
      }),
      check: async (ctx) => storedHash("MarketRule", await marketRecord(ctx), ctx.configs.marketRule.configHash),
    },
    {
      id: "market.seal",
      phase: "market",
      title: "sealMarketRule",
      kind: "write",
      signer: "governance",
      build: (ctx) => ({
        address: ctx.platform.registries.marketRule,
        abi: marketAbi(),
        functionName: "sealMarketRule",
        args: [ctx.configs.marketRule.marketRuleConfigId, ctx.configs.marketRule.configHash],
      }),
      check: async (ctx) => Boolean((await marketRecord(ctx)).isSealed),
    },
    {
      id: "market.activate",
      phase: "market",
      title: "activateMarketRule",
      kind: "write",
      signer: "governance",
      build: (ctx) => ({
        address: ctx.platform.registries.marketRule,
        abi: marketAbi(),
        functionName: "activateMarketRule",
        args: [ctx.configs.marketRule.marketRuleConfigId, ctx.configs.marketRule.configHash],
      }),
      check: async (ctx) => {
        const record = await marketRecord(ctx);
        return Number(record.status) === Enum.MarketRuleStatus.ACTIVE && !record.paused;
      },
    },
  ];
}

async function preflight(ctx, steps) {
  const pending = steps.filter((step) => ctx.state.steps[step.id]?.status !== "done");
  const chainId = await ctx.publicClient.getChainId();
  if (chainId !== ctx.platform.chainId) throw new Error(`RPC chainId=${chainId}，平台报告 chainId=${ctx.platform.chainId}`);
  if (ctx.config.adapter === "ondoGm") {
    await assertMainnetOndoEvidence({
      chainId,
      config: { assetAdapters: { ondoGm: { token: ctx.platform.adapter.token } } },
      publicClient: ctx.publicClient,
    });
  }
  const [dvpAssetRegistry, dvpMarketRegistry] = await Promise.all([
    ctx.publicClient.readContract({
      address: ctx.platform.dvp,
      abi: DVP_VIEW_ABI,
      functionName: "assetVersionRegistry",
    }),
    ctx.publicClient.readContract({
      address: ctx.platform.dvp,
      abi: DVP_VIEW_ABI,
      functionName: "marketRuleRegistry",
    }),
  ]);
  if (
    getAddress(dvpAssetRegistry) !== ctx.platform.registries.assetVersion
    || getAddress(dvpMarketRegistry) !== ctx.platform.registries.marketRule
  ) {
    throw new Error("平台报告中的 Registry 与 DvP 当前绑定不一致");
  }

  const registryAbi = {
    adapter: loadArtifact("AdapterRegistry").abi,
    calculator: loadArtifact("PrincipalCalculatorRegistry").abi,
    settlementToken: loadArtifact("SettlementTokenRegistry").abi,
  };
  const [adapter, calculator, settlement] = await Promise.all([
    ctx.publicClient.readContract({
      address: ctx.platform.registries.adapter,
      abi: registryAbi.adapter,
      functionName: "getAdapter",
      args: [ctx.platform.adapter.id],
    }),
    ctx.publicClient.readContract({
      address: ctx.platform.registries.calculator,
      abi: registryAbi.calculator,
      functionName: "getPrincipalCalculator",
      args: [ctx.platform.calculator.id],
    }),
    ctx.publicClient.readContract({
      address: ctx.platform.registries.settlementToken,
      abi: registryAbi.settlementToken,
      functionName: "getSettlementToken",
      args: [ctx.platform.settlement.id],
    }),
  ]);
  if (
    Number(adapter.status) !== Enum.AdapterStatus.ACTIVE
    || adapter.config.configHash !== ctx.platform.adapter.hash
    || Number(calculator.status) !== Enum.CalculatorStatus.ACTIVE
    || calculator.config.configHash !== ctx.platform.calculator.hash
    || Number(settlement.status) !== Enum.SettlementTokenStatus.ACTIVE
    || settlement.config.configHash !== ctx.platform.settlement.hash
  ) {
    throw new Error("资产引用的 Adapter / Calculator / SettlementToken 链上配置不是报告中的 ACTIVE 配置");
  }

  await assertAssetBindingCurrent(ctx);

  const roleFor = { configurer: "CONFIGURER_ROLE", governance: "GOVERNANCE_ROLE" };
  for (const signer of new Set(pending.map((step) => step.signer))) {
    const account = ctx.signers[signer];
    for (const registry of [ctx.platform.registries.assetVersion, ctx.platform.registries.marketRule]) {
      const granted = await ctx.publicClient.readContract({
        address: registry,
        abi: ACCESS_ABI,
        functionName: "hasRole",
        args: [ROLE_ID[roleFor[signer]], account.address],
      });
      if (!granted) throw new Error(`${account.address} 没有 Registry 的 ${roleFor[signer]}`);
    }
    if ((await ctx.publicClient.getBalance({ address: account.address })) === 0n) {
      throw new Error(`${signer} ${account.address} 余额为 0，付不起 gas`);
    }
  }
  const now = Number((await ctx.publicClient.getBlock()).timestamp);
  if (pending.some((step) => step.id === "market.activate")) {
    const rule = ctx.configs.marketRule;
    if (now < rule.quoteValidFrom || now > rule.quoteValidUntil) {
      throw new Error("当前链上时间不在 MarketRule 报价窗口内，不能激活");
    }
  }
}

function signers(keys) {
  const configurerKey = asPrivateKey(keys.configurer, "HTP_CONFIGURER_KEY");
  const governanceKey = asPrivateKey(keys.governance, "HTP_GOVERNANCE_KEY");
  if (!configurerKey || !governanceKey) {
    throw new Error("必须设置 HTP_CONFIGURER_KEY 和 HTP_GOVERNANCE_KEY");
  }
  return {
    configurer: privateKeyToAccount(configurerKey),
    governance: privateKeyToAccount(governanceKey),
  };
}

function mergeIndex(path, platform, entry) {
  const index = existsSync(path)
    ? readJson(path)
    : { chainId: platform.chainId, dvp: platform.dvp, assets: [] };
  if (index.chainId !== platform.chainId || index.dvp !== platform.dvp) {
    throw new Error(`${path} 属于另一套平台部署`);
  }
  index.assets = [...index.assets.filter((item) => item.assetVersionId !== entry.assetVersionId), entry]
    .sort((left, right) => left.assetVersionId.localeCompare(right.assetVersionId));
  writeJsonAtomic(path, index);
}

export async function listAsset(options) {
  const config = normalizeAssetConfig(options.rawConfig);
  const reportPath = resolve(options.reportPath ?? join(tmpOutRoot, "platform-summary.json"));
  const platform = loadAssetPlatform(reportPath, config);
  if (!platform.feeEpoch?.quoteValidFrom) throw new Error("平台报告缺少 Fee Epoch 窗口");

  const steps = listingSteps();
  const statePath = resolve(
    options.statePath ?? join(tmpOutRoot, `asset-state.${platform.chainId}.${config.assetToken.toLowerCase()}.json`),
  );
  if (options.status) {
    printStatus(steps, existsSync(statePath) ? readJson(statePath) : { steps: {} });
    return null;
  }
  const rpcUrl = String(options.rpcUrl ?? "");
  if (!rpcUrl) throw new Error("缺少 RPC：用 --rpc 或 HTP_RPC_URL 指定");
  assertRpcUrl(rpcUrl);
  ensureBuild();
  const accounts = signers(options.keys ?? {});
  const { publicClient, wallets } = createChainClients(rpcUrl, platform.chainId, accounts);
  const assetDecimals = Number(
    await publicClient.readContract({ address: config.assetToken, abi: ERC20_META_ABI, functionName: "decimals" }),
  );
  const deployment = await detectTokenDeployment(publicClient, config.assetToken, {
    deploymentKind: config.deploymentKind,
    implementation: config.implementation,
  });
  const configs = buildListingConfigs(config, platform, deployment, assetDecimals);
  const fingerprint = {
    chainId: platform.chainId,
    dvp: platform.dvp,
    assetToken: config.assetToken,
    configHash: keccak256(stringToHex(`${configs.asset.configHash}:${configs.marketRule.configHash}`)),
  };
  const outPath = resolve(options.outPath ?? join(tmpOutRoot, `assets.${platform.chainId}.json`));
  const releaseLock = acquireLock(statePath);
  try {
    const state = loadState(statePath, fingerprint);
    const ctx = {
      config,
      configs,
      platform,
      publicClient,
      wallets,
      signers: accounts,
      finalityConfirmations: platform.finalityConfirmations,
      state,
      statePath,
      nextNonce: new Map(),
      sentCount: 0,
      saveState: () => {
        state.updatedAt = new Date().toISOString();
        writeJsonAtomic(statePath, state);
      },
    };
    ctx.saveState();
    await preflight(ctx, steps);
    await runSteps(ctx, steps, { from: null, start: 0, end: steps.length - 1 });
    const entry = {
      assetToken: config.assetToken,
      economicAssetIdHash: config.economicAssetIdHash,
      assetVersionId: configs.asset.assetVersionId,
      assetVersionConfigHash: configs.asset.configHash,
      marketRuleConfigId: configs.marketRule.marketRuleConfigId,
      marketRuleConfigHash: configs.marketRule.configHash,
      adapterConfigId: platform.adapter.id,
      adapterConfigHash: platform.adapter.hash,
      adapterTransactions: 0,
      status: "ACTIVE",
    };
    mergeIndex(outPath, platform, entry);
    console.log(`资产已上架：${config.assetToken}`);
    console.log(`AssetVersion: ${entry.assetVersionId}`);
    console.log(`MarketRule: ${entry.marketRuleConfigId}`);
    console.log(`本次发送 ${ctx.sentCount} 笔交易；Adapter 交易 0 笔`);
    return { entry, sentCount: ctx.sentCount };
  } finally {
    releaseLock();
  }
}

async function runSelfTest() {
  ensureBuild([
    "PipelineCashToken",
    "UsdyTokenMock",
    "AddressListMock",
    "OndoGmListMock",
    "OndoGmPauseManagerMock",
    "OndoComplianceMock",
    "OndoComplianceViewMock",
    "IntegrationOndoGmToken",
  ]);
  const workDir = join(tmpOutRoot, "self-test-list-asset");
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });
  const check = (condition, message) => {
    if (!condition) throw new Error(`自测失败：${message}`);
  };

  await withAnvil(async (rpcUrl) => {
    const [deployer, governance, configurer] = ANVIL_KEYS.map((key) => privateKeyToAccount(key));
    const chain = defineChain({
      id: 31337,
      name: "Anvil",
      nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [rpcUrl] } },
    });
    const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
    const wallet = createWalletClient({ chain, account: deployer, transport: http(rpcUrl) });
    const deployMock = async (name, args = []) => {
      const artifact = loadArtifact(name);
      const hash = await wallet.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode, args });
      return getAddress((await publicClient.waitForTransactionReceipt({ hash })).contractAddress);
    };
    const callMock = async (name, address, functionName, args) => {
      const hash = await wallet.writeContract({ address, abi: loadArtifact(name).abi, functionName, args });
      await publicClient.waitForTransactionReceipt({ hash });
    };

    const cashToken = await deployMock("PipelineCashToken");
    const lists = [await deployMock("AddressListMock"), await deployMock("AddressListMock"), await deployMock("AddressListMock")];
    const usdy = await deployMock("UsdyTokenMock");
    await callMock("UsdyTokenMock", usdy, "configure", lists);
    const blocklist = await deployMock("OndoGmListMock");
    const sanctionsList = await deployMock("OndoGmListMock");
    const pauseManager = await deployMock("OndoGmPauseManagerMock");
    const compliance = await deployMock("OndoComplianceMock");
    const complianceView = await deployMock("OndoComplianceViewMock", [compliance, ONDO_GM_IDENTIFIER]);
    await callMock("OndoComplianceMock", compliance, "configure", [
      ONDO_GM_IDENTIFIER,
      blocklist,
      sanctionsList,
    ]);
    const referenceToken = await deployMock("IntegrationOndoGmToken", [complianceView, pauseManager]);
    const siblingToken = await deployMock("IntegrationOndoGmToken", [complianceView, pauseManager]);

    const reportPath = join(workDir, "platform-deployment.json");
    await deployPlatform({
      rawConfig: {
        expectedChainId: 31337,
        finalityConfirmations: 1,
        deploymentVersion: "1.0.0",
        evidenceHash: `0x${"22".repeat(32)}`,
        roles: {
          defaultAdmin: deployer.address,
          governance: governance.address,
          upgrader: ADDRESS_FOR_SELF_TEST.upgrader,
          pauser: ADDRESS_FOR_SELF_TEST.pauser,
          executor: ADDRESS_FOR_SELF_TEST.executor,
          configurer: configurer.address,
        },
        settlementToken: {
          address: cashToken,
          decimals: 6,
          permitCapability: "UNSUPPORTED",
          deploymentKind: "DIRECT",
        },
        calculators: ["FUND", "STOCK"],
        assetAdapters: {
          usdyRestricted: { token: usdy },
          ondoGm: { token: referenceToken },
        },
        feeEpoch: {},
        globalFee: {
          investorRateBps: 25,
          investorHasCap: false,
          investorCapAmount: "0",
          makerRateBps: 15,
          makerHasCap: false,
          makerCapAmount: "0",
          collector: deployer.address,
        },
      },
      rpcUrl,
      keys: {
        deployer: ANVIL_KEYS[0],
        governance: ANVIL_KEYS[1],
        configurer: ANVIL_KEYS[2],
      },
      statePath: join(workDir, "platform-state.json"),
      outPath: reportPath,
    });

    const rawAsset = (token, economicByte) => ({
      expectedChainId: 31337,
      economicAssetIdHash: `0x${economicByte.repeat(64)}`,
      assetToken: token,
      deploymentKind: "DIRECT",
      implementation: null,
      permitCapability: "UNSUPPORTED",
      assetClass: "STOCK",
      adapter: "ondoGm",
      calculator: "STOCK",
      marketRule: {
        minCashPrincipal: "1",
        minExecutableQuantity: "1",
        quantityStep: "1",
        priceTick: "1",
        priceDecimals: 6,
        quantityDecimals: 18,
        quoteValidFrom: null,
        quoteValidUntil: null,
        settlementValidUntil: null,
      },
    });
    const base = {
      reportPath: join(workDir, "platform-summary.json"),
      rpcUrl,
      keys: { configurer: ANVIL_KEYS[2], governance: ANVIL_KEYS[1] },
      outPath: join(workDir, "assets.json"),
    };
    const first = await listAsset({
      ...base,
      rawConfig: rawAsset(referenceToken, "1"),
      statePath: join(workDir, "asset-reference-state.json"),
    });
    const second = await listAsset({
      ...base,
      rawConfig: rawAsset(siblingToken, "2"),
      statePath: join(workDir, "asset-sibling-state.json"),
    });
    check(first.sentCount === 5 && second.sentCount === 5, "每个新资产应只发送 5 笔 Registry 交易");
    check(first.entry.adapterConfigId === second.entry.adapterConfigId, "同族资产必须复用同一个 adapterConfigId");
    check(first.entry.assetVersionId !== second.entry.assetVersionId, "不同 token 必须有不同 AssetVersion");
    const again = await listAsset({
      ...base,
      rawConfig: rawAsset(siblingToken, "2"),
      statePath: join(workDir, "asset-sibling-state.json"),
    });
    check(again.sentCount === 0, "重跑资产上架不应重复发交易");
    check(readJson(base.outPath).assets.length === 2, "汇总应包含两项资产");
  });
  console.log("\n资产上架自测全部通过");
}

const ADDRESS_FOR_SELF_TEST = Object.freeze({
  upgrader: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
  pauser: "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65",
  executor: "0x9965507d1a55bcc2695d58f0e5bd91d6fbf4dd6d",
});

async function main() {
  const flags = parseArgs(process.argv.slice(2));
  if (flags.help) {
    console.log(usage());
    return;
  }
  if (flags["self-test"]) {
    await runSelfTest();
    return;
  }
  if (typeof flags.config !== "string") throw new Error(`必须提供 --config\n\n${usage()}`);
  loadTmpEnv();
  await listAsset({
    rawConfig: readJson(resolve(process.cwd(), flags.config)),
    reportPath: typeof flags.report === "string" ? resolve(process.cwd(), flags.report) : undefined,
    rpcUrl: typeof flags.rpc === "string" ? flags.rpc : process.env.HTP_RPC_URL,
    keys: {
      configurer: process.env.HTP_CONFIGURER_KEY,
      governance: process.env.HTP_GOVERNANCE_KEY,
    },
    statePath: typeof flags.state === "string" ? resolve(process.cwd(), flags.state) : undefined,
    outPath: typeof flags.out === "string" ? resolve(process.cwd(), flags.out) : undefined,
    status: Boolean(flags.status),
  });
}

const invoked = process.argv[1] !== undefined && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (invoked) {
  main().catch((error) => {
    console.error(`\n错误：${safeErrorMessage(error)}`);
    process.exitCode = 1;
  });
}
