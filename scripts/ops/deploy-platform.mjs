#!/usr/bin/env node
// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
/**
 * HTP 平台初始化部署（分阶段、可断点续跑）。
 *
 * 只立平台和共享件：8 个 Registry、ValidatorFactory、DvPSettlement、registerDependentDvp、
 * 适配器、本金计算器、结算币配置、Fee Epoch 1 + GLOBAL 默认费率。
 * 不做：资产版本、市场规则、参与方、资格、角色移交。
 *
 * 适配器（部署 + registerAdapter + activateAdapter）：
 *   UnrestrictedERC20Adapter  必部署。ERC20 / UNRESTRICTED，资产腿和结算腿都能用，结算币也用它
 *   UsdyRestrictedAdapter     配置 assetAdapters.usdyRestricted 时部署。ERC20 / TOKEN_ENFORCED，仅资产腿
 *   OndoGmTokenAdapter        配置 assetAdapters.ondoGm 时部署。ERC20 / TOKEN_ENFORCED，仅资产腿
 *   ERC1404Adapter            配置 assetAdapters.erc1404 时部署。ERC1404 / ISSUER_EXTERNAL，仅资产腿
 * Ondo GM 以配置 token 为参考固定 runtime/provider 图，同一合约族复用一个实例；USDY/ERC1404 仍绑定单 token。
 * USDY 适配器会检查调用方 DvP 是否在代币 allowlist 中，新 DvP 部署后需要由 USDY 名单管理员加入 allowlist。
 *
 * 私钥只从环境变量读取（自动加载 tmp/.env，shell 里的同名变量优先），配置文件里出现私钥字段会直接拒绝：
 *   HTP_DEPLOYER_KEY     必填
 *   HTP_GOVERNANCE_KEY   roles.governance 不是部署者时必填
 *   HTP_CONFIGURER_KEY   roles.configurer 不是部署者时必填
 *
 * 每一步完成后写入状态文件（默认 tmp/out/platform-state.<chainId>.json），失败后重跑同一条命令即可续跑。
 *
 * 用法（仓库根目录，先按 .env.example 填好 tmp/.env）：
 *   node scripts/ops/deploy-platform.mjs --config tmp/platform.json
 *   node scripts/ops/deploy-platform.mjs --config tmp/platform.json --status
 *   node scripts/ops/deploy-platform.mjs --self-test
 */

import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { createServer } from "node:net";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  concat,
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  getContractAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  stringToHex,
  toFunctionSelector,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { verifyOndoGmFixedBlock } from "../fork/verify-ondo-gm-fixed-block.mjs";
import {
  Enum,
  InterfaceVersion,
  Namespace,
  SCHEMA_VERSION,
  ZERO_ADDRESS,
  ZERO_BYTES32,
  assertPinnedHashes,
  assetClassSubject,
  deriveConfigId,
  hashAdapterCapabilities,
  hashAdapterConfig,
  hashDeploymentVersion,
  hashFeeConfig,
  hashFeeConstraint,
  hashFeePolicyEpochConfig,
  hashPrincipalCalculatorConfig,
  hashSettlementTokenConfig,
  keccakUtf8,
  matchedScopeHash,
  tokenSubject,
} from "./lib/htp-hash.mjs";
import { loadTmpEnv, safeErrorMessage } from "./lib/env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const contractsRoot = join(repoRoot, "contracts");
const tmpOutRoot = join(repoRoot, "tmp", "out");
const defaultOutRoot = join(contractsRoot, "out");
let outRoot = defaultOutRoot;

const STATE_VERSION = 1;
const FEE_EPOCH = 1;
const MAX_AGGREGATE_FEE_BPS = 1_000;
const UINT256_MAX = (1n << 256n) - 1n;
const RECEIPT_TIMEOUT_MS = 180_000;
const RECEIPT_BLOCK_BUDGET_MS = 30_000;
// 负载均衡的 RPC 各节点同步有先后：拿到回执后要等读请求也能看到结果，再继续下一步。
const VISIBILITY_TIMEOUT_MS = 90_000;
const VISIBILITY_POLL_MS = 1_000;
const SEND_ATTEMPTS = 3;
const SEND_RETRY_MS = 4_000;
const DAY = 24 * 60 * 60;

const ERC1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ERC1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

const ROLE_ID = Object.freeze({
  DEFAULT_ADMIN_ROLE: ZERO_BYTES32,
  GOVERNANCE_ROLE: keccakUtf8("GOVERNANCE_ROLE"),
  UPGRADER_ROLE: keccakUtf8("UPGRADER_ROLE"),
  PAUSER_ROLE: keccakUtf8("PAUSER_ROLE"),
  EXECUTOR_ROLE: keccakUtf8("EXECUTOR_ROLE"),
  CONFIGURER_ROLE: keccakUtf8("CONFIGURER_ROLE"),
});

// 顺序即部署顺序：deps 必须已经部署。
const REGISTRY_SPECS = Object.freeze([
  { key: "adapter", contract: "AdapterRegistry", deps: [] },
  { key: "calculator", contract: "PrincipalCalculatorRegistry", deps: [] },
  { key: "settlementToken", contract: "SettlementTokenRegistry", deps: ["adapter"] },
  { key: "assetVersion", contract: "AssetVersionRegistry", deps: ["settlementToken", "adapter", "calculator"] },
  { key: "eligibility", contract: "EligibilityRegistry", deps: [] },
  { key: "marketRule", contract: "MarketRuleRegistry", deps: ["assetVersion", "settlementToken"] },
  { key: "fee", contract: "FeeRegistry", deps: ["assetVersion", "settlementToken"] },
  { key: "participant", contract: "ParticipantRegistry", deps: [] },
]);

const CALCULATOR_SPECS = Object.freeze({
  STOCK: { contract: "StockPrincipalCalculator", assetClass: Enum.AssetClass.STOCK },
  FUND: { contract: "FundPrincipalCalculator", assetClass: Enum.AssetClass.FUND },
  BOND: { contract: "BondPrincipalCalculator", assetClass: Enum.AssetClass.BOND },
});

// unrestricted 必部署；其余 key 与配置 assetAdapters 下的字段名一致，配置了才部署。
const ADAPTER_SPECS = Object.freeze({
  unrestricted: {
    stateKey: "unrestrictedAdapter",
    contract: "UnrestrictedERC20Adapter",
    label: "普通 ERC-20 / 结算币适配器",
    tokenStandard: Enum.TokenStandard.ERC20,
    restrictionMode: Enum.RestrictionMode.UNRESTRICTED,
  },
  usdyRestricted: {
    stateKey: "usdyAdapter",
    contract: "UsdyRestrictedAdapter",
    label: "USDY 受限适配器",
    tokenStandard: Enum.TokenStandard.ERC20,
    restrictionMode: Enum.RestrictionMode.TOKEN_ENFORCED,
  },
  ondoGm: {
    stateKey: "ondoGmAdapter",
    contract: "OndoGmTokenAdapter",
    label: "Ondo GMToken 适配器",
    tokenStandard: Enum.TokenStandard.ERC20,
    restrictionMode: Enum.RestrictionMode.TOKEN_ENFORCED,
  },
  erc1404: {
    stateKey: "erc1404Adapter",
    contract: "ERC1404Adapter",
    label: "ERC-1404 适配器",
    tokenStandard: Enum.TokenStandard.ERC1404,
    restrictionMode: Enum.RestrictionMode.ISSUER_EXTERNAL,
  },
});
const RESTRICTED_ADAPTER_KEYS = Object.freeze(["usdyRestricted", "ondoGm", "erc1404"]);
const ADAPTER_PROVIDER_CALL_GAS_MAX = 100_000;
const USDY_LIST_NAMES = Object.freeze(["blocklist", "allowlist", "sanctionsList"]);
export const ONDO_GM_IDENTIFIER = getAddress(`0x${keccakUtf8("global_markets").slice(-40)}`);

const RESTRICTION_PROVIDER_TYPEHASH = keccakUtf8("RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)");
const RESTRICTION_PROVIDER_SET_TYPEHASH = keccakUtf8(
  "RestrictionProviderSet(RestrictionProvider[] providers)RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)",
);
const PROVIDER_SELECTOR = Object.freeze({
  paused: toFunctionSelector("paused()"),
  blocklist: toFunctionSelector("blocklist()"),
  allowlist: toFunctionSelector("allowlist()"),
  sanctionsList: toFunctionSelector("sanctionsList()"),
  isBlocked: toFunctionSelector("isBlocked(address)"),
  isAllowed: toFunctionSelector("isAllowed(address)"),
  isSanctioned: toFunctionSelector("isSanctioned(address)"),
  detectTransferRestriction: toFunctionSelector("detectTransferRestriction(address,address,uint256)"),
  compliance: toFunctionSelector("compliance()"),
  tokenPauseManager: toFunctionSelector("tokenPauseManager()"),
  gmIdentifier: toFunctionSelector("gmIdentifier()"),
  rwaTokenToBlocklist: toFunctionSelector("rwaTokenToBlocklist(address)"),
  rwaTokenToSanctionsList: toFunctionSelector("rwaTokenToSanctionsList(address)"),
  isTokenPaused: toFunctionSelector("isTokenPaused(address)"),
});

const NETWORKS = Object.freeze({
  1: { name: "Ethereum", symbol: "ETH", explorer: "https://etherscan.io" },
  133: { name: "HashKey Chain Testnet", symbol: "HSK", explorer: "https://testnet-explorer.hsk.xyz" },
  177: { name: "HashKey Chain", symbol: "HSK", explorer: "https://explorer.hsk.xyz" },
  31337: { name: "Anvil", symbol: "ETH", explorer: null },
});
const HSK_CHAIN_IDS = new Set([133, 177]);

const ACCESS_ABI = parseAbi(["function hasRole(bytes32 role, address account) view returns (bool)"]);
const DEPENDENT_ABI = parseAbi([
  "function getDependentDvpCount() view returns (uint256)",
  "function getDependentDvp(uint256 index) view returns (address dvp, bool retiredExempt)",
]);
const DVP_VIEW_ABI = parseAbi([
  "function domainSeparatorV4() view returns (bytes32)",
  "function deploymentVersionHash() view returns (bytes32)",
  "function globalPaused() view returns (bool)",
  "function retired() view returns (bool)",
  "function participantRegistry() view returns (address)",
  "function assetVersionRegistry() view returns (address)",
  "function eligibilityRegistry() view returns (address)",
  "function feeRegistry() view returns (address)",
  "function marketRuleRegistry() view returns (address)",
  "function settlementTokenRegistry() view returns (address)",
  "function adapterRegistry() view returns (address)",
  "function principalCalculatorRegistry() view returns (address)",
]);
const ADAPTER_VIEW_ABI = parseAbi([
  "function interfaceVersion() view returns (bytes32)",
  "function capabilities() view returns ((uint8 tokenStandard, uint8 restrictionMode, uint8 precheckMethod, uint256 transferLegMask))",
  "function capabilityHash() view returns (bytes32)",
  "function providerHash() view returns (bytes32)",
]);
const CALCULATOR_VIEW_ABI = parseAbi([
  "function interfaceVersion() view returns (bytes32)",
  "function assetClass() view returns (uint8)",
]);
const ERC20_META_ABI = parseAbi([
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
]);
const USDY_TOKEN_ABI = parseAbi([
  "function paused() view returns (bool)",
  "function blocklist() view returns (address)",
  "function allowlist() view returns (address)",
  "function sanctionsList() view returns (address)",
]);
const USDY_LIST_ABI = parseAbi([
  "function isBlocked(address account) view returns (bool)",
  "function isAllowed(address account) view returns (bool)",
  "function isSanctioned(address account) view returns (bool)",
]);
const ONDO_GM_TOKEN_ABI = parseAbi([
  "function compliance() view returns (address)",
  "function tokenPauseManager() view returns (address)",
]);
const ONDO_GM_VIEW_ABI = parseAbi([
  "function compliance() view returns (address)",
  "function gmIdentifier() view returns (address)",
]);
const ONDO_COMPLIANCE_ABI = parseAbi([
  "function rwaTokenToBlocklist(address identifier) view returns (address)",
  "function rwaTokenToSanctionsList(address identifier) view returns (address)",
]);
const ONDO_PAUSE_MANAGER_ABI = parseAbi(["function isTokenPaused(address token) view returns (bool)"]);

const DVP_REGISTRY_GETTERS = Object.freeze({
  participant: "participantRegistry",
  assetVersion: "assetVersionRegistry",
  eligibility: "eligibilityRegistry",
  fee: "feeRegistry",
  marketRule: "marketRuleRegistry",
  settlementToken: "settlementTokenRegistry",
  adapter: "adapterRegistry",
  calculator: "principalCalculatorRegistry",
});

function usage() {
  return `node scripts/ops/deploy-platform.mjs [options]

选项：
  --config <path>     JSON 配置（见 deploy/ops-platform.example.json）
                      assetAdapters.usdyRestricted = { token, blocklist?, allowlist?, sanctionsList?, providerCallGas? }
                      assetAdapters.ondoGm          = { token: 合约族参考 token, providerCallGas? }
                      assetAdapters.erc1404        = { token, providerCallGas? }
                      不写或写 null 表示不部署；USDY 名单不写时从代币读取，写了必须与当前值一致；providerCallGas 默认 100000
                      Ethereum 主网必须配置 USDY + Ondo GM；HSK 主网/测试网只允许 USDY
  --rpc <url>         RPC，也可用 HTP_RPC_URL；禁止写入配置文件
  --state <path>      状态文件，默认 tmp/out/platform-state.<chainId>.json
  --out <path>        部署报告，默认 tmp/out/platform-deployment.json
  --artifacts <dir>   编译产物目录，默认 contracts/out（指定后不会自动 forge build）
  --until <stepId>    执行到该步骤（含）后停止
  --from <stepId>     清掉该步骤及之后的完成记录，从这里强制重跑
  --status            只打印进度，不发交易，不需要私钥
  --verify            步骤全部完成后，只做校验并重写报告
  --summarize <path>  从已有的完整报告生成精简版（不连链、不需要私钥）
  --self-test         在 127.0.0.1 拉起 Anvil，跑完整部署 + 续跑验收

环境变量：HTP_DEPLOYER_KEY（必填）、HTP_GOVERNANCE_KEY、HTP_CONFIGURER_KEY
          会自动读取 tmp/.env（模板见 .env.example），shell 里设置的同名变量优先
`;
}

const KNOWN_FLAGS = new Set([
  "config",
  "rpc",
  "state",
  "out",
  "artifacts",
  "until",
  "from",
  "status",
  "verify",
  "summarize",
  "self-test",
  "help",
]);

function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) throw new Error(`未知参数: ${token}`);
    const key = token.slice(2);
    if (!KNOWN_FLAGS.has(key)) throw new Error(`未知选项: --${key}\n\n${usage()}`);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      flags[key] = true;
    } else {
      flags[key] = next;
      i += 1;
    }
  }
  return flags;
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function jsonSafe(value) {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, nested]) => [key, jsonSafe(nested)]));
  }
  return value;
}

function assertObjectKeys(value, label, allowedKeys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} 必须是对象`);
  for (const key of Object.keys(value)) {
    if (!allowedKeys.includes(key)) throw new Error(`${label} 包含未知字段: ${key}`);
  }
  return value;
}

function requireAddress(value, label) {
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new Error(`${label} 不是合法地址: ${value}`);
  }
  const address = getAddress(value);
  if (address === zeroAddress) throw new Error(`${label} 不能是零地址`);
  return address;
}

function optionalAddress(value, label) {
  if (value === undefined || value === null || value === "") return null;
  return requireAddress(value, label);
}

function requireBytes32(value, label) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/u.test(value)) {
    throw new Error(`${label} 必须是 0x + 64 位十六进制`);
  }
  if (/^0x0{64}$/u.test(value)) throw new Error(`${label} 不能为全 0`);
  return value.toLowerCase();
}

function optionalUnix(value, label) {
  if (value === undefined || value === null || value === "") return null;
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${label} 必须是正整数 unix 秒`);
  return value;
}

function requireBps(value, label) {
  if (!Number.isInteger(value) || value < 0 || value > 10_000) throw new Error(`${label} 必须是 0-10000 的整数`);
  return value;
}

function requireBoolean(value, label) {
  if (typeof value !== "boolean") throw new Error(`${label} 必须是 boolean`);
  return value;
}

function requireUint(value, label) {
  if (value === undefined || value === null || value === "") return 0n;
  if (typeof value !== "string" || !/^(0|[1-9]\d*)$/u.test(value)) {
    throw new Error(`${label} 必须是不含前导零的非负十进制字符串`);
  }
  const amount = BigInt(value);
  if (amount > UINT256_MAX) throw new Error(`${label} 超出 uint256`);
  return amount;
}

function parseEnumName(table, value, label, fallback) {
  if (value === undefined || value === null || value === "") {
    if (fallback === undefined) throw new Error(`缺少 ${label}`);
    return fallback;
  }
  const name = String(value).toUpperCase();
  if (!(name in table) || name === "NONE") throw new Error(`${label} 取值非法: ${value}`);
  return table[name];
}

function requireProviderCallGas(value, label) {
  if (value === undefined || value === null || value === "") return ADAPTER_PROVIDER_CALL_GAS_MAX;
  if (!Number.isSafeInteger(value) || value <= 0 || value > ADAPTER_PROVIDER_CALL_GAS_MAX) {
    throw new Error(`${label} 必须是 1-${ADAPTER_PROVIDER_CALL_GAS_MAX} 的整数`);
  }
  return value;
}

function normalizeAssetAdapters(raw) {
  const adapters = { usdyRestricted: null, ondoGm: null, erc1404: null };
  if (raw === undefined || raw === null) return adapters;
  assertObjectKeys(raw, "assetAdapters", RESTRICTED_ADAPTER_KEYS);

  const usdy = raw.usdyRestricted;
  if (usdy !== undefined && usdy !== null) {
    const label = "assetAdapters.usdyRestricted";
    assertObjectKeys(usdy, label, ["token", ...USDY_LIST_NAMES, "providerCallGas"]);
    adapters.usdyRestricted = {
      token: requireAddress(usdy.token, `${label}.token`),
      ...Object.fromEntries(USDY_LIST_NAMES.map((name) => [name, optionalAddress(usdy[name], `${label}.${name}`)])),
      providerCallGas: requireProviderCallGas(usdy.providerCallGas, `${label}.providerCallGas`),
    };
  }

  const ondoGm = raw.ondoGm;
  if (ondoGm !== undefined && ondoGm !== null) {
    const label = "assetAdapters.ondoGm";
    assertObjectKeys(ondoGm, label, ["token", "providerCallGas"]);
    adapters.ondoGm = {
      token: requireAddress(ondoGm.token, `${label}.token`),
      providerCallGas: requireProviderCallGas(ondoGm.providerCallGas, `${label}.providerCallGas`),
    };
  }

  const erc1404 = raw.erc1404;
  if (erc1404 !== undefined && erc1404 !== null) {
    assertObjectKeys(erc1404, "assetAdapters.erc1404", ["token", "providerCallGas"]);
    adapters.erc1404 = {
      token: requireAddress(erc1404.token, "assetAdapters.erc1404.token"),
      providerCallGas: requireProviderCallGas(erc1404.providerCallGas, "assetAdapters.erc1404.providerCallGas"),
    };
  }
  return adapters;
}

function enabledAdapterKeys(config) {
  return ["unrestricted", ...RESTRICTED_ADAPTER_KEYS.filter((key) => config.assetAdapters[key])];
}

function assertChainDeploymentProfile(chainId, calculators, adapters) {
  if (chainId === 1) {
    if (!adapters.usdyRestricted || !adapters.ondoGm) {
      throw new Error("Ethereum 主网部署必须同时配置 assetAdapters.usdyRestricted 和 assetAdapters.ondoGm");
    }
    if (!calculators.includes("FUND") || !calculators.includes("STOCK")) {
      throw new Error("Ethereum 主网部署必须同时包含 FUND 和 STOCK calculator");
    }
  } else if (HSK_CHAIN_IDS.has(chainId)) {
    if (!adapters.usdyRestricted) {
      throw new Error("HSK 部署必须配置 assetAdapters.usdyRestricted");
    }
    if (adapters.ondoGm || adapters.erc1404) {
      throw new Error("HSK 部署只允许 USDY 受限资产 Adapter，不允许 Ondo GM 或 ERC1404 Adapter");
    }
    if (!calculators.includes("FUND")) {
      throw new Error("HSK 部署 USDY 必须包含 FUND calculator");
    }
  }
}

function assertNoSecrets(value, path = "config") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoSecrets(item, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, nested] of Object.entries(value)) {
    if (/private|secret|mnemonic|seed/iu.test(key)) {
      throw new Error(`配置文件不允许包含私钥类字段 ${path}.${key}；私钥请用环境变量传入`);
    }
    if (/rpc|url/iu.test(key)) {
      throw new Error(`配置文件不允许包含 RPC 字段 ${path}.${key}；RPC 请用 HTP_RPC_URL 或 --rpc 传入`);
    }
    assertNoSecrets(nested, `${path}.${key}`);
  }
}

function assertRpcUrl(rpcUrl) {
  if (!/^https?:\/\/127\.0\.0\.1(?::\d+)?(?:\/|$)/u.test(rpcUrl) && !/^https:\/\//u.test(rpcUrl)) {
    throw new Error("RPC 只允许 https 公网端点或 http://127.0.0.1");
  }
}

export function normalizeConfig(raw) {
  assertNoSecrets(raw);
  assertObjectKeys(raw, "config", [
    "expectedChainId",
    "finalityConfirmations",
    "deploymentVersion",
    "evidenceHash",
    "roles",
    "settlementToken",
    "calculators",
    "assetAdapters",
    "feeEpoch",
    "globalFee",
  ]);

  const deploymentVersion = String(raw.deploymentVersion ?? "");
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u.test(deploymentVersion)) {
    throw new Error(`deploymentVersion 必须是 major.minor.patch 且各段无前导 0: "${deploymentVersion}"`);
  }

  const rolesRaw = assertObjectKeys(raw.roles, "roles", [
    "defaultAdmin",
    "governance",
    "upgrader",
    "pauser",
    "executor",
    "configurer",
  ]);
  const roles = {};
  for (const name of ["defaultAdmin", "governance", "upgrader", "pauser", "executor", "configurer"]) {
    roles[name] = requireAddress(rolesRaw[name], `roles.${name}`);
  }

  const tokenRaw = assertObjectKeys(raw.settlementToken, "settlementToken", [
    "address",
    "decimals",
    "permitCapability",
    "deploymentKind",
    "implementation",
  ]);
  const deploymentKind = parseEnumName(
    Enum.TokenDeploymentKind,
    tokenRaw.deploymentKind,
    "settlementToken.deploymentKind",
  );
  const settlementToken = {
    address: requireAddress(tokenRaw.address, "settlementToken.address"),
    decimals: tokenRaw.decimals === undefined || tokenRaw.decimals === null ? null : tokenRaw.decimals,
    permitCapability: parseEnumName(
      Enum.PermitCapability,
      tokenRaw.permitCapability,
      "settlementToken.permitCapability",
      Enum.PermitCapability.UNSUPPORTED,
    ),
    deploymentKind,
    implementation: optionalAddress(tokenRaw.implementation, "settlementToken.implementation"),
  };
  if (
    settlementToken.decimals !== null
    && !(Number.isInteger(settlementToken.decimals) && settlementToken.decimals >= 1 && settlementToken.decimals <= 36)
  ) {
    throw new Error("settlementToken.decimals 必须是 1-36 的整数");
  }
  if (deploymentKind === Enum.TokenDeploymentKind.DIRECT && settlementToken.implementation) {
    throw new Error("settlementToken.deploymentKind 为 DIRECT 时 implementation 必须为空");
  }
  if (deploymentKind === Enum.TokenDeploymentKind.ERC1967_PROXY && !settlementToken.implementation) {
    throw new Error("settlementToken.deploymentKind 为 ERC1967_PROXY 时必须显式提供 implementation");
  }

  const calculatorsRaw = raw.calculators ?? ["FUND"];
  if (!Array.isArray(calculatorsRaw)) throw new Error("calculators 必须是数组");
  const calculators = [...new Set(calculatorsRaw.map((item) => String(item).toUpperCase()))];
  if (calculators.length === 0) throw new Error("calculators 至少要有一项");
  for (const name of calculators) {
    if (!(name in CALCULATOR_SPECS)) throw new Error(`calculators 只能是 STOCK / FUND / BOND: ${name}`);
  }
  calculators.sort((a, b) => CALCULATOR_SPECS[a].assetClass - CALCULATOR_SPECS[b].assetClass);

  const epochRaw =
    raw.feeEpoch === undefined
      ? {}
      : assertObjectKeys(raw.feeEpoch, "feeEpoch", ["quoteValidFrom", "quoteValidUntil", "settlementValidUntil"]);
  const feeEpoch = {
    quoteValidFrom: optionalUnix(epochRaw.quoteValidFrom, "feeEpoch.quoteValidFrom"),
    quoteValidUntil: optionalUnix(epochRaw.quoteValidUntil, "feeEpoch.quoteValidUntil"),
    settlementValidUntil: optionalUnix(epochRaw.settlementValidUntil, "feeEpoch.settlementValidUntil"),
  };

  const feeRaw = assertObjectKeys(raw.globalFee, "globalFee", [
    "investorRateBps",
    "investorHasCap",
    "investorCapAmount",
    "makerRateBps",
    "makerHasCap",
    "makerCapAmount",
    "collector",
    "validFrom",
    "validUntil",
  ]);
  const globalFee = {
    investorRateBps: requireBps(feeRaw.investorRateBps, "globalFee.investorRateBps"),
    investorHasCap: requireBoolean(feeRaw.investorHasCap, "globalFee.investorHasCap"),
    investorCapAmount: requireUint(feeRaw.investorCapAmount, "globalFee.investorCapAmount"),
    makerRateBps: requireBps(feeRaw.makerRateBps, "globalFee.makerRateBps"),
    makerHasCap: requireBoolean(feeRaw.makerHasCap, "globalFee.makerHasCap"),
    makerCapAmount: requireUint(feeRaw.makerCapAmount, "globalFee.makerCapAmount"),
    collector: requireAddress(feeRaw.collector, "globalFee.collector"),
    validFrom: optionalUnix(feeRaw.validFrom, "globalFee.validFrom"),
    validUntil: optionalUnix(feeRaw.validUntil, "globalFee.validUntil"),
  };
  const worstCase = 2 * Math.max(globalFee.investorRateBps, globalFee.makerRateBps);
  if (worstCase > MAX_AGGREGATE_FEE_BPS) {
    throw new Error(
      `费率超上限：2 × max(investor, maker) = ${worstCase} bps > ${MAX_AGGREGATE_FEE_BPS} bps，单边费率最多 500 bps`,
    );
  }
  if (!globalFee.investorHasCap && globalFee.investorCapAmount !== 0n) {
    throw new Error("globalFee.investorHasCap 为 false 时 investorCapAmount 必须为 0");
  }
  if (!globalFee.makerHasCap && globalFee.makerCapAmount !== 0n) {
    throw new Error("globalFee.makerHasCap 为 false 时 makerCapAmount 必须为 0");
  }

  const expectedChainId = raw.expectedChainId;
  if (!Number.isSafeInteger(expectedChainId) || expectedChainId <= 0) {
    throw new Error("expectedChainId 必须是正整数");
  }
  const finalityConfirmations = raw.finalityConfirmations;
  if (!Number.isSafeInteger(finalityConfirmations) || finalityConfirmations <= 0) {
    throw new Error("finalityConfirmations 必须是正整数");
  }
  const assetAdapters = normalizeAssetAdapters(raw.assetAdapters);
  assertChainDeploymentProfile(expectedChainId, calculators, assetAdapters);

  return {
    expectedChainId,
    finalityConfirmations,
    deploymentVersion,
    evidenceHash: requireBytes32(raw.evidenceHash, "evidenceHash"),
    roles,
    settlementToken,
    calculators,
    assetAdapters,
    feeEpoch,
    globalFee,
  };
}

function configFingerprint(config) {
  return keccak256(stringToHex(JSON.stringify(jsonSafe(config))));
}

function asPrivateKey(value, label) {
  if (value === undefined || value === null || value === "") return null;
  const key = value.startsWith("0x") ? value : `0x${value}`;
  if (!/^0x[0-9a-fA-F]{64}$/u.test(key)) throw new Error(`${label} 必须是 32 字节 hex 私钥`);
  return key;
}

function loadSigners(config, keys) {
  const deployerKey = asPrivateKey(keys.deployer, "HTP_DEPLOYER_KEY");
  if (!deployerKey) throw new Error("必须设置环境变量 HTP_DEPLOYER_KEY");
  const deployer = privateKeyToAccount(deployerKey);

  const resolveRole = (roleName, envName, rawKey) => {
    const expected = config.roles[roleName];
    const key = asPrivateKey(rawKey, envName);
    if (key) {
      const account = privateKeyToAccount(key);
      if (account.address !== expected) {
        throw new Error(`${envName} 对应地址 ${account.address} 与 roles.${roleName} (${expected}) 不一致`);
      }
      return account;
    }
    if (expected === deployer.address) return deployer;
    return null;
  };

  return {
    deployer,
    governance: resolveRole("governance", "HTP_GOVERNANCE_KEY", keys.governance),
    configurer: resolveRole("configurer", "HTP_CONFIGURER_KEY", keys.configurer),
  };
}

// ---------------------------------------------------------------------------
// 编译产物
// ---------------------------------------------------------------------------

const artifactCache = new Map();
let defaultBuildReady = false;

const ARTIFACT_SOURCE_FILES = Object.freeze({
  PipelineCashToken: "UsdyOperatorPipeline.s.sol",
  UsdyTokenMock: "AdapterMocks.sol",
  AddressListMock: "AdapterMocks.sol",
  ERC1404TokenMock: "AdapterMocks.sol",
  OndoGmListMock: "OndoGmMocks.sol",
  OndoGmPauseManagerMock: "OndoGmMocks.sol",
  OndoComplianceMock: "OndoGmMocks.sol",
  OndoComplianceViewMock: "OndoGmMocks.sol",
  IntegrationOndoGmToken: "OndoGmMocks.sol",
});

function artifactPath(contractName) {
  const file = ARTIFACT_SOURCE_FILES[contractName] ?? `${contractName}.sol`;
  return join(outRoot, file, `${contractName}.json`);
}

function loadArtifact(contractName) {
  if (artifactCache.has(contractName)) return artifactCache.get(contractName);
  const path = artifactPath(contractName);
  if (!existsSync(path)) throw new Error(`缺少编译产物 ${path}，请先执行 forge build --root contracts`);
  const json = readJson(path);
  const bytecode = typeof json.bytecode === "string" ? json.bytecode : json.bytecode?.object;
  if (!bytecode || bytecode === "0x") throw new Error(`${contractName} bytecode 为空`);
  if (Object.keys(json.bytecode?.linkReferences ?? {}).length > 0) throw new Error(`${contractName} 仍有未链接 library`);
  const artifact = { abi: json.abi, bytecode };
  artifactCache.set(contractName, artifact);
  return artifact;
}

function ensureBuild(extra = []) {
  const required = [
    "ERC1967Proxy",
    "DvPSettlement",
    "DvPCurrentStateValidatorFactory",
    ...Object.values(ADAPTER_SPECS).map((spec) => spec.contract),
    ...REGISTRY_SPECS.map((spec) => spec.contract),
    ...Object.values(CALCULATOR_SPECS).map((spec) => spec.contract),
    ...extra,
  ];
  const missing = required.filter((name) => !existsSync(artifactPath(name)));
  if (outRoot !== defaultOutRoot) {
    if (missing.length > 0) throw new Error(`--artifacts ${outRoot} 缺少编译产物: ${missing.join(", ")}`);
    return;
  }
  if (defaultBuildReady && missing.length === 0) return;
  console.log("编译合约（forge build --root contracts）...");
  const result = spawnSync("forge", ["build", "--root", contractsRoot], { cwd: repoRoot, stdio: "inherit" });
  if (result.status !== 0) throw new Error("forge build 失败");
  artifactCache.clear();
  defaultBuildReady = true;
}

// ---------------------------------------------------------------------------
// 状态文件
// ---------------------------------------------------------------------------

function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(jsonSafe(value), null, 2)}\n`);
  renameSync(tmp, path);
}

function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function acquireLock(statePath) {
  const lockPath = `${statePath}.lock`;
  mkdirSync(dirname(lockPath), { recursive: true });
  if (existsSync(lockPath)) {
    const pid = Number(readFileSync(lockPath, "utf8").trim());
    if (Number.isInteger(pid) && pid > 0 && processAlive(pid)) {
      throw new Error(`另一个部署进程（pid ${pid}）正在使用 ${statePath}`);
    }
    unlinkSync(lockPath);
  }
  const fd = openSync(lockPath, "wx");
  writeSync(fd, String(process.pid));
  closeSync(fd);
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    try {
      unlinkSync(lockPath);
    } catch {
      // 已被删除
    }
  };
  const onSignal = (signal) => {
    release();
    process.exit(signal === "SIGINT" ? 130 : 143);
  };
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  return () => {
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
    release();
  };
}

function loadState(statePath, fingerprint) {
  if (!existsSync(statePath)) {
    return { version: STATE_VERSION, fingerprint, createdAt: new Date().toISOString(), resolved: null, configHashes: {}, steps: {} };
  }
  const state = readJson(statePath);
  if (state.version !== STATE_VERSION) throw new Error(`状态文件版本 ${state.version} 不受支持`);
  const mismatches = Object.keys(fingerprint).filter((key) => state.fingerprint?.[key] !== fingerprint[key]);
  if (mismatches.length > 0) {
    const detail = mismatches.map((key) => `  ${key}: 状态文件=${state.fingerprint?.[key]} 当前=${fingerprint[key]}`).join("\n");
    throw new Error(
      `状态文件 ${statePath} 与本次运行不匹配，拒绝续跑：\n${detail}\n` +
        "如果确实要开始一套全新部署，请换一个 --state 路径。",
    );
  }
  state.configHashes ??= {};
  state.steps ??= {};
  return state;
}

// ---------------------------------------------------------------------------
// 链上读取与配置计算
// ---------------------------------------------------------------------------

function stringifyArgs(args) {
  return JSON.stringify(args, (_, value) => (typeof value === "bigint" ? value.toString() : value));
}

function formatTxError(error, abi) {
  const decoded =
    typeof error?.walk === "function" ? error.walk((item) => (item?.data?.errorName ? item : null)) : null;
  if (decoded?.data?.errorName) {
    const { errorName, args } = decoded.data;
    return args === undefined ? errorName : `${errorName} ${stringifyArgs(args)}`;
  }
  if (abi && typeof error?.walk === "function") {
    const raw = error.walk((item) => typeof item?.data === "string" && /^0x[0-9a-fA-F]{8,}$/u.test(item.data));
    if (raw) {
      try {
        const { errorName, args } = decodeErrorResult({ abi, data: raw.data });
        return args === undefined ? errorName : `${errorName} ${stringifyArgs(args)}`;
      } catch {
        // abi 里没有这个错误，退回原始信息
      }
    }
  }
  return safeErrorMessage(error);
}

async function codeHashOf(publicClient, address) {
  const code = await publicClient.getCode({ address });
  if (!code || code === "0x") throw new Error(`${address} 没有合约代码`);
  return keccak256(code);
}

async function hasCode(publicClient, address) {
  const code = await publicClient.getCode({ address });
  return Boolean(code && code !== "0x");
}

async function readSlotAddress(publicClient, address, slot) {
  const word = await publicClient.getStorageAt({ address, slot });
  if (!word || word === "0x") return zeroAddress;
  return getAddress(`0x${word.slice(-40)}`);
}

async function detectTokenDeployment(publicClient, token, meta) {
  const tokenCodeHash = await codeHashOf(publicClient, token);
  if (meta.deploymentKind === Enum.TokenDeploymentKind.DIRECT) {
    return { kind: Enum.TokenDeploymentKind.DIRECT, tokenCodeHash, implementation: ZERO_ADDRESS, implementationCodeHash: ZERO_BYTES32 };
  }
  const implementation = await readSlotAddress(publicClient, token, ERC1967_IMPLEMENTATION_SLOT);
  if (implementation !== meta.implementation) {
    throw new Error(
      `settlementToken.implementation=${meta.implementation} 与 ERC-1967 implementation slot=${implementation} 不一致`,
    );
  }
  return {
    kind: Enum.TokenDeploymentKind.ERC1967_PROXY,
    tokenCodeHash,
    implementation,
    implementationCodeHash: await codeHashOf(publicClient, implementation),
  };
}

function stepAddress(ctx, id) {
  const entry = ctx.state.steps[id];
  if (!entry || entry.status !== "done" || !entry.address) throw new Error(`步骤 ${id} 尚未完成，拿不到地址`);
  return getAddress(entry.address);
}

const addr = {
  registryImpl: (ctx, key) => stepAddress(ctx, `registry.${key}.impl`),
  registry: (ctx, key) => stepAddress(ctx, `registry.${key}.proxy`),
  factory: (ctx) => stepAddress(ctx, "core.factory"),
  dvp: (ctx) => stepAddress(ctx, "core.dvp"),
  adapter: (ctx, key) => stepAddress(ctx, `component.${ADAPTER_SPECS[key].stateKey}`),
  calculator: (ctx, name) => stepAddress(ctx, `component.calculator.${name}`),
};

function registryAbi(key) {
  return loadArtifact(REGISTRY_SPECS.find((spec) => spec.key === key).contract).abi;
}

function readRegistry(ctx, key, functionName, args) {
  return ctx.publicClient.readContract({ address: addr.registry(ctx, key), abi: registryAbi(key), functionName, args });
}

function pinConfigHash(ctx, name, configHash) {
  const pinned = ctx.state.configHashes[name];
  if (pinned && pinned !== configHash) {
    throw new Error(
      `${name} 的 configHash 与上次运行不一致（上次 ${pinned}，本次 ${configHash}），链上对象可能已变化，停止执行`,
    );
  }
  if (!pinned) {
    ctx.state.configHashes[name] = configHash;
    ctx.saveState();
  }
}

async function cached(ctx, name, build) {
  if (!ctx.cache.has(name)) ctx.cache.set(name, await build());
  return ctx.cache.get(name);
}

function compareProviders(left, right) {
  const byAddress = BigInt(left.provider) - BigInt(right.provider);
  if (byAddress !== 0n) return byAddress < 0n ? -1 : 1;
  const bySelector = Number.parseInt(left.selector.slice(2), 16) - Number.parseInt(right.selector.slice(2), 16);
  if (bySelector !== 0) return bySelector;
  const byCodeHash = BigInt(left.codeHash) - BigInt(right.codeHash);
  return byCodeHash === 0n ? 0 : byCodeHash < 0n ? -1 : 1;
}

/** 与 RestrictionProviderLib.canonicalHash 一致：按 (provider, selector, codeHash) 升序后做 EIP-712 式哈希。 */
function restrictionProviderSetHash(providers) {
  const hashes = [...providers].sort(compareProviders).map((item) =>
    keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "address" }, { type: "bytes4" }, { type: "bytes32" }],
        [RESTRICTION_PROVIDER_TYPEHASH, item.provider, item.selector, item.codeHash],
      ),
    ),
  );
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [RESTRICTION_PROVIDER_SET_TYPEHASH, keccak256(concat(hashes))]),
  );
}

/**
 * 受限适配器要写死的外部依赖（按链上当前状态读取），以及据此算出的期望 providerHash。
 * spec: { token, providerCallGas, blocklist?, allowlist?, sanctionsList? }；名单字段只在 usdyRestricted 下使用。
 */
export async function readRestrictedBinding(publicClient, key, spec, label = key) {
  const token = spec.token;
  if (!(await hasCode(publicClient, token))) throw new Error(`${label}.token ${token} 在当前链上没有代码`);
  const tokenCodeHash = await codeHashOf(publicClient, token);

  if (key === "erc1404") {
    const providers = [{ provider: token, selector: PROVIDER_SELECTOR.detectTransferRestriction, codeHash: tokenCodeHash }];
    return { token, tokenCodeHash, providerCallGas: spec.providerCallGas, providerHash: restrictionProviderSetHash(providers) };
  }

  if (key === "ondoGm") {
    const readAddress = async (address, abi, functionName, args = []) => {
      try {
        const value = getAddress(await publicClient.readContract({ address, abi, functionName, args }));
        if (value === zeroAddress || !(await hasCode(publicClient, value))) {
          throw new Error(`${functionName}() 返回零地址或无代码地址 ${value}`);
        }
        return value;
      } catch (error) {
        throw new Error(`${label} 读取 ${functionName}() 失败：${safeErrorMessage(error)}`);
      }
    };
    const complianceView = await readAddress(token, ONDO_GM_TOKEN_ABI, "compliance");
    const pauseManager = await readAddress(token, ONDO_GM_TOKEN_ABI, "tokenPauseManager");
    const compliance = await readAddress(complianceView, ONDO_GM_VIEW_ABI, "compliance");
    const gmIdentifier = getAddress(
      await publicClient.readContract({ address: complianceView, abi: ONDO_GM_VIEW_ABI, functionName: "gmIdentifier" }),
    );
    if (gmIdentifier !== ONDO_GM_IDENTIFIER) {
      throw new Error(`${label} gmIdentifier=${gmIdentifier}，预期 ${ONDO_GM_IDENTIFIER}`);
    }
    const blocklist = await readAddress(compliance, ONDO_COMPLIANCE_ABI, "rwaTokenToBlocklist", [gmIdentifier]);
    const sanctionsList = await readAddress(compliance, ONDO_COMPLIANCE_ABI, "rwaTokenToSanctionsList", [gmIdentifier]);
    const [complianceViewCodeHash, complianceCodeHash, pauseManagerCodeHash, blocklistCodeHash, sanctionsListCodeHash] =
      await Promise.all(
        [complianceView, compliance, pauseManager, blocklist, sanctionsList].map((address) =>
          codeHashOf(publicClient, address),
        ),
      );
    const tokenProvider = (selector) => ({ provider: token, selector, codeHash: tokenCodeHash });
    const providers = [
      tokenProvider(PROVIDER_SELECTOR.compliance),
      tokenProvider(PROVIDER_SELECTOR.tokenPauseManager),
      { provider: complianceView, selector: PROVIDER_SELECTOR.compliance, codeHash: complianceViewCodeHash },
      { provider: complianceView, selector: PROVIDER_SELECTOR.gmIdentifier, codeHash: complianceViewCodeHash },
      { provider: compliance, selector: PROVIDER_SELECTOR.rwaTokenToBlocklist, codeHash: complianceCodeHash },
      { provider: compliance, selector: PROVIDER_SELECTOR.rwaTokenToSanctionsList, codeHash: complianceCodeHash },
      { provider: pauseManager, selector: PROVIDER_SELECTOR.isTokenPaused, codeHash: pauseManagerCodeHash },
      { provider: blocklist, selector: PROVIDER_SELECTOR.isBlocked, codeHash: blocklistCodeHash },
      { provider: sanctionsList, selector: PROVIDER_SELECTOR.isSanctioned, codeHash: sanctionsListCodeHash },
    ];
    return {
      token,
      tokenCodeHash,
      complianceView,
      complianceViewCodeHash,
      compliance,
      complianceCodeHash,
      gmIdentifier,
      pauseManager,
      pauseManagerCodeHash,
      blocklist,
      blocklistCodeHash,
      sanctionsList,
      sanctionsListCodeHash,
      providerCallGas: spec.providerCallGas,
      providerHash: restrictionProviderSetHash(providers),
    };
  }

  const lists = {};
  for (const name of USDY_LIST_NAMES) {
    let onToken;
    try {
      onToken = getAddress(await publicClient.readContract({ address: token, abi: USDY_TOKEN_ABI, functionName: name }));
    } catch (error) {
      throw new Error(`${label}.token ${token} 读取 ${name}() 失败，它不像 USDY 类代币：${safeErrorMessage(error)}`);
    }
    if (onToken === zeroAddress) throw new Error(`${label}.token ${token} 的 ${name}() 返回零地址`);
    if (spec[name] && spec[name] !== onToken) {
      throw new Error(
        `${label}.${name}=${spec[name]} 与代币当前 ${name}()=${onToken} 不一致。` +
          "适配器会写死名单地址，不一致时所有 USDY 交易都会返回 PROVIDER_MISMATCH；请删掉该字段或改成代币当前值",
      );
    }
    if (!(await hasCode(publicClient, onToken))) throw new Error(`USDY ${name} ${onToken} 没有合约代码`);
    lists[name] = { address: onToken, codeHash: await codeHashOf(publicClient, onToken) };
  }
  const tokenProvider = (selector) => ({ provider: token, selector, codeHash: tokenCodeHash });
  const providers = [
    tokenProvider(PROVIDER_SELECTOR.paused),
    tokenProvider(PROVIDER_SELECTOR.blocklist),
    tokenProvider(PROVIDER_SELECTOR.allowlist),
    tokenProvider(PROVIDER_SELECTOR.sanctionsList),
    { provider: lists.blocklist.address, selector: PROVIDER_SELECTOR.isBlocked, codeHash: lists.blocklist.codeHash },
    { provider: lists.allowlist.address, selector: PROVIDER_SELECTOR.isAllowed, codeHash: lists.allowlist.codeHash },
    { provider: lists.sanctionsList.address, selector: PROVIDER_SELECTOR.isSanctioned, codeHash: lists.sanctionsList.codeHash },
  ];
  return {
    token,
    tokenCodeHash,
    blocklist: lists.blocklist.address,
    blocklistCodeHash: lists.blocklist.codeHash,
    allowlist: lists.allowlist.address,
    allowlistCodeHash: lists.allowlist.codeHash,
    sanctionsList: lists.sanctionsList.address,
    sanctionsListCodeHash: lists.sanctionsList.codeHash,
    providerCallGas: spec.providerCallGas,
    providerHash: restrictionProviderSetHash(providers),
  };
}

export function adapterConstructorArgs(key, dvp, binding) {
  if (key === "unrestricted") return [dvp];
  const gas = BigInt(binding.providerCallGas);
  if (key === "erc1404" || key === "ondoGm") return [dvp, binding.token, binding.tokenCodeHash, gas];
  return [
    dvp,
    binding.token,
    binding.tokenCodeHash,
    binding.blocklist,
    binding.blocklistCodeHash,
    binding.allowlist,
    binding.allowlistCodeHash,
    binding.sanctionsList,
    binding.sanctionsListCodeHash,
    gas,
  ];
}

export function assertProviderBinding(key, binding, config) {
  if (binding.providerHash !== config.providerHash) {
    throw new Error(
      `${ADAPTER_SPECS[key].contract} 的 providerHash（${config.providerHash}）与代币当前状态算出的（${binding.providerHash}）不一致：` +
        "代币或名单的地址/代码在适配器部署后变了，登记它只会让交易返回 PROVIDER_MISMATCH，已停止。" +
        "请确认代币状态后重新部署该适配器",
    );
  }
}

/** 从链上读取适配器自报的信息，拼出 AdapterConfig。revision / replacesId 由调用方按版本链决定。 */
export async function readAdapterConfig(publicClient, chainId, key, adapter, { revision, replacesId }) {
  const spec = ADAPTER_SPECS[key];
  const read = (functionName) => publicClient.readContract({ address: adapter, abi: ADAPTER_VIEW_ABI, functionName });
  const [interfaceVersion, rawCapabilities, capabilityHash, providerHash, codeHash] = await Promise.all([
    read("interfaceVersion"),
    read("capabilities"),
    read("capabilityHash"),
    read("providerHash"),
    codeHashOf(publicClient, adapter),
  ]);
  const capabilities = {
    tokenStandard: Number(rawCapabilities.tokenStandard),
    restrictionMode: Number(rawCapabilities.restrictionMode),
    precheckMethod: Number(rawCapabilities.precheckMethod),
    transferLegMask: BigInt(rawCapabilities.transferLegMask),
  };
  if (interfaceVersion !== InterfaceVersion.ASSET_ADAPTER_V1) throw new Error(`${spec.contract} interfaceVersion 不是 ASSET_ADAPTER_V1`);
  if (hashAdapterCapabilities(capabilities) !== capabilityHash) throw new Error(`${spec.contract} capabilityHash 与本地计算不一致`);
  if (capabilities.tokenStandard !== spec.tokenStandard || capabilities.restrictionMode !== spec.restrictionMode) {
    throw new Error(
      `${spec.contract} 能力为 ${enumName(Enum.TokenStandard, capabilities.tokenStandard)} / ` +
        `${enumName(Enum.RestrictionMode, capabilities.restrictionMode)}，与预期不符`,
    );
  }
  const config = {
    schemaVersion: SCHEMA_VERSION,
    adapterConfigId: adapterConfigIdFor(chainId, capabilityHash, revision),
    revision,
    chainId,
    adapter,
    interfaceVersion,
    codeHash,
    capabilities,
    capabilityHash,
    providerHash,
    replacesId,
    configHash: ZERO_BYTES32,
  };
  config.configHash = hashAdapterConfig(config);
  return config;
}

export function adapterConfigIdFor(chainId, capabilityHash, revision) {
  return deriveConfigId(Namespace.ADAPTER, SCHEMA_VERSION, chainId, capabilityHash, revision);
}

/** USDY 代币暂停状态和 DvP 在三份名单里的状态；DvP 作为 preCheck 的调用方同样要过名单。 */
export async function readUsdyDvpState(publicClient, binding, dvp) {
  const readList = (address, functionName) =>
    publicClient.readContract({ address, abi: USDY_LIST_ABI, functionName, args: [dvp] }).catch(() => null);
  const [paused, dvpBlocked, dvpAllowed, dvpSanctioned] = await Promise.all([
    publicClient.readContract({ address: binding.token, abi: USDY_TOKEN_ABI, functionName: "paused" }).catch(() => null),
    readList(binding.blocklist, "isBlocked"),
    readList(binding.allowlist, "isAllowed"),
    readList(binding.sanctionsList, "isSanctioned"),
  ]);
  const warnings = [];
  if (dvpAllowed !== true) {
    warnings.push(`DvP ${dvp} 不在 USDY allowlist（${binding.allowlist}）中，USDY 交易会被 USDY_CALLER_NOT_ALLOWED 拦下；请让 USDY 名单管理员加入`);
  }
  if (dvpBlocked !== false) warnings.push(`DvP ${dvp} 在 USDY blocklist 中（或读取失败）`);
  if (dvpSanctioned !== false) warnings.push(`DvP ${dvp} 在 USDY 制裁名单中（或读取失败）`);
  if (paused !== false) warnings.push(`USDY 代币 ${binding.token} 处于暂停状态（或读取失败）`);
  return { tokenState: { paused, dvpBlocked, dvpAllowed, dvpSanctioned }, warnings };
}

export async function readOndoGmDvpState(publicClient, binding, dvp) {
  const [paused, dvpBlocked, dvpSanctioned] = await Promise.all([
    publicClient
      .readContract({
        address: binding.pauseManager,
        abi: ONDO_PAUSE_MANAGER_ABI,
        functionName: "isTokenPaused",
        args: [binding.token],
      })
      .catch(() => null),
    publicClient
      .readContract({ address: binding.blocklist, abi: USDY_LIST_ABI, functionName: "isBlocked", args: [dvp] })
      .catch(() => null),
    publicClient
      .readContract({
        address: binding.sanctionsList,
        abi: USDY_LIST_ABI,
        functionName: "isSanctioned",
        args: [dvp],
      })
      .catch(() => null),
  ]);
  const warnings = [];
  if (paused !== false) warnings.push(`Ondo GMToken ${binding.token} 处于暂停状态（或读取失败）`);
  if (dvpBlocked !== false) warnings.push(`DvP ${dvp} 在 Ondo GM blocklist 中（或读取失败）`);
  if (dvpSanctioned !== false) warnings.push(`DvP ${dvp} 在 Ondo GM 制裁名单中（或读取失败）`);
  return { tokenState: { paused, dvpBlocked, dvpSanctioned }, warnings };
}

function restrictedBinding(ctx, key) {
  return cached(ctx, `binding.${key}`, () =>
    readRestrictedBinding(ctx.publicClient, key, ctx.config.assetAdapters[key], `assetAdapters.${key}`),
  );
}

async function assertBindingCurrent(ctx, key) {
  const [binding, config] = await Promise.all([
    readRestrictedBinding(ctx.publicClient, key, ctx.config.assetAdapters[key], `assetAdapters.${key}`),
    adapterConfig(ctx, key),
  ]);
  assertProviderBinding(key, binding, config);
}

export async function assertMainnetOndoEvidence(ctx) {
  if (ctx.chainId !== 1 || !ctx.config.assetAdapters.ondoGm) return;
  const evidence = readJson(join(repoRoot, "schema/v1/vectors/adapters/ondo-gm-aaplon.json"));
  const referenceToken = getAddress(ctx.config.assetAdapters.ondoGm.token);
  if (getAddress(evidence.candidateAddresses?.token ?? ZERO_ADDRESS) !== referenceToken) {
    throw new Error(`Ondo GM 参考 token ${referenceToken} 与生产审批证据中的 token 不一致`);
  }
  await verifyOndoGmFixedBlock(ctx.publicClient, evidence);
  const current = await readRestrictedBinding(ctx.publicClient, "ondoGm", ctx.config.assetAdapters.ondoGm);
  if (current.providerHash.toLowerCase() !== String(evidence.providerHash).toLowerCase()) {
    throw new Error(
      `Ondo GM 当前 providerHash ${current.providerHash} 与生产审批证据 ${evidence.providerHash} 不一致`,
    );
  }
}

function adapterConfig(ctx, key) {
  const spec = ADAPTER_SPECS[key];
  return cached(ctx, spec.stateKey, async () => {
    let config = await readAdapterConfig(ctx.publicClient, ctx.chainId, key, addr.adapter(ctx, key), {
      revision: 1,
      replacesId: ZERO_BYTES32,
    });
    const keys = enabledAdapterKeys(ctx.config);
    for (const previousKey of keys.slice(0, keys.indexOf(key)).reverse()) {
      const previous = await adapterConfig(ctx, previousKey);
      if (previous.capabilityHash !== config.capabilityHash) continue;
      const revision = previous.revision + 1;
      config = {
        ...config,
        adapterConfigId: adapterConfigIdFor(ctx.chainId, config.capabilityHash, revision),
        revision,
        replacesId: previous.adapterConfigId,
        configHash: ZERO_BYTES32,
      };
      config.configHash = hashAdapterConfig(config);
      break;
    }
    pinConfigHash(ctx, spec.stateKey, config.configHash);
    return config;
  });
}

function calculatorConfig(ctx, name) {
  return cached(ctx, `calculator.${name}`, async () => {
    const calculator = addr.calculator(ctx, name);
    const [interfaceVersion, assetClass, codeHash] = await Promise.all([
      ctx.publicClient.readContract({ address: calculator, abi: CALCULATOR_VIEW_ABI, functionName: "interfaceVersion" }),
      ctx.publicClient.readContract({ address: calculator, abi: CALCULATOR_VIEW_ABI, functionName: "assetClass" }),
      codeHashOf(ctx.publicClient, calculator),
    ]);
    if (Number(assetClass) !== CALCULATOR_SPECS[name].assetClass) throw new Error(`${name} 计算器返回的 assetClass 不符`);
    if (interfaceVersion !== InterfaceVersion.PRINCIPAL_CALCULATOR_V1) throw new Error(`${name} 计算器 interfaceVersion 不符`);
    const config = {
      schemaVersion: SCHEMA_VERSION,
      calculatorConfigId: deriveConfigId(
        Namespace.PRINCIPAL_CALCULATOR,
        SCHEMA_VERSION,
        ctx.chainId,
        assetClassSubject(Number(assetClass)),
        1,
      ),
      revision: 1,
      chainId: ctx.chainId,
      assetClass: Number(assetClass),
      calculator,
      interfaceVersion,
      codeHash,
      replacesId: ZERO_BYTES32,
      configHash: ZERO_BYTES32,
    };
    config.configHash = hashPrincipalCalculatorConfig(config);
    pinConfigHash(ctx, `calculator.${name}`, config.configHash);
    return config;
  });
}

function settlementTokenConfig(ctx) {
  return cached(ctx, "settlementToken", async () => {
    const adapter = await adapterConfig(ctx, "unrestricted");
    const token = ctx.config.settlementToken;
    const deployment = await detectTokenDeployment(ctx.publicClient, token.address, token);
    const config = {
      schemaVersion: SCHEMA_VERSION,
      configId: deriveConfigId(Namespace.SETTLEMENT_TOKEN, SCHEMA_VERSION, ctx.chainId, tokenSubject(token.address), 1),
      revision: 1,
      chainId: ctx.chainId,
      settlementToken: token.address,
      tokenDeploymentKind: deployment.kind,
      settlementTokenDecimals: ctx.settlementDecimals,
      tokenCodeHash: deployment.tokenCodeHash,
      implementation: deployment.implementation,
      implementationCodeHash: deployment.implementationCodeHash,
      adapterConfigId: adapter.adapterConfigId,
      adapterConfigHash: adapter.configHash,
      permitCapability: token.permitCapability,
      replacesConfigId: ZERO_BYTES32,
      configHash: ZERO_BYTES32,
    };
    config.configHash = hashSettlementTokenConfig(config);
    pinConfigHash(ctx, "settlementToken", config.configHash);
    return config;
  });
}

function feeEpochConfig(ctx) {
  const { schedule } = ctx.state.resolved;
  const config = {
    schemaVersion: SCHEMA_VERSION,
    feePolicyEpoch: FEE_EPOCH,
    chainId: ctx.chainId,
    quoteValidFrom: schedule.quoteValidFrom,
    quoteValidUntil: schedule.quoteValidUntil,
    settlementValidUntil: schedule.settlementValidUntil,
    configHash: ZERO_BYTES32,
  };
  config.configHash = hashFeePolicyEpochConfig(config);
  return config;
}

function globalFeeConfig(ctx) {
  return cached(ctx, "globalFee", async () => {
    const settlement = await settlementTokenConfig(ctx);
    const fee = ctx.config.globalFee;
    const { feeValidity } = ctx.state.resolved;
    const scopeKeyHash = ZERO_BYTES32;
    const scopeHash = matchedScopeHash(FEE_EPOCH, Enum.ScopeType.GLOBAL, scopeKeyHash);
    const config = {
      schemaVersion: SCHEMA_VERSION,
      feeVersionId: deriveConfigId(Namespace.FEE, SCHEMA_VERSION, ctx.chainId, scopeHash, 1),
      revision: 1,
      chainId: ctx.chainId,
      feePolicyEpoch: FEE_EPOCH,
      scopeType: Enum.ScopeType.GLOBAL,
      scopeKeyHash,
      matchedScopeHash: scopeHash,
      investorRateBps: fee.investorRateBps,
      investorHasCap: fee.investorHasCap,
      investorCapAmount: fee.investorCapAmount,
      makerRateBps: fee.makerRateBps,
      makerHasCap: fee.makerHasCap,
      makerCapAmount: fee.makerCapAmount,
      roundingMode: Enum.RoundingMode.DOWN,
      settlementToken: settlement.settlementToken,
      settlementTokenConfigId: settlement.configId,
      settlementTokenConfigHash: settlement.configHash,
      collector: fee.collector,
      validFrom: feeValidity.validFrom,
      validUntil: feeValidity.validUntil,
      feeConstraintHash: ZERO_BYTES32,
      replacesFeeVersionId: ZERO_BYTES32,
      configHash: ZERO_BYTES32,
    };
    config.feeConstraintHash = hashFeeConstraint(config);
    config.configHash = hashFeeConfig(config);
    pinConfigHash(ctx, "globalFee", config.configHash);
    return config;
  });
}

function requireStoredHash(label, record, expectedHash) {
  if (record.config.configHash !== expectedHash) {
    throw new Error(`${label} 链上已存在同 ID 配置，但 configHash 不同（链上 ${record.config.configHash}，本地 ${expectedHash}）`);
  }
}

async function dependentDvps(ctx, key) {
  const address = addr.registry(ctx, key);
  const count = Number(await ctx.publicClient.readContract({ address, abi: DEPENDENT_ABI, functionName: "getDependentDvpCount" }));
  const items = [];
  for (let index = 0; index < count; index += 1) {
    const row = await ctx.publicClient.readContract({
      address,
      abi: DEPENDENT_ABI,
      functionName: "getDependentDvp",
      args: [BigInt(index)],
    });
    items.push(getAddress(row[0]));
  }
  return items;
}

// ---------------------------------------------------------------------------
// 步骤定义
// ---------------------------------------------------------------------------

function registryInitArgs(ctx, spec) {
  const { roles } = ctx.config;
  return [
    roles.defaultAdmin,
    roles.governance,
    roles.upgrader,
    roles.pauser,
    roles.configurer,
    ...spec.deps.map((dep) => addr.registry(ctx, dep)),
  ];
}

function buildSteps(config) {
  const steps = [];
  const deployStep = (id, phase, title, build, verify) =>
    steps.push({ id, phase, title, kind: "deploy", signer: "deployer", build, verify });
  const writeStep = (id, phase, title, signer, build, check) =>
    steps.push({ id, phase, title, kind: "write", signer, build, check });

  for (const spec of REGISTRY_SPECS) {
    deployStep(`registry.${spec.key}.impl`, "registries", `${spec.contract} 实现合约`, () => ({
      artifact: loadArtifact(spec.contract),
      args: [],
    }));
    deployStep(
      `registry.${spec.key}.proxy`,
      "registries",
      `${spec.contract} 代理 + initialize`,
      (ctx) => ({
        artifact: loadArtifact("ERC1967Proxy"),
        args: [
          addr.registryImpl(ctx, spec.key),
          encodeFunctionData({
            abi: loadArtifact(spec.contract).abi,
            functionName: "initialize",
            args: registryInitArgs(ctx, spec),
          }),
        ],
      }),
      async (ctx, address) => {
        const implementation = await readSlotAddress(ctx.publicClient, address, ERC1967_IMPLEMENTATION_SLOT);
        const expected = addr.registryImpl(ctx, spec.key);
        if (implementation !== expected) {
          throw new Error(`${spec.contract} 代理的 implementation 是 ${implementation}，状态文件记录的是 ${expected}`);
        }
      },
    );
  }

  deployStep("core.factory", "core", "DvPCurrentStateValidatorFactory", () => ({
    artifact: loadArtifact("DvPCurrentStateValidatorFactory"),
    args: [],
  }));
  deployStep("core.dvp", "core", "DvPSettlement", (ctx) => {
    const { roles } = ctx.config;
    return {
      artifact: loadArtifact("DvPSettlement"),
      args: [
        { defaultAdmin: roles.defaultAdmin, governance: roles.governance, pauser: roles.pauser, executor: roles.executor },
        {
          participant: addr.registry(ctx, "participant"),
          assetVersion: addr.registry(ctx, "assetVersion"),
          eligibility: addr.registry(ctx, "eligibility"),
          fee: addr.registry(ctx, "fee"),
          marketRule: addr.registry(ctx, "marketRule"),
          settlementToken: addr.registry(ctx, "settlementToken"),
          adapter: addr.registry(ctx, "adapter"),
          principalCalculator: addr.registry(ctx, "calculator"),
        },
        BigInt(ctx.chainId),
        stringToHex(ctx.config.deploymentVersion),
        addr.factory(ctx),
      ],
    };
  });

  for (const spec of REGISTRY_SPECS) {
    writeStep(
      `bind.${spec.key}`,
      "bindDvp",
      `${spec.contract}.registerDependentDvp`,
      "governance",
      (ctx) => ({
        address: addr.registry(ctx, spec.key),
        abi: registryAbi(spec.key),
        functionName: "registerDependentDvp",
        args: [addr.dvp(ctx), ctx.config.evidenceHash],
      }),
      async (ctx) => (await dependentDvps(ctx, spec.key)).includes(addr.dvp(ctx)),
    );
  }

  const adapterKeys = enabledAdapterKeys(config);
  for (const key of adapterKeys) {
    const spec = ADAPTER_SPECS[key];
    deployStep(`component.${spec.stateKey}`, "components", `${spec.contract}（${spec.label}）`, async (ctx) => ({
      artifact: loadArtifact(spec.contract),
      args: adapterConstructorArgs(key, addr.dvp(ctx), key === "unrestricted" ? null : await restrictedBinding(ctx, key)),
    }));
  }
  for (const name of config.calculators) {
    deployStep(`component.calculator.${name}`, "components", CALCULATOR_SPECS[name].contract, () => ({
      artifact: loadArtifact(CALCULATOR_SPECS[name].contract),
      args: [],
    }));
  }

  for (const key of adapterKeys) {
    const spec = ADAPTER_SPECS[key];
    writeStep(
      `config.${spec.stateKey}.register`,
      "configs",
      `registerAdapter（${spec.label}）`,
      "configurer",
      async (ctx) => {
        if (key !== "unrestricted") await assertBindingCurrent(ctx, key);
        return {
          address: addr.registry(ctx, "adapter"),
          abi: registryAbi("adapter"),
          functionName: "registerAdapter",
          args: [await adapterConfig(ctx, key)],
        };
      },
      async (ctx) => {
        const config = await adapterConfig(ctx, key);
        const record = await readRegistry(ctx, "adapter", "getAdapter", [config.adapterConfigId]);
        if (!record.exists) return false;
        requireStoredHash(`AdapterRegistry（${spec.label}）`, record, config.configHash);
        return true;
      },
    );
    writeStep(
      `config.${spec.stateKey}.activate`,
      "configs",
      `activateAdapter（${spec.label}）`,
      "governance",
      async (ctx) => {
        if (key !== "unrestricted") await assertBindingCurrent(ctx, key);
        const adapter = await adapterConfig(ctx, key);
        return {
          address: addr.registry(ctx, "adapter"),
          abi: registryAbi("adapter"),
          functionName: "activateAdapter",
          args: [adapter.adapterConfigId, adapter.configHash],
        };
      },
      async (ctx) => {
        const adapter = await adapterConfig(ctx, key);
        const record = await readRegistry(ctx, "adapter", "getAdapter", [adapter.adapterConfigId]);
        return record.exists && Number(record.status) === Enum.AdapterStatus.ACTIVE;
      },
    );
  }
  for (const name of config.calculators) {
    writeStep(
      `config.calculator.${name}.register`,
      "configs",
      `registerPrincipalCalculator（${name}）`,
      "configurer",
      async (ctx) => ({
        address: addr.registry(ctx, "calculator"),
        abi: registryAbi("calculator"),
        functionName: "registerPrincipalCalculator",
        args: [await calculatorConfig(ctx, name)],
      }),
      async (ctx) => {
        const config = await calculatorConfig(ctx, name);
        const record = await readRegistry(ctx, "calculator", "getPrincipalCalculator", [config.calculatorConfigId]);
        if (!record.exists) return false;
        requireStoredHash("PrincipalCalculatorRegistry", record, config.configHash);
        return true;
      },
    );
  }
  writeStep(
    "config.settlementToken.register",
    "configs",
    "registerSettlementToken",
    "configurer",
    async (ctx) => ({
      address: addr.registry(ctx, "settlementToken"),
      abi: registryAbi("settlementToken"),
      functionName: "registerSettlementToken",
      args: [await settlementTokenConfig(ctx)],
    }),
    async (ctx) => {
      const config = await settlementTokenConfig(ctx);
      const record = await readRegistry(ctx, "settlementToken", "getSettlementToken", [config.configId]);
      if (!record.exists) return false;
      requireStoredHash("SettlementTokenRegistry", record, config.configHash);
      return true;
    },
  );

  for (const name of config.calculators) {
    writeStep(
      `config.calculator.${name}.activate`,
      "configs",
      `activatePrincipalCalculator（${name}）`,
      "governance",
      async (ctx) => {
        const config = await calculatorConfig(ctx, name);
        return {
          address: addr.registry(ctx, "calculator"),
          abi: registryAbi("calculator"),
          functionName: "activatePrincipalCalculator",
          args: [config.calculatorConfigId, config.configHash],
        };
      },
      async (ctx) => {
        const config = await calculatorConfig(ctx, name);
        const record = await readRegistry(ctx, "calculator", "getPrincipalCalculator", [config.calculatorConfigId]);
        return record.exists && Number(record.status) === Enum.CalculatorStatus.ACTIVE;
      },
    );
  }
  writeStep(
    "config.settlementToken.activate",
    "configs",
    "activateSettlementToken",
    "governance",
    async (ctx) => {
      const config = await settlementTokenConfig(ctx);
      return {
        address: addr.registry(ctx, "settlementToken"),
        abi: registryAbi("settlementToken"),
        functionName: "activateSettlementToken",
        args: [config.configId, config.configHash],
      };
    },
    async (ctx) => {
      const config = await settlementTokenConfig(ctx);
      const record = await readRegistry(ctx, "settlementToken", "getSettlementToken", [config.configId]);
      return record.exists && Number(record.status) === Enum.SettlementTokenStatus.ACTIVE;
    },
  );

  const readEpoch = (ctx) => readRegistry(ctx, "fee", "getFeePolicyEpoch", [BigInt(FEE_EPOCH)]);
  const readFeeVersion = async (ctx) => readRegistry(ctx, "fee", "getFeeVersion", [(await globalFeeConfig(ctx)).feeVersionId]);

  writeStep(
    "fee.epoch.create",
    "fee",
    `createFeePolicyEpoch(${FEE_EPOCH})`,
    "governance",
    (ctx) => ({
      address: addr.registry(ctx, "fee"),
      abi: registryAbi("fee"),
      functionName: "createFeePolicyEpoch",
      args: [feeEpochConfig(ctx)],
    }),
    async (ctx) => {
      const record = await readEpoch(ctx);
      if (!record.exists) return false;
      requireStoredHash("FeeRegistry epoch", record, feeEpochConfig(ctx).configHash);
      return true;
    },
  );
  writeStep(
    "fee.global.register",
    "fee",
    "registerFeeVersion（GLOBAL 默认费率）",
    "configurer",
    async (ctx) => ({
      address: addr.registry(ctx, "fee"),
      abi: registryAbi("fee"),
      functionName: "registerFeeVersion",
      args: [await globalFeeConfig(ctx)],
    }),
    async (ctx) => {
      const record = await readFeeVersion(ctx);
      if (!record.exists) return false;
      requireStoredHash("FeeRegistry GLOBAL", record, (await globalFeeConfig(ctx)).configHash);
      return true;
    },
  );
  writeStep(
    "fee.epoch.seal",
    "fee",
    `sealFeePolicyEpoch(${FEE_EPOCH})`,
    "governance",
    (ctx) => ({
      address: addr.registry(ctx, "fee"),
      abi: registryAbi("fee"),
      functionName: "sealFeePolicyEpoch",
      args: [BigInt(FEE_EPOCH), feeEpochConfig(ctx).configHash],
    }),
    async (ctx) => Boolean((await readEpoch(ctx)).isSealed),
  );
  writeStep(
    "fee.global.activate",
    "fee",
    "activateFeeVersion（GLOBAL 默认费率）",
    "governance",
    async (ctx) => {
      const config = await globalFeeConfig(ctx);
      return {
        address: addr.registry(ctx, "fee"),
        abi: registryAbi("fee"),
        functionName: "activateFeeVersion",
        args: [config.feeVersionId, config.configHash],
      };
    },
    async (ctx) => Number((await readFeeVersion(ctx)).status) === Enum.FeeVersionStatus.ACTIVE,
  );
  writeStep(
    "fee.epoch.activate",
    "fee",
    `activateFeePolicyEpoch(${FEE_EPOCH})`,
    "governance",
    async (ctx) => {
      const fee = await globalFeeConfig(ctx);
      return {
        address: addr.registry(ctx, "fee"),
        abi: registryAbi("fee"),
        functionName: "activateFeePolicyEpoch",
        args: [BigInt(FEE_EPOCH), feeEpochConfig(ctx).configHash, fee.feeVersionId],
      };
    },
    async (ctx) => Number((await readEpoch(ctx)).status) === Enum.FeePolicyEpochStatus.ACTIVE,
  );

  return steps;
}

// ---------------------------------------------------------------------------
// 执行器
// ---------------------------------------------------------------------------

async function waitUntilVisible(probe, timeoutMs = VISIBILITY_TIMEOUT_MS) {
  const started = Date.now();
  for (;;) {
    try {
      if (await probe()) return true;
    } catch {
      // 落后节点可能直接报错，继续等
    }
    if (Date.now() - started >= timeoutMs) return false;
    await new Promise((r) => setTimeout(r, VISIBILITY_POLL_MS));
  }
}

// 估算 gas 时可能落到尚未同步上一笔交易的节点，表现为依赖合约“没有代码”等回滚；隔几秒重试通常就能通过。
async function sendWithRetry(label, abi, send) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await send();
    } catch (error) {
      const reason = formatTxError(error, abi);
      if (attempt >= SEND_ATTEMPTS) throw new Error(`${label}: ${reason}`);
      console.log(`    发送失败（${reason}），${SEND_RETRY_MS / 1000}s 后重试 ${attempt}/${SEND_ATTEMPTS - 1}`);
      await new Promise((r) => setTimeout(r, SEND_RETRY_MS));
    }
  }
}

async function stepVisible(ctx, step, address, timeoutMs) {
  const probe = step.kind === "deploy" ? () => hasCode(ctx.publicClient, address) : () => step.check(ctx);
  return waitUntilVisible(probe, timeoutMs);
}

async function tryGetReceipt(publicClient, hash) {
  try {
    return await publicClient.getTransactionReceipt({ hash });
  } catch {
    return null;
  }
}

async function tryGetTransaction(publicClient, hash) {
  try {
    return await publicClient.getTransaction({ hash });
  } catch {
    return null;
  }
}

function markDone(ctx, step, entry, receipt, extra = {}) {
  ctx.state.steps[step.id] = {
    status: "done",
    signer: entry.signer,
    from: entry.from,
    nonce: entry.nonce,
    txHash: receipt?.transactionHash ?? entry.txHash ?? null,
    blockNumber: receipt ? Number(receipt.blockNumber) : null,
    gasUsed: receipt ? receipt.gasUsed.toString() : null,
    address: step.kind === "deploy" ? getAddress(receipt?.contractAddress ?? extra.address) : null,
    finishedAt: new Date().toISOString(),
    ...extra,
  };
  ctx.saveState();
  const done = ctx.state.steps[step.id];
  const details = [done.address ? `地址 ${done.address}` : null, done.txHash ? `tx ${done.txHash}` : null, extra.note]
    .filter(Boolean)
    .join("  ");
  console.log(`    完成 ${details}`);
}

async function confirmDone(ctx, step, entry) {
  if (step.kind === "deploy") {
    if (!(await stepVisible(ctx, step, entry.address, 30_000))) {
      throw new Error(
        `状态文件记录 ${step.id} 已完成，但链上 ${entry.address} 没有代码（RPC 连错链或链被重置？）。` +
          `确认后可用 --from ${step.id} 重跑`,
      );
    }
    if (step.verify) await step.verify(ctx, getAddress(entry.address));
    return;
  }
  if (!(await stepVisible(ctx, step, null, 30_000))) {
    throw new Error(`状态文件记录 ${step.id} 已完成，但链上状态不符。确认后可用 --from ${step.id} 重跑`);
  }
}

async function recoverPending(ctx, step, entry) {
  if (entry.txHash) {
    let receipt = await tryGetReceipt(ctx.publicClient, entry.txHash);
    if (receipt || (await tryGetTransaction(ctx.publicClient, entry.txHash))) {
      console.log(`    等待上次发出的交易 ${entry.txHash} 达到 ${ctx.finalityConfirmations} 个确认`);
      receipt = await ctx.publicClient.waitForTransactionReceipt({
        hash: entry.txHash,
        timeout: Math.max(RECEIPT_TIMEOUT_MS, ctx.finalityConfirmations * RECEIPT_BLOCK_BUDGET_MS),
        confirmations: ctx.finalityConfirmations,
      });
    }
    if (receipt) {
      if (receipt.status === "success") {
        markDone(ctx, step, entry, receipt, { note: "续跑时补齐回执" });
        return true;
      }
      console.log(`    上次交易 ${entry.txHash} 已回滚，重新执行`);
      delete ctx.state.steps[step.id];
      ctx.saveState();
      return false;
    }
  }
  const confirmedNonce =
    entry.nonce === undefined
      ? null
      : await ctx.publicClient.getTransactionCount({ address: entry.from, blockTag: "latest" });
  if (step.kind === "deploy" && confirmedNonce !== null) {
    const predicted = getContractAddress({ from: entry.from, nonce: BigInt(entry.nonce) });
    const nonceUsed = confirmedNonce > entry.nonce;
    if (nonceUsed && (await stepVisible(ctx, step, predicted, 30_000))) {
      markDone(ctx, step, entry, null, { address: predicted, note: "续跑时按 nonce 找回合约" });
      return true;
    }
  }
  if (step.kind === "write" && (await step.check(ctx))) {
    markDone(ctx, step, entry, null, { note: "续跑时确认链上已生效" });
    return true;
  }
  if (confirmedNonce !== null && confirmedNonce <= entry.nonce) {
    const pendingNonce = await ctx.publicClient.getTransactionCount({ address: entry.from, blockTag: "pending" });
    if (pendingNonce > entry.nonce) {
      throw new Error(
        `${step.id} 的 nonce ${entry.nonce} 已在 pending 池中，但状态文件尚无 txHash；` +
          "为避免重复交易，等待该 nonce 确认或被节点丢弃后再重跑",
      );
    }
  }
  delete ctx.state.steps[step.id];
  ctx.saveState();
  return false;
}

async function execute(ctx, step) {
  const account = ctx.signers[step.signer];
  const wallet = ctx.wallets[step.signer];
  const rpcNonce = await ctx.publicClient.getTransactionCount({ address: account.address, blockTag: "pending" });
  const nonce = Math.max(rpcNonce, ctx.nextNonce.get(account.address) ?? 0);
  const entry = { status: "pending", signer: step.signer, from: account.address, nonce, startedAt: new Date().toISOString() };

  let hash;
  if (step.kind === "deploy") {
    const { artifact, args, gas } = await step.build(ctx);
    ctx.state.steps[step.id] = entry;
    ctx.saveState();
    hash = await sendWithRetry(`${step.id} 部署失败`, artifact.abi, () =>
      wallet.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode, args, nonce, ...(gas ? { gas } : {}) }),
    );
  } else {
    const request = await step.build(ctx);
    ctx.state.steps[step.id] = entry;
    ctx.saveState();
    hash = await sendWithRetry(`${step.id} 发送失败`, request.abi, () => wallet.writeContract({ ...request, nonce }));
  }

  entry.txHash = hash;
  ctx.saveState();
  ctx.nextNonce.set(account.address, nonce + 1);
  console.log(`    已发送 tx ${hash}`);
  ctx.sentCount += 1;

  const receipt = await ctx.publicClient.waitForTransactionReceipt({
    hash,
    timeout: Math.max(RECEIPT_TIMEOUT_MS, ctx.finalityConfirmations * RECEIPT_BLOCK_BUDGET_MS),
    confirmations: ctx.finalityConfirmations,
  });
  if (receipt.status !== "success") {
    ctx.state.steps[step.id] = { ...entry, status: "reverted", blockNumber: Number(receipt.blockNumber) };
    ctx.saveState();
    throw new Error(`${step.id} 交易回滚 ${hash}`);
  }
  if (step.kind === "deploy" && !receipt.contractAddress) throw new Error(`${step.id} 回执里没有合约地址`);
  markDone(ctx, step, entry, receipt);
  const address = step.kind === "deploy" ? getAddress(receipt.contractAddress) : null;
  if (!(await stepVisible(ctx, step, address))) {
    throw new Error(
      `${step.id} 已上链（区块 ${receipt.blockNumber}），但 RPC 在 ${VISIBILITY_TIMEOUT_MS / 1000}s 内仍读不到结果，` +
        "节点同步可能严重滞后。已记为完成，稍后重跑同一条命令即可继续",
    );
  }
}

async function runSteps(ctx, steps, range) {
  const total = steps.length;
  for (let index = range.start; index <= range.end; index += 1) {
    const step = steps[index];
    const label = `[${String(index + 1).padStart(2)}/${total}] ${step.id}  ${step.title}`;
    const entry = ctx.state.steps[step.id];

    if (entry?.status === "done") {
      await confirmDone(ctx, step, entry);
      console.log(`${label}  (已完成，跳过)`);
      continue;
    }
    console.log(label);
    if (entry?.status === "pending" && (await recoverPending(ctx, step, entry))) continue;
    if (entry?.status === "reverted") delete ctx.state.steps[step.id];

    if (step.kind === "write" && (await step.check(ctx))) {
      markDone(ctx, step, { signer: step.signer, from: ctx.signers[step.signer]?.address ?? null }, null, {
        note: "链上已生效，未发交易",
      });
      continue;
    }
    await execute(ctx, step);
  }
}

function resolveRange(steps, flags) {
  const indexOf = (id, name) => {
    const index = steps.findIndex((step) => step.id === id);
    if (index < 0) throw new Error(`--${name} 找不到步骤 ${id}，可用 --status 查看步骤 id`);
    return index;
  };
  const from = typeof flags.from === "string" ? indexOf(flags.from, "from") : null;
  const end = typeof flags.until === "string" ? indexOf(flags.until, "until") : steps.length - 1;
  if (from !== null && from > end) throw new Error("--from 不能在 --until 之后");
  return { from, start: 0, end };
}

function printStatus(steps, state) {
  const done = steps.filter((step) => state.steps[step.id]?.status === "done").length;
  console.log(`进度 ${done}/${steps.length}`);
  let phase = null;
  for (const step of steps) {
    if (step.phase !== phase) {
      phase = step.phase;
      console.log(`\n[${phase}]`);
    }
    const entry = state.steps[step.id];
    const mark = entry?.status === "done" ? "done   " : entry?.status ? entry.status.padEnd(7) : "-      ";
    const detail = entry?.address ?? entry?.txHash ?? "";
    console.log(`  ${mark} ${step.id.padEnd(36)} ${detail}`);
  }
}

// ---------------------------------------------------------------------------
// 预检
// ---------------------------------------------------------------------------

async function resolveSchedule(ctx) {
  if (ctx.state.resolved) return;
  const now = Number((await ctx.publicClient.getBlock()).timestamp);
  const epoch = ctx.config.feeEpoch;
  const quoteValidFrom = epoch.quoteValidFrom ?? now;
  const quoteValidUntil = epoch.quoteValidUntil ?? quoteValidFrom + 365 * DAY;
  const settlementValidUntil = epoch.settlementValidUntil ?? quoteValidUntil + 30 * DAY;
  if (!(quoteValidFrom <= quoteValidUntil && quoteValidUntil <= settlementValidUntil)) {
    throw new Error("feeEpoch 必须满足 quoteValidFrom <= quoteValidUntil <= settlementValidUntil");
  }
  const validFrom = ctx.config.globalFee.validFrom ?? quoteValidFrom;
  const validUntil = ctx.config.globalFee.validUntil ?? settlementValidUntil;
  if (validUntil < validFrom || validFrom < quoteValidFrom || validUntil > settlementValidUntil) {
    throw new Error(
      `globalFee 有效期 [${validFrom}, ${validUntil}] 必须落在 Epoch 窗口 [${quoteValidFrom}, ${settlementValidUntil}] 之内`,
    );
  }
  ctx.state.resolved = {
    resolvedAt: now,
    schedule: { quoteValidFrom, quoteValidUntil, settlementValidUntil },
    feeValidity: { validFrom, validUntil },
  };
  ctx.saveState();
}

function isoTime(unix) {
  return new Date(Number(unix) * 1000).toISOString();
}

function assertFactoryPinned() {
  const factoryRuntime = readJson(artifactPath("DvPCurrentStateValidatorFactory")).deployedBytecode?.object;
  const factoryCodeHash = keccak256(factoryRuntime);
  const dvpCreation = loadArtifact("DvPSettlement").bytecode.toLowerCase();
  if (!dvpCreation.includes(factoryCodeHash.slice(2).toLowerCase())) {
    throw new Error(
      `编译出的 DvPCurrentStateValidatorFactory 代码哈希 ${factoryCodeHash} 不在 DvPSettlement 钉死的常量里，` +
        "部署 DvP 一定会以 InvalidDvpValidatorFactory 回滚。\n" +
        "常见原因：contracts/lib 下的 OpenZeppelin 子模块被改过（例如 forge fmt），bytecode_hash=ipfs 使元数据哈希变化。\n" +
        "修复：恢复子模块到提交版本后重新 forge build，或用 --artifacts 指向一份干净构建的产物。",
    );
  }
}

async function preflight(ctx, steps, range) {
  const pending = steps.slice(range.start, range.end + 1).filter((step) => ctx.state.steps[step.id]?.status !== "done");

  if (pending.some((step) => step.id === "core.dvp")) assertFactoryPinned();
  await assertMainnetOndoEvidence(ctx);

  for (const signer of new Set(pending.map((step) => step.signer))) {
    if (!ctx.signers[signer]) {
      const env = signer === "governance" ? "HTP_GOVERNANCE_KEY" : "HTP_CONFIGURER_KEY";
      throw new Error(`待执行步骤需要 ${signer}（${ctx.config.roles[signer]}）签名，请设置 ${env}`);
    }
  }

  const token = ctx.config.settlementToken.address;
  if (!(await hasCode(ctx.publicClient, token))) throw new Error(`结算币 ${token} 在当前链上没有代码`);
  const onChainDecimals = Number(await ctx.publicClient.readContract({ address: token, abi: ERC20_META_ABI, functionName: "decimals" }));
  if (ctx.config.settlementToken.decimals !== null && ctx.config.settlementToken.decimals !== onChainDecimals) {
    throw new Error(`settlementToken.decimals=${ctx.config.settlementToken.decimals}，链上 decimals()=${onChainDecimals}`);
  }
  ctx.settlementDecimals = onChainDecimals;
  await detectTokenDeployment(ctx.publicClient, token, ctx.config.settlementToken);

  for (const key of RESTRICTED_ADAPTER_KEYS) {
    if (!ctx.config.assetAdapters[key]) continue;
    const stateKey = ADAPTER_SPECS[key].stateKey;
    if (!pending.some((step) => step.id === `component.${stateKey}` || step.id === `config.${stateKey}.register`)) continue;
    const binding = await restrictedBinding(ctx, key);
    console.log(`${ADAPTER_SPECS[key].contract} 绑定代币 ${binding.token}（providerCallGas ${binding.providerCallGas}）`);
    if (key === "usdyRestricted") {
      console.log(`  blocklist ${binding.blocklist}  allowlist ${binding.allowlist}  sanctionsList ${binding.sanctionsList}`);
    } else if (key === "ondoGm") {
      console.log(
        `  complianceView ${binding.complianceView}  compliance ${binding.compliance}  pauseManager ${binding.pauseManager}`,
      );
      console.log(`  blocklist ${binding.blocklist}  sanctionsList ${binding.sanctionsList}`);
    }
  }

  const { schedule } = ctx.state.resolved;
  console.log(
    `Fee Epoch ${FEE_EPOCH} 报价窗口 ${isoTime(schedule.quoteValidFrom)} ~ ${isoTime(schedule.quoteValidUntil)}，` +
      `最晚交割 ${isoTime(schedule.settlementValidUntil)}`,
  );
  if (pending.some((step) => step.id === "fee.epoch.activate")) {
    const now = Number((await ctx.publicClient.getBlock()).timestamp);
    if (now < schedule.quoteValidFrom || now > schedule.quoteValidUntil) {
      throw new Error(
        `链上时间 ${isoTime(now)} 不在 Epoch 报价窗口内，activateFeePolicyEpoch 会回滚。` +
          "请调整 feeEpoch，或用 --until 在 fee.epoch.activate 之前停下",
      );
    }
  }

  for (const [name, account] of Object.entries(ctx.signers)) {
    if (!account || !pending.some((step) => step.signer === name)) continue;
    const balance = await ctx.publicClient.getBalance({ address: account.address });
    if (balance === 0n) throw new Error(`${name} ${account.address} 余额为 0，付不起 gas`);
  }
}

// ---------------------------------------------------------------------------
// 校验与报告
// ---------------------------------------------------------------------------

function failedLeaves(value, prefix = "") {
  if (typeof value === "boolean") return value ? [] : [prefix];
  if (value && typeof value === "object") {
    return Object.entries(value).flatMap(([key, nested]) => failedLeaves(nested, prefix ? `${prefix}.${key}` : key));
  }
  return [];
}

function enumName(table, value) {
  return Object.entries(table).find(([, item]) => item === Number(value))?.[0] ?? `UNKNOWN(${value})`;
}

async function hasRole(ctx, target, role, account) {
  return ctx.publicClient.readContract({ address: target, abi: ACCESS_ABI, functionName: "hasRole", args: [ROLE_ID[role], account] });
}

function capabilityNames(capabilities) {
  return {
    tokenStandard: enumName(Enum.TokenStandard, capabilities.tokenStandard),
    restrictionMode: enumName(Enum.RestrictionMode, capabilities.restrictionMode),
    precheckMethod: enumName(Enum.PrecheckMethod, capabilities.precheckMethod),
    transferLegMask: capabilities.transferLegMask,
  };
}

async function restrictedAdapterReport(ctx, key, dvp) {
  const spec = ADAPTER_SPECS[key];
  const [config, binding] = await Promise.all([adapterConfig(ctx, key), restrictedBinding(ctx, key)]);
  const [record, current] = await Promise.all([
    readRegistry(ctx, "adapter", "getAdapter", [config.adapterConfigId]),
    readRegistry(ctx, "adapter", "getCurrentAdapter", [config.capabilityHash]),
  ]);
  const status = enumName(Enum.AdapterStatus, record.status);
  const checks = { active: status === "ACTIVE", providerBindingCurrent: binding.providerHash === config.providerHash };
  const warnings = [];
  const entry = {
    contract: spec.contract,
    adapter: config.adapter,
    adapterConfigId: config.adapterConfigId,
    configHash: config.configHash,
    revision: config.revision,
    replacesId: config.replacesId,
    capabilityHash: config.capabilityHash,
    providerHash: config.providerHash,
    capabilities: capabilityNames(config.capabilities),
    status,
    isCurrent: current.exists && current.config.adapterConfigId === config.adapterConfigId,
    binding,
  };

  if (key === "usdyRestricted") {
    const state = await readUsdyDvpState(ctx.publicClient, binding, dvp);
    entry.tokenState = state.tokenState;
    warnings.push(...state.warnings);
  } else if (key === "ondoGm") {
    const state = await readOndoGmDvpState(ctx.publicClient, binding, dvp);
    entry.tokenState = state.tokenState;
    warnings.push(...state.warnings);
  }
  return { entry, checks, warnings };
}

async function buildReport(ctx, steps) {
  const { publicClient, config, chainId } = ctx;
  const { roles } = config;
  const dvp = addr.dvp(ctx);
  const factory = addr.factory(ctx);
  const signedPayloadValidator = getContractAddress({ from: dvp, nonce: 1n });
  const currentStateValidator = getContractAddress({ from: factory, nonce: 3n });

  const registries = {};
  const registryChecks = {};
  for (const spec of REGISTRY_SPECS) {
    const proxy = addr.registry(ctx, spec.key);
    const implementation = addr.registryImpl(ctx, spec.key);
    const [slotImplementation, slotAdmin, dependents, boundOnDvp, ...roleFacts] = await Promise.all([
      readSlotAddress(publicClient, proxy, ERC1967_IMPLEMENTATION_SLOT),
      readSlotAddress(publicClient, proxy, ERC1967_ADMIN_SLOT),
      dependentDvps(ctx, spec.key),
      publicClient.readContract({ address: dvp, abi: DVP_VIEW_ABI, functionName: DVP_REGISTRY_GETTERS[spec.key] }),
      hasRole(ctx, proxy, "DEFAULT_ADMIN_ROLE", roles.defaultAdmin),
      hasRole(ctx, proxy, "GOVERNANCE_ROLE", roles.governance),
      hasRole(ctx, proxy, "UPGRADER_ROLE", roles.upgrader),
      hasRole(ctx, proxy, "PAUSER_ROLE", roles.pauser),
      hasRole(ctx, proxy, "CONFIGURER_ROLE", roles.configurer),
    ]);
    registries[spec.key] = { contract: spec.contract, proxy, implementation };
    registryChecks[spec.key] = {
      implementationSlot: slotImplementation === implementation,
      proxyAdminSlotZero: slotAdmin === zeroAddress,
      dependentDvpRegistered: dependents.includes(dvp),
      boundOnDvp: getAddress(boundOnDvp) === proxy,
      roles: {
        DEFAULT_ADMIN_ROLE: roleFacts[0],
        GOVERNANCE_ROLE: roleFacts[1],
        UPGRADER_ROLE: roleFacts[2],
        PAUSER_ROLE: roleFacts[3],
        CONFIGURER_ROLE: roleFacts[4],
      },
    };
  }

  const readDvp = (functionName) => publicClient.readContract({ address: dvp, abi: DVP_VIEW_ABI, functionName });
  const [domainSeparator, deploymentVersionHash, globalPaused, retired, factoryCode, signedCode, currentCode] =
    await Promise.all([
      readDvp("domainSeparatorV4"),
      readDvp("deploymentVersionHash"),
      readDvp("globalPaused"),
      readDvp("retired"),
      hasCode(publicClient, factory),
      hasCode(publicClient, signedPayloadValidator),
      hasCode(publicClient, currentStateValidator),
    ]);
  const dvpRoles = {
    DEFAULT_ADMIN_ROLE: await hasRole(ctx, dvp, "DEFAULT_ADMIN_ROLE", roles.defaultAdmin),
    GOVERNANCE_ROLE: await hasRole(ctx, dvp, "GOVERNANCE_ROLE", roles.governance),
    PAUSER_ROLE: await hasRole(ctx, dvp, "PAUSER_ROLE", roles.pauser),
    EXECUTOR_ROLE: await hasRole(ctx, dvp, "EXECUTOR_ROLE", roles.executor),
    noUpgraderRole: !(await hasRole(ctx, dvp, "UPGRADER_ROLE", roles.upgrader)),
    noConfigurerRole: !(await hasRole(ctx, dvp, "CONFIGURER_ROLE", roles.configurer)),
  };

  const unrestrictedAdapter = await adapterConfig(ctx, "unrestricted");
  const assetAdapters = {};
  const assetAdapterChecks = {};
  const warnings = [];
  for (const key of RESTRICTED_ADAPTER_KEYS) {
    if (!config.assetAdapters[key]) continue;
    const item = await restrictedAdapterReport(ctx, key, dvp);
    assetAdapters[key] = item.entry;
    assetAdapterChecks[key] = item.checks;
    warnings.push(...item.warnings);
  }
  const settlement = await settlementTokenConfig(ctx);
  const epoch = feeEpochConfig(ctx);
  const fee = await globalFeeConfig(ctx);
  const calculators = {};
  for (const name of config.calculators) {
    const calc = await calculatorConfig(ctx, name);
    const record = await readRegistry(ctx, "calculator", "getPrincipalCalculator", [calc.calculatorConfigId]);
    calculators[name] = {
      address: calc.calculator,
      calculatorConfigId: calc.calculatorConfigId,
      configHash: calc.configHash,
      status: enumName(Enum.CalculatorStatus, record.status),
    };
  }
  const [adapterRecord, settlementRecord, epochRecord, feeRecord, tokenName, tokenSymbol] = await Promise.all([
    readRegistry(ctx, "adapter", "getAdapter", [unrestrictedAdapter.adapterConfigId]),
    readRegistry(ctx, "settlementToken", "getSettlementToken", [settlement.configId]),
    readRegistry(ctx, "fee", "getFeePolicyEpoch", [BigInt(FEE_EPOCH)]),
    readRegistry(ctx, "fee", "getFeeVersion", [fee.feeVersionId]),
    publicClient.readContract({ address: settlement.settlementToken, abi: ERC20_META_ABI, functionName: "name" }).catch(() => null),
    publicClient.readContract({ address: settlement.settlementToken, abi: ERC20_META_ABI, functionName: "symbol" }).catch(() => null),
  ]);

  const statuses = {
    unrestrictedAdapter: enumName(Enum.AdapterStatus, adapterRecord.status),
    settlementToken: enumName(Enum.SettlementTokenStatus, settlementRecord.status),
    feeEpoch: enumName(Enum.FeePolicyEpochStatus, epochRecord.status),
    globalFee: enumName(Enum.FeeVersionStatus, feeRecord.status),
  };

  const checks = {
    dvp: {
      notPaused: !globalPaused,
      notRetired: !retired,
      deploymentVersionHash: deploymentVersionHash === hashDeploymentVersion(config.deploymentVersion),
      factoryHasCode: factoryCode,
      signedPayloadValidatorHasCode: signedCode,
      currentStateValidatorHasCode: currentCode,
      roles: dvpRoles,
    },
    registries: registryChecks,
    configurations: {
      unrestrictedAdapterActive: statuses.unrestrictedAdapter === "ACTIVE",
      settlementTokenActive: statuses.settlementToken === "ACTIVE",
      feeEpochActive: statuses.feeEpoch === "ACTIVE",
      feeEpochSealed: Boolean(epochRecord.isSealed),
      globalFeeActive: statuses.globalFee === "ACTIVE",
      calculatorsActive: Object.fromEntries(Object.entries(calculators).map(([name, item]) => [name, item.status === "ACTIVE"])),
    },
    assetAdapters: assetAdapterChecks,
  };
  const failed = failedLeaves(checks);

  const blockOf = (id) => ctx.state.steps[id]?.blockNumber ?? null;
  const dataSources = [
    { name: "DvPSettlement", address: dvp, startBlock: blockOf("core.dvp") },
    ...REGISTRY_SPECS.map((spec) => ({
      name: spec.contract,
      address: registries[spec.key].proxy,
      startBlock: blockOf(`registry.${spec.key}.proxy`),
    })),
  ];
  const knownBlocks = dataSources.map((item) => item.startBlock).filter((block) => block !== null);
  const network = NETWORKS[chainId];

  return {
    metadata: {
      generatedAt: new Date().toISOString(),
      chainId,
      finalityConfirmations: config.finalityConfirmations,
      network: network?.name ?? `chain-${chainId}`,
      explorer: network?.explorer ?? null,
      deployer: ctx.signers.deployer.address,
      deploymentVersion: config.deploymentVersion,
      deploymentVersionHash,
      stateFile: ctx.statePath,
      platformReady: failed.length === 0,
      scope: "platform-only：未登记任何资产版本、市场规则、参与方和资格",
    },
    roles,
    addresses: {
      dvp,
      factory,
      signedPayloadValidator,
      currentStateValidator,
      settlementToken: settlement.settlementToken,
      unrestrictedAdapter: unrestrictedAdapter.adapter,
      assetAdapters: Object.fromEntries(Object.entries(assetAdapters).map(([key, item]) => [key, item.adapter])),
      calculators: Object.fromEntries(Object.entries(calculators).map(([name, item]) => [name, item.address])),
      registries: Object.fromEntries(Object.entries(registries).map(([key, item]) => [key, item.proxy])),
      registryImplementations: Object.fromEntries(Object.entries(registries).map(([key, item]) => [key, item.implementation])),
    },
    dvp: {
      address: dvp,
      globalPaused,
      retired,
      eip712: {
        name: "HTP DvP Settlement",
        version: config.deploymentVersion.split(".")[0],
        chainId,
        verifyingContract: dvp,
        domainSeparator,
      },
    },
    configuration: {
      evidenceHash: config.evidenceHash,
      unrestrictedAdapter: {
        adapterConfigId: unrestrictedAdapter.adapterConfigId,
        configHash: unrestrictedAdapter.configHash,
        capabilityHash: unrestrictedAdapter.capabilityHash,
        capabilities: capabilityNames(unrestrictedAdapter.capabilities),
        status: statuses.unrestrictedAdapter,
      },
      assetAdapters,
      calculators,
      settlementToken: {
        address: settlement.settlementToken,
        name: tokenName,
        symbol: tokenSymbol,
        decimals: settlement.settlementTokenDecimals,
        deploymentKind: enumName(Enum.TokenDeploymentKind, settlement.tokenDeploymentKind),
        implementation: settlement.implementation,
        permitCapability: enumName(Enum.PermitCapability, settlement.permitCapability),
        configId: settlement.configId,
        configHash: settlement.configHash,
        status: statuses.settlementToken,
      },
      feeEpoch: {
        feePolicyEpoch: FEE_EPOCH,
        configHash: epoch.configHash,
        quoteValidFrom: { unix: epoch.quoteValidFrom, iso: isoTime(epoch.quoteValidFrom) },
        quoteValidUntil: { unix: epoch.quoteValidUntil, iso: isoTime(epoch.quoteValidUntil) },
        settlementValidUntil: { unix: epoch.settlementValidUntil, iso: isoTime(epoch.settlementValidUntil) },
        sealed: Boolean(epochRecord.isSealed),
        status: statuses.feeEpoch,
      },
      globalFee: {
        feeVersionId: fee.feeVersionId,
        configHash: fee.configHash,
        matchedScopeHash: fee.matchedScopeHash,
        feeConstraintHash: fee.feeConstraintHash,
        scopeType: "GLOBAL",
        investorRateBps: fee.investorRateBps,
        investorHasCap: fee.investorHasCap,
        investorCapAmount: fee.investorCapAmount,
        makerRateBps: fee.makerRateBps,
        makerHasCap: fee.makerHasCap,
        makerCapAmount: fee.makerCapAmount,
        collector: fee.collector,
        validFrom: { unix: fee.validFrom, iso: isoTime(fee.validFrom) },
        validUntil: { unix: fee.validUntil, iso: isoTime(fee.validUntil) },
        status: statuses.globalFee,
      },
    },
    subgraph: {
      chainId,
      startBlock: knownBlocks.length ? Math.min(...knownBlocks) : null,
      dataSources,
    },
    verification: { platformReady: failed.length === 0, failed, warnings, checks },
    transactions: steps
      .map((step) => ({ step: step.id, ...ctx.state.steps[step.id] }))
      .filter((item) => item.txHash)
      .map((item) => ({
        step: item.step,
        hash: item.txHash,
        blockNumber: item.blockNumber,
        from: item.from,
        gasUsed: item.gasUsed,
        address: item.address,
        explorer: network?.explorer ? `${network.explorer}/tx/${item.txHash}` : null,
      })),
  };
}

/** 从完整报告提炼对接用的最小集合：地址、角色、EIP-712 域、配置 ID/Hash、费率参数。 */
export function buildSummary(report) {
  const cfg = report.configuration;
  return {
    chainId: report.metadata.chainId,
    finalityConfirmations: report.metadata.finalityConfirmations,
    network: report.metadata.network,
    deploymentVersion: report.metadata.deploymentVersion,
    platformReady: report.metadata.platformReady,
    generatedAt: report.metadata.generatedAt,
    startBlock: report.subgraph.startBlock,
    eip712: report.dvp.eip712,
    contracts: {
      dvp: report.addresses.dvp,
      factory: report.addresses.factory,
      settlementToken: report.addresses.settlementToken,
      unrestrictedAdapter: report.addresses.unrestrictedAdapter,
      assetAdapters: report.addresses.assetAdapters ?? {},
      calculators: report.addresses.calculators,
      registries: report.addresses.registries,
    },
    roles: report.roles,
    warnings: report.verification.warnings ?? [],
    configs: {
      unrestrictedAdapter: { id: cfg.unrestrictedAdapter.adapterConfigId, hash: cfg.unrestrictedAdapter.configHash },
      assetAdapters: Object.fromEntries(
        Object.entries(cfg.assetAdapters ?? {}).map(([key, item]) => [
          key,
          {
            id: item.adapterConfigId,
            hash: item.configHash,
            capabilityHash: item.capabilityHash,
            tokenStandard: item.capabilities.tokenStandard,
            restrictionMode: item.capabilities.restrictionMode,
            status: item.status,
            isCurrent: item.isCurrent,
            revision: item.revision,
            replacesId: item.replacesId,
            token: item.binding.token,
          },
        ]),
      ),
      settlementToken: {
        id: cfg.settlementToken.configId,
        hash: cfg.settlementToken.configHash,
        decimals: cfg.settlementToken.decimals,
      },
      calculators: Object.fromEntries(
        Object.entries(cfg.calculators).map(([name, item]) => [name, { id: item.calculatorConfigId, hash: item.configHash }]),
      ),
      feeEpoch: {
        epoch: cfg.feeEpoch.feePolicyEpoch,
        quoteValidFrom: cfg.feeEpoch.quoteValidFrom.unix,
        quoteValidUntil: cfg.feeEpoch.quoteValidUntil.unix,
        settlementValidUntil: cfg.feeEpoch.settlementValidUntil.unix,
      },
      globalFee: {
        feeVersionId: cfg.globalFee.feeVersionId,
        matchedScopeHash: cfg.globalFee.matchedScopeHash,
        feeConstraintHash: cfg.globalFee.feeConstraintHash,
        investorRateBps: cfg.globalFee.investorRateBps,
        investorCapAmount: cfg.globalFee.investorHasCap ? cfg.globalFee.investorCapAmount : null,
        makerRateBps: cfg.globalFee.makerRateBps,
        makerCapAmount: cfg.globalFee.makerHasCap ? cfg.globalFee.makerCapAmount : null,
        collector: cfg.globalFee.collector,
      },
    },
  };
}

function summaryPathFor(reportPath) {
  return reportPath.endsWith("-deployment.json")
    ? reportPath.replace(/-deployment\.json$/u, "-summary.json")
    : reportPath.replace(/(\.json)?$/u, ".summary.json");
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

function createChainClients(rpcUrl, chainId, signers) {
  const chain = defineChain({
    id: chainId,
    name: NETWORKS[chainId]?.name ?? `chain-${chainId}`,
    nativeCurrency: { name: NETWORKS[chainId]?.symbol ?? "ETH", symbol: NETWORKS[chainId]?.symbol ?? "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  const transport = http(rpcUrl);
  const publicClient = createPublicClient({ chain, transport });
  const wallets = {};
  for (const [name, account] of Object.entries(signers)) {
    if (account) wallets[name] = createWalletClient({ chain, account, transport });
  }
  return { publicClient, wallets };
}

/**
 * options: { rawConfig, rpcUrl, keys: {deployer, governance, configurer}, statePath?, outPath?, from?, until?, status?, verify? }
 */
export async function deployPlatform(options) {
  assertPinnedHashes();
  const config = normalizeConfig(options.rawConfig);
  if (options.status && options.statePath) {
    const statePath = resolve(options.statePath);
    printStatus(buildSteps(config), existsSync(statePath) ? readJson(statePath) : { steps: {} });
    return null;
  }
  const rpcUrl = String(options.rpcUrl ?? "");
  if (!rpcUrl) throw new Error("缺少 rpcUrl（--rpc 或 HTP_RPC_URL）");
  assertRpcUrl(rpcUrl);

  const chainId = await createPublicClient({ transport: http(rpcUrl) }).getChainId();
  if (config.expectedChainId !== chainId) {
    throw new Error(`RPC 返回 chainId=${chainId}，配置要求 expectedChainId=${config.expectedChainId}`);
  }
  const statePath = resolve(options.statePath ?? join(tmpOutRoot, `platform-state.${chainId}.json`));
  const outPath = resolve(options.outPath ?? join(tmpOutRoot, "platform-deployment.json"));
  const steps = buildSteps(config);

  if (options.status) {
    if (!existsSync(statePath)) {
      console.log(`还没有状态文件 ${statePath}`);
      printStatus(steps, { steps: {} });
      return null;
    }
    printStatus(steps, readJson(statePath));
    return null;
  }

  ensureBuild();
  const signers = loadSigners(config, options.keys ?? {});
  const fingerprint = { chainId, deployer: signers.deployer.address, configHash: configFingerprint(config) };
  const releaseLock = acquireLock(statePath);
  try {
    const state = loadState(statePath, fingerprint);
    const { publicClient, wallets } = createChainClients(rpcUrl, chainId, signers);
    const ctx = {
      config,
      chainId,
      publicClient,
      wallets,
      signers,
      finalityConfirmations: config.finalityConfirmations,
      state,
      statePath,
      cache: new Map(),
      nextNonce: new Map(),
      sentCount: 0,
      settlementDecimals: null,
      saveState: () => {
        state.updatedAt = new Date().toISOString();
        writeJsonAtomic(statePath, state);
      },
    };
    ctx.saveState();

    console.log(`chainId=${chainId} deployer=${signers.deployer.address}`);
    console.log(`状态文件 ${statePath}`);

    const range = resolveRange(steps, options);
    if (range.from !== null) {
      for (const step of steps.slice(range.from)) delete state.steps[step.id];
      ctx.saveState();
      console.log(`已清除 ${steps[range.from].id} 及之后的完成记录`);
    }

    await resolveSchedule(ctx);
    await preflight(ctx, steps, range);

    if (!options.verify) await runSteps(ctx, steps, range);

    const allDone = steps.every((step) => state.steps[step.id]?.status === "done");
    if (!allDone) {
      if (options.verify) throw new Error("还有步骤未完成，不能 --verify");
      console.log(`\n已停在 ${steps[range.end].id}，本次发送 ${ctx.sentCount} 笔交易。去掉 --until 重跑即可继续。`);
      return { state, report: null, sentCount: ctx.sentCount };
    }

    const report = await buildReport(ctx, steps);
    writeJsonAtomic(outPath, report);
    writeJsonAtomic(summaryPathFor(outPath), buildSummary(report));
    console.log(`\n报告已写入 ${outPath}`);
    console.log(`精简版已写入 ${summaryPathFor(outPath)}`);
    console.log(`本次发送 ${ctx.sentCount} 笔交易`);
    console.log(`DvP: ${report.addresses.dvp}`);
    console.log(`UnrestrictedERC20Adapter: ${report.addresses.unrestrictedAdapter}`);
    for (const [key, item] of Object.entries(report.configuration.assetAdapters)) {
      console.log(
        `${item.contract}: ${item.adapter}（${key}，${key === "ondoGm" ? "参考代币" : "绑定代币"} ${
          item.binding.token
        }，${item.status}，${
          item.isCurrent ? "CURRENT" : "NON_CURRENT"
        }）`,
      );
    }
    for (const warning of report.verification.warnings) console.log(`注意：${warning}`);
    if (!report.verification.platformReady) {
      throw new Error(`部署校验未通过：\n  ${report.verification.failed.join("\n  ")}`);
    }
    console.log("校验通过：平台已就绪（尚未上任何资产）");
    return { state, report, sentCount: ctx.sentCount };
  } finally {
    releaseLock();
  }
}

// ---------------------------------------------------------------------------
// 自测（仅 127.0.0.1 Anvil，使用 Anvil 公开测试私钥）
// ---------------------------------------------------------------------------

const ANVIL_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
];

function reservedPort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => (error ? reject(error) : resolvePort(port)));
    });
    server.on("error", reject);
  });
}

async function withAnvil(run) {
  const port = await reservedPort();
  const rpcUrl = `http://127.0.0.1:${port}`;
  const child = spawn("anvil", ["--host", "127.0.0.1", "--port", String(port), "--silent"], {
    stdio: "ignore",
  });
  try {
    const started = Date.now();
    for (;;) {
      try {
        await createPublicClient({ transport: http(rpcUrl) }).getChainId();
        break;
      } catch {
        if (Date.now() - started > 15_000) throw new Error("Anvil 启动超时");
        await new Promise((r) => setTimeout(r, 150));
      }
    }
    return await run(rpcUrl);
  } finally {
    child.kill("SIGTERM");
  }
}

function assertSelfTest(condition, message) {
  if (!condition) throw new Error(`自测失败：${message}`);
}

async function runSelfTest() {
  ensureBuild([
    "PipelineCashToken",
    "UsdyTokenMock",
    "AddressListMock",
    "ERC1404TokenMock",
    "OndoGmListMock",
    "OndoGmPauseManagerMock",
    "OndoComplianceMock",
    "OndoComplianceViewMock",
    "IntegrationOndoGmToken",
  ]);
  const workDir = join(tmpOutRoot, "self-test-platform");
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });

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
    const usdyToken = await deployMock("UsdyTokenMock");
    const [blocklist, allowlist, sanctionsList, otherBlocklist] = [
      await deployMock("AddressListMock"),
      await deployMock("AddressListMock"),
      await deployMock("AddressListMock"),
      await deployMock("AddressListMock"),
    ];
    await callMock("UsdyTokenMock", usdyToken, "configure", [blocklist, allowlist, sanctionsList]);
    const erc1404Token = await deployMock("ERC1404TokenMock");
    const [gmBlocklist, gmSanctionsList, gmPauseManager, gmCompliance] = [
      await deployMock("OndoGmListMock"),
      await deployMock("OndoGmListMock"),
      await deployMock("OndoGmPauseManagerMock"),
      await deployMock("OndoComplianceMock"),
    ];
    const gmComplianceView = await deployMock("OndoComplianceViewMock", [gmCompliance, ONDO_GM_IDENTIFIER]);
    const gmToken = await deployMock("IntegrationOndoGmToken", [gmComplianceView, gmPauseManager]);
    await callMock("OndoComplianceMock", gmCompliance, "configure", [
      ONDO_GM_IDENTIFIER,
      gmBlocklist,
      gmSanctionsList,
    ]);

    const rawConfig = {
      expectedChainId: 31337,
      finalityConfirmations: 1,
      deploymentVersion: "1.0.0",
      evidenceHash: `0x${"22".repeat(32)}`,
      roles: {
        defaultAdmin: deployer.address,
        governance: governance.address,
        upgrader: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
        pauser: "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65",
        executor: "0x9965507d1a55bcc2695c58f0e5bd91d6fbf4dd6d",
        configurer: configurer.address,
      },
      settlementToken: { address: cashToken, decimals: 6, permitCapability: "UNSUPPORTED", deploymentKind: "DIRECT" },
      calculators: ["FUND", "STOCK"],
      assetAdapters: {
        usdyRestricted: { token: usdyToken, allowlist, providerCallGas: 100000 },
        ondoGm: { token: gmToken, providerCallGas: 100000 },
        erc1404: { token: erc1404Token },
      },
      feeEpoch: { quoteValidFrom: null, quoteValidUntil: null, settlementValidUntil: null },
      globalFee: {
        investorRateBps: 25,
        investorHasCap: true,
        investorCapAmount: "50000000",
        makerRateBps: 15,
        makerHasCap: false,
        makerCapAmount: "0",
        collector: deployer.address,
      },
    };
    const base = {
      rawConfig,
      rpcUrl,
      keys: { deployer: ANVIL_KEYS[0], governance: ANVIL_KEYS[1], configurer: ANVIL_KEYS[2] },
      statePath: join(workDir, "state.json"),
      outPath: join(workDir, "report.json"),
    };

    console.log("\n=== 自测 0：USDY 名单与代币不一致时，发交易前拒绝 ===");
    let rejected = false;
    let rejectionMessage = "";
    const nonceBefore = await publicClient.getTransactionCount({ address: deployer.address });
    try {
      await deployPlatform({
        ...base,
        statePath: join(workDir, "state-bad-list.json"),
        rawConfig: {
          ...rawConfig,
          assetAdapters: { ...rawConfig.assetAdapters, usdyRestricted: { token: usdyToken, allowlist: otherBlocklist } },
        },
      });
    } catch (error) {
      rejectionMessage = safeErrorMessage(error);
      rejected = /不一致/u.test(rejectionMessage);
    }
    assertSelfTest(rejected, `名单地址与代币不一致时应报错（实际：${rejectionMessage}）`);
    assertSelfTest(
      (await publicClient.getTransactionCount({ address: deployer.address })) === nonceBefore,
      "名单不一致时不应发出任何交易",
    );

    console.log("\n=== 自测 1：执行到 core.dvp 后停下 ===");
    const partial = await deployPlatform({ ...base, until: "core.dvp" });
    assertSelfTest(partial.report === null, "--until 后不应生成报告");
    assertSelfTest(partial.sentCount === 18, `前 18 步应发 18 笔交易，实际 ${partial.sentCount}`);

    console.log("\n=== 自测 2：缺少治理私钥时拒绝继续 ===");
    rejected = false;
    try {
      await deployPlatform({ ...base, keys: { deployer: ANVIL_KEYS[0], configurer: ANVIL_KEYS[2] } });
    } catch (error) {
      rejected = /HTP_GOVERNANCE_KEY/u.test(error.message);
    }
    assertSelfTest(rejected, "缺治理私钥时应在发交易前报错");

    console.log("\n=== 自测 3：改了配置后拒绝续跑 ===");
    rejected = false;
    try {
      await deployPlatform({ ...base, rawConfig: { ...rawConfig, globalFee: { ...rawConfig.globalFee, makerRateBps: 20 } } });
    } catch (error) {
      rejected = /不匹配/u.test(error.message);
    }
    assertSelfTest(rejected, "配置变化后应拒绝续跑");

    console.log("\n=== 自测 4：续跑到结束 ===");
    const full = await deployPlatform(base);
    assertSelfTest(full.report?.verification.platformReady === true, "平台校验应通过");
    assertSelfTest(Object.keys(full.report.addresses.registries).length === 8, "报告应有 8 个 Registry");
    const expectedCurrentStateValidator = getContractAddress({
      from: full.report.addresses.factory,
      nonce: 3n,
    });
    assertSelfTest(
      full.report.addresses.currentStateValidator === expectedCurrentStateValidator,
      "报告应记录 Factory nonce 3 部署的 CurrentStateValidator",
    );
    assertSelfTest(
      full.report.addresses.currentStateValidator
        !== getContractAddress({ from: full.report.addresses.factory, nonce: 1n }),
      "CurrentStateValidator 不得误报为 Factory helper",
    );
    assertSelfTest(full.report.configuration.globalFee.status === "ACTIVE", "GLOBAL 费率应为 ACTIVE");
    assertSelfTest(full.report.configuration.feeEpoch.status === "ACTIVE", "Epoch 应为 ACTIVE");
    assertSelfTest(full.report.configuration.calculators.STOCK.status === "ACTIVE", "STOCK 计算器应为 ACTIVE");
    const usdy = full.report.configuration.assetAdapters.usdyRestricted;
    const ondoGm = full.report.configuration.assetAdapters.ondoGm;
    const erc1404 = full.report.configuration.assetAdapters.erc1404;
    assertSelfTest(
      usdy?.status === "ACTIVE" && ondoGm?.status === "ACTIVE" && erc1404?.status === "ACTIVE",
      "三个受限适配器应为 ACTIVE",
    );
    assertSelfTest(usdy.isCurrent === false, "USDY rev1 应保持 ACTIVE 但不再是当前 revision");
    assertSelfTest(ondoGm.isCurrent === true, "Ondo GM rev2 应是 TOKEN_ENFORCED 当前 revision");
    assertSelfTest(erc1404.isCurrent === true, "ERC1404 应是 ISSUER_EXTERNAL 当前 revision");
    assertSelfTest(usdy.revision === 1 && ondoGm.revision === 2, "同 capability 的 USDY / Ondo GM 应为连续 revision");
    assertSelfTest(ondoGm.replacesId === usdy.adapterConfigId, "Ondo GM replacesId 应指向 USDY 配置");
    assertSelfTest(
      usdy.capabilities.tokenStandard === "ERC20" && usdy.capabilities.restrictionMode === "TOKEN_ENFORCED",
      "USDY 适配器应为 ERC20 / TOKEN_ENFORCED",
    );
    assertSelfTest(usdy.capabilities.transferLegMask === 1n << 1n, "USDY 适配器应只服务资产腿");
    assertSelfTest(erc1404.capabilities.restrictionMode === "ISSUER_EXTERNAL", "ERC1404 适配器应为 ISSUER_EXTERNAL");
    assertSelfTest(
      new Set([full.report.configuration.unrestrictedAdapter.adapterConfigId, usdy.adapterConfigId, erc1404.adapterConfigId]).size === 3,
      "三个适配器的配置 ID 应互不相同",
    );
    assertSelfTest(
      full.report.verification.warnings.some((item) => item.includes("allowlist")),
      "DvP 不在 USDY allowlist 时应给出提示",
    );

    console.log("\n=== 自测 5：全部完成后再跑一次，不应发任何交易 ===");
    const again = await deployPlatform(base);
    assertSelfTest(again.sentCount === 0, `重跑不应发交易，实际 ${again.sentCount}`);
    assertSelfTest(again.report.addresses.dvp === full.report.addresses.dvp, "重跑后 DvP 地址不应变化");

    console.log("\n=== 自测 6：丢失状态文件后按链上状态补齐 ===");
    const state = readJson(base.statePath);
    for (const id of ["fee.global.activate", "fee.epoch.activate"]) delete state.steps[id];
    writeJsonAtomic(base.statePath, state);
    const healed = await deployPlatform(base);
    assertSelfTest(healed.sentCount === 0, "链上已生效的步骤不应重发交易");
    assertSelfTest(healed.report.verification.platformReady, "补齐后校验应通过");

    console.log("\n=== 自测 7：DvP 加入 USDY allowlist 后提示消失 ===");
    await callMock("AddressListMock", allowlist, "setAllowed", [full.report.addresses.dvp, true]);
    const allowed = await deployPlatform({ ...base, verify: true });
    assertSelfTest(allowed.report.verification.warnings.length === 0, "加入 allowlist 后不应再有提示");
    assertSelfTest(allowed.report.configuration.assetAdapters.usdyRestricted.tokenState.dvpAllowed === true, "应读到 DvP 已在 allowlist");

    console.log("\n=== 自测 8：USDY 换了 blocklist 后校验失败 ===");
    await callMock("UsdyTokenMock", usdyToken, "configure", [otherBlocklist, allowlist, sanctionsList]);
    rejected = false;
    try {
      await deployPlatform({ ...base, verify: true });
    } catch (error) {
      rejected = /assetAdapters\.usdyRestricted\.providerBindingCurrent/u.test(error.message);
    }
    assertSelfTest(rejected, "代币名单变化后应报 providerBindingCurrent 失败");
    await callMock("UsdyTokenMock", usdyToken, "configure", [blocklist, allowlist, sanctionsList]);
    const restored = await deployPlatform({ ...base, verify: true });
    assertSelfTest(restored.report.verification.platformReady, "名单恢复后校验应通过");

    const summary = buildSummary(restored.report);
    assertSelfTest(summary.configs.assetAdapters.usdyRestricted.restrictionMode === "TOKEN_ENFORCED", "精简版应包含 USDY 适配器配置");
    assertSelfTest(summary.configs.assetAdapters.ondoGm.restrictionMode === "TOKEN_ENFORCED", "精简版应包含 Ondo GM 适配器配置");
    assertSelfTest(summary.configs.assetAdapters.usdyRestricted.isCurrent === false, "精简版应标明 USDY 不是当前 revision");
    assertSelfTest(summary.configs.assetAdapters.ondoGm.isCurrent === true, "精简版应标明 Ondo GM 是当前 revision");
    assertSelfTest(summary.contracts.assetAdapters.erc1404 === erc1404.adapter, "精简版应包含 ERC1404 适配器地址");
  });
  console.log("\n自测全部通过");
}

export function setArtifactsRoot(dir) {
  outRoot = dir;
}

// 供 scripts/ops/deploy-adapter.mjs 复用：步骤执行器、状态文件、链上读取和参数校验。
export {
  ACCESS_ABI,
  ADAPTER_SPECS,
  ANVIL_KEYS,
  DVP_VIEW_ABI,
  RESTRICTED_ADAPTER_KEYS,
  ROLE_ID,
  USDY_LIST_NAMES,
  acquireLock,
  asPrivateKey,
  assertRpcUrl,
  capabilityNames,
  createChainClients,
  detectTokenDeployment,
  enumName,
  ensureBuild,
  hasCode,
  loadArtifact,
  loadState,
  optionalAddress,
  printStatus,
  readJson,
  requireAddress,
  requireProviderCallGas,
  recoverPending,
  runSteps,
  withAnvil,
  writeJsonAtomic,
};

async function main() {
  const flags = parseArgs(process.argv.slice(2));
  if (flags.help) {
    console.log(usage());
    return;
  }
  if (typeof flags.summarize === "string") {
    const reportPath = resolve(process.cwd(), flags.summarize);
    const summaryPath = summaryPathFor(reportPath);
    writeJsonAtomic(summaryPath, buildSummary(readJson(reportPath)));
    console.log(`精简版已写入 ${summaryPath}`);
    return;
  }
  if (typeof flags.artifacts === "string") outRoot = resolve(process.cwd(), flags.artifacts);
  if (flags["self-test"]) {
    await runSelfTest();
    return;
  }
  if (typeof flags.config !== "string") throw new Error(`必须提供 --config\n\n${usage()}`);
  loadTmpEnv();
  await deployPlatform({
    rawConfig: readJson(resolve(process.cwd(), flags.config)),
    rpcUrl: typeof flags.rpc === "string" ? flags.rpc : process.env.HTP_RPC_URL || undefined,
    keys: {
      deployer: process.env.HTP_DEPLOYER_KEY,
      governance: process.env.HTP_GOVERNANCE_KEY,
      configurer: process.env.HTP_CONFIGURER_KEY,
    },
    statePath: typeof flags.state === "string" ? flags.state : undefined,
    outPath: typeof flags.out === "string" ? flags.out : undefined,
    from: typeof flags.from === "string" ? flags.from : undefined,
    until: typeof flags.until === "string" ? flags.until : undefined,
    status: Boolean(flags.status),
    verify: Boolean(flags.verify),
  });
}

const invoked = process.argv[1] !== undefined && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (invoked) {
  main().catch((error) => {
    console.error(`\n错误：${safeErrorMessage(error)}`);
    process.exitCode = 1;
  });
}
