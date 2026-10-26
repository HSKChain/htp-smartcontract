#!/usr/bin/env node
// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
/**
 * 在已经跑完 scripts/ops/deploy-platform.mjs 的平台上追加一个资产适配器：部署 → registerAdapter → activateAdapter。
 *
 * 支持的类型：
 *   usdy          UsdyRestrictedAdapter     ERC20 / TOKEN_ENFORCED，仅资产腿；需要 --token
 *   ondo-gm       OndoGmTokenAdapter        ERC20 / TOKEN_ENFORCED，仅资产腿；--token 是合约族参考 token
 *   erc1404       ERC1404Adapter            ERC1404 / ISSUER_EXTERNAL，仅资产腿；需要 --token
 *   unrestricted  UnrestrictedERC20Adapter  ERC20 / UNRESTRICTED，资产腿和结算腿；不需要 --token
 *
 * 版本链：同一种能力（capabilityHash）的适配器共用一条线性版本链。脚本从链上逐个查 revision 1、2、3…，
 * 新适配器登记为下一个 revision，replacesId 指向当前最新的一条。激活后它成为该能力的“当前”适配器
 * （getCurrentAdapter 返回它），旧配置保持 ACTIVE，已登记的资产版本不受影响；
 * 资产版本必须绑定确切 adapterConfigId；Ondo GM 同 runtime/provider 合约族共用一条配置。
 *
 * 私钥只从环境变量读取（自动加载 tmp/.env，shell 里的同名变量优先）：
 *   HTP_DEPLOYER_KEY     必填，部署适配器
 *   HTP_CONFIGURER_KEY   registerAdapter；不设置则用部署者，需持有 AdapterRegistry 的 CONFIGURER_ROLE
 *   HTP_GOVERNANCE_KEY   activateAdapter；不设置则用部署者，需持有 AdapterRegistry 的 GOVERNANCE_ROLE
 *
 * 用法（仓库根目录）：
 *   node scripts/ops/deploy-adapter.mjs --type usdy --token 0x...
 *   node scripts/ops/deploy-adapter.mjs --type ondo-gm --token 0x... # 参考 token
 *   node scripts/ops/deploy-adapter.mjs --type erc1404 --token 0x... --no-activate
 *   node scripts/ops/deploy-adapter.mjs --type usdy --token 0x... --status
 *   node scripts/ops/deploy-adapter.mjs --self-test
 *
 * 每步完成后写状态文件，失败后重跑同一条命令即可续跑；全部完成后重跑不会再发交易。
 * 结果合并写入 tmp/out/adapters.<chainId>.json（按 adapterConfigId 去重）。
 */

import { existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { createPublicClient, createWalletClient, defineChain, getAddress, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  ACCESS_ABI,
  ADAPTER_SPECS,
  ANVIL_KEYS,
  DVP_VIEW_ABI,
  ONDO_GM_IDENTIFIER,
  ROLE_ID,
  USDY_LIST_NAMES,
  acquireLock,
  adapterConfigIdFor,
  adapterConstructorArgs,
  asPrivateKey,
  assertMainnetOndoEvidence,
  assertProviderBinding,
  assertRpcUrl,
  capabilityNames,
  createChainClients,
  deployPlatform,
  enumName,
  ensureBuild,
  hasCode,
  loadArtifact,
  loadState,
  optionalAddress,
  printStatus,
  readAdapterConfig,
  readOndoGmDvpState,
  readJson,
  readRestrictedBinding,
  readUsdyDvpState,
  requireAddress,
  requireProviderCallGas,
  runSteps,
  setArtifactsRoot,
  withAnvil,
  writeJsonAtomic,
} from "./deploy-platform.mjs";
import { Enum, ZERO_BYTES32 } from "./lib/htp-hash.mjs";
import { loadTmpEnv, safeErrorMessage } from "./lib/env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const tmpOutRoot = join(repoRoot, "tmp", "out");
const MAX_REVISION_SCAN = 1_000;

const TYPES = Object.freeze({
  usdy: "usdyRestricted",
  "ondo-gm": "ondoGm",
  erc1404: "erc1404",
  unrestricted: "unrestricted",
});


function usage() {
  return `node scripts/ops/deploy-adapter.mjs --type <usdy|ondo-gm|erc1404|unrestricted> [options]

选项：
  --type <type>            usdy / ondo-gm / erc1404 / unrestricted
  --token <address>        受限类型必填；ondo-gm 中是合约族参考 token
  --blocklist <address>    仅 usdy：不填则从代币读取，填了必须与代币当前值一致
  --allowlist <address>    同上
  --sanctions-list <addr>  同上
  --provider-gas <n>       适配器每次外部调用的 gas 上限，1-100000，默认 100000
  --report <path>          平台精简版或部署报告，默认 tmp/out/platform-summary.json
  --rpc <url>              RPC，也可用 HTP_RPC_URL（报告里不含 RPC）
  --state <path>           状态文件，默认 tmp/out/adapter-state.<chainId>.<type>.<token>.json
  --out <path>             结果汇总，默认 tmp/out/adapters.<chainId>.json
  --artifacts <dir>        编译产物目录，默认 contracts/out
  --no-activate            只部署和登记，不激活（稍后去掉该选项重跑即可激活）
  --status                 只打印进度，不发交易
  --self-test              在 127.0.0.1 拉起 Anvil 做完整验收

环境变量：HTP_DEPLOYER_KEY（必填）、HTP_CONFIGURER_KEY、HTP_GOVERNANCE_KEY、HTP_RPC_URL
          会自动读取 tmp/.env，shell 里设置的同名变量优先
`;
}

const KNOWN_FLAGS = new Set([
  "type",
  "token",
  "blocklist",
  "allowlist",
  "sanctions-list",
  "provider-gas",
  "report",
  "rpc",
  "state",
  "out",
  "artifacts",
  "no-activate",
  "status",
  "self-test",
  "help",
]);

function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) throw new Error(`未知参数: ${token}`);
    const key = token.slice(2);
    if (key === "private-key") throw new Error("不支持 --private-key，私钥请用环境变量传入");
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
// 参数与平台信息
// ---------------------------------------------------------------------------

export function normalizeRequest(raw) {
  const key = TYPES[String(raw.type ?? "").toLowerCase()];
  if (!key) throw new Error(`--type 只能是 ${Object.keys(TYPES).join(" / ")}`);
  if (key === "unrestricted") {
    if (raw.token || USDY_LIST_NAMES.some((name) => raw[name]) || raw.providerCallGas) {
      throw new Error("unrestricted 适配器不绑定代币，不接受 --token / 名单 / --provider-gas");
    }
    return { key, spec: null };
  }
  const providerCallGas =
    typeof raw.providerCallGas === "string" && /^(0|[1-9]\d*)$/u.test(raw.providerCallGas)
      ? Number(raw.providerCallGas)
      : raw.providerCallGas;
  const spec = {
    token: requireAddress(raw.token, "--token"),
    providerCallGas: requireProviderCallGas(providerCallGas, "--provider-gas"),
  };
  if (key === "usdyRestricted") {
    for (const name of USDY_LIST_NAMES) spec[name] = optionalAddress(raw[name], `--${name === "sanctionsList" ? "sanctions-list" : name}`);
  } else if (USDY_LIST_NAMES.some((name) => raw[name])) {
    throw new Error("名单参数只适用于 --type usdy");
  }
  return { key, spec };
}

/** 兼容完整报告（platform-deployment.json）和精简版（platform-summary.json）。 */
export function loadPlatform(reportPath) {
  if (!existsSync(reportPath)) {
    throw new Error(`找不到平台部署报告 ${reportPath}；请先跑 scripts/ops/deploy-platform.mjs，或用 --report 指定`);
  }
  const report = readJson(reportPath);
  const chainId = report.metadata?.chainId ?? report.chainId;
  const finalityConfirmations = report.metadata?.finalityConfirmations ?? report.finalityConfirmations;
  const dvp = report.addresses?.dvp ?? report.contracts?.dvp;
  const adapterRegistry = report.addresses?.registries?.adapter ?? report.contracts?.registries?.adapter;
  if (!Number.isSafeInteger(chainId) || chainId <= 0 || !dvp || !adapterRegistry) {
    throw new Error(`${reportPath} 里缺少合法的 chainId / dvp / registries.adapter`);
  }
  if (!Number.isSafeInteger(finalityConfirmations) || finalityConfirmations <= 0) {
    throw new Error(`${reportPath} 里缺少合法的 metadata.finalityConfirmations`);
  }
  return {
    chainId,
    finalityConfirmations,
    dvp: requireAddress(dvp, "报告中的 dvp"),
    adapterRegistry: requireAddress(adapterRegistry, "报告中的 registries.adapter"),
  };
}

export function assertAdapterChainPolicy(chainId, key) {
  if ((chainId === 133 || chainId === 177) && (key === "ondoGm" || key === "erc1404")) {
    throw new Error("HSK 只上 USDY，不允许部署 Ondo GM 或 ERC1404 Adapter");
  }
}

function loadSigners(keys) {
  const deployerKey = asPrivateKey(keys.deployer, "HTP_DEPLOYER_KEY");
  if (!deployerKey) throw new Error("必须设置环境变量 HTP_DEPLOYER_KEY");
  const deployer = privateKeyToAccount(deployerKey);
  const optional = (value, name) => {
    const key = asPrivateKey(value, name);
    return key ? privateKeyToAccount(key) : deployer;
  };
  return {
    deployer,
    configurer: optional(keys.configurer, "HTP_CONFIGURER_KEY"),
    governance: optional(keys.governance, "HTP_GOVERNANCE_KEY"),
  };
}

// ---------------------------------------------------------------------------
// 版本链
// ---------------------------------------------------------------------------

function registryAbi() {
  return loadArtifact("AdapterRegistry").abi;
}

function getAdapterRecord(ctx, adapterConfigId) {
  return ctx.publicClient.readContract({
    address: ctx.platform.adapterRegistry,
    abi: registryAbi(),
    functionName: "getAdapter",
    args: [adapterConfigId],
  });
}

function deployedAdapter(ctx) {
  const entry = ctx.state.steps["adapter.deploy"];
  if (entry?.status !== "done" || !entry.address) throw new Error("适配器尚未部署");
  return getAddress(entry.address);
}

/**
 * 沿版本链从 revision 1 往后查：遇到本适配器说明已登记过；遇到空位就是下一个 revision。
 * 每次都现查，不缓存，这样登记交易上链后 check 能立即看到结果。
 */
async function resolveRegistration(ctx) {
  const { chainId, key } = ctx;
  const adapter = deployedAdapter(ctx);
  const probe = await readAdapterConfig(ctx.publicClient, chainId, key, adapter, { revision: 1, replacesId: ZERO_BYTES32 });
  let latestId = ZERO_BYTES32;
  for (let revision = 1; revision <= MAX_REVISION_SCAN; revision += 1) {
    const adapterConfigId = adapterConfigIdFor(chainId, probe.capabilityHash, revision);
    const record = await getAdapterRecord(ctx, adapterConfigId);
    if (!record.exists) {
      const config = await readAdapterConfig(ctx.publicClient, chainId, key, adapter, { revision, replacesId: latestId });
      return { registered: false, config, record: null };
    }
    if (getAddress(record.config.adapter) === adapter) {
      const config = await readAdapterConfig(ctx.publicClient, chainId, key, adapter, {
        revision,
        replacesId: record.config.replacesId,
      });
      if (record.config.configHash !== config.configHash) {
        throw new Error(`链上 revision ${revision} 登记的是本适配器，但 configHash 与本地重算不一致（链上 ${record.config.configHash}）`);
      }
      return { registered: true, config, record };
    }
    latestId = adapterConfigId;
  }
  throw new Error(`版本链超过 ${MAX_REVISION_SCAN} 条，停止扫描`);
}

async function binding(ctx) {
  if (ctx.key === "unrestricted") return null;
  if (!ctx.binding) ctx.binding = await readRestrictedBinding(ctx.publicClient, ctx.key, ctx.spec, `--type ${ctx.type}`);
  return ctx.binding;
}

// ---------------------------------------------------------------------------
// 步骤
// ---------------------------------------------------------------------------

function buildSteps(key, noActivate) {
  const spec = ADAPTER_SPECS[key];
  const steps = [
    {
      id: "adapter.deploy",
      phase: "adapter",
      title: `部署 ${spec.contract}`,
      kind: "deploy",
      signer: "deployer",
      build: async (ctx) => ({
        artifact: loadArtifact(spec.contract),
        args: adapterConstructorArgs(key, ctx.platform.dvp, await binding(ctx)),
      }),
    },
    {
      id: "adapter.register",
      phase: "adapter",
      title: "registerAdapter",
      kind: "write",
      signer: "configurer",
      build: async (ctx) => {
        const { registered, config } = await resolveRegistration(ctx);
        if (registered) throw new Error("适配器已登记，不应再发送 registerAdapter");
        if (key !== "unrestricted") assertProviderBinding(key, await binding(ctx), config);
        console.log(`    登记为 revision ${config.revision}${config.revision > 1 ? `，replacesId ${config.replacesId}` : ""}`);
        return {
          address: ctx.platform.adapterRegistry,
          abi: registryAbi(),
          functionName: "registerAdapter",
          args: [config],
        };
      },
      check: async (ctx) => (await resolveRegistration(ctx)).registered,
    },
  ];
  if (!noActivate) {
    steps.push({
      id: "adapter.activate",
      phase: "adapter",
      title: "activateAdapter",
      kind: "write",
      signer: "governance",
      build: async (ctx) => {
        const { registered, config } = await resolveRegistration(ctx);
        if (!registered) throw new Error("适配器尚未登记，不能激活");
        if (key !== "unrestricted") {
          const current = await readRestrictedBinding(ctx.publicClient, key, ctx.spec, `--type ${ctx.type}`);
          assertProviderBinding(key, current, config);
        }
        if (config.revision > 1) {
          console.log(`    激活后 getCurrentAdapter 将指向本适配器（revision ${config.revision}），旧配置保持 ACTIVE`);
        }
        return {
          address: ctx.platform.adapterRegistry,
          abi: registryAbi(),
          functionName: "activateAdapter",
          args: [config.adapterConfigId, config.configHash],
        };
      },
      check: async (ctx) => {
        const { registered, record } = await resolveRegistration(ctx);
        return registered && Number(record.status) === Enum.AdapterStatus.ACTIVE;
      },
    });
  }
  return steps;
}

// ---------------------------------------------------------------------------
// 预检与结果
// ---------------------------------------------------------------------------

async function preflight(ctx, steps) {
  const { publicClient, platform } = ctx;
  if (!(await hasCode(publicClient, platform.dvp))) throw new Error(`DvP ${platform.dvp} 在当前链上没有代码，报告与 RPC 不是同一条链？`);
  const boundRegistry = getAddress(
    await publicClient.readContract({ address: platform.dvp, abi: DVP_VIEW_ABI, functionName: "adapterRegistry" }),
  );
  if (boundRegistry !== platform.adapterRegistry) {
    throw new Error(`DvP 绑定的 AdapterRegistry 是 ${boundRegistry}，报告里是 ${platform.adapterRegistry}`);
  }

  const pending = steps.filter((step) => ctx.state.steps[step.id]?.status !== "done");
  const requiredRole = { configurer: "CONFIGURER_ROLE", governance: "GOVERNANCE_ROLE" };
  const envName = { configurer: "HTP_CONFIGURER_KEY", governance: "HTP_GOVERNANCE_KEY" };
  for (const signer of new Set(pending.map((step) => step.signer))) {
    const account = ctx.signers[signer];
    if (requiredRole[signer]) {
      const granted = await publicClient.readContract({
        address: platform.adapterRegistry,
        abi: ACCESS_ABI,
        functionName: "hasRole",
        args: [ROLE_ID[requiredRole[signer]], account.address],
      });
      if (!granted) {
        throw new Error(
          `${account.address} 没有 AdapterRegistry 的 ${requiredRole[signer]}；` +
            `请设置 ${envName[signer]} 为持有该角色的私钥，或先用 scripts/ops/grant-gov-cfg.mjs 授权`,
        );
      }
    }
    if ((await publicClient.getBalance({ address: account.address })) === 0n) {
      throw new Error(`${signer} ${account.address} 余额为 0，付不起 gas`);
    }
  }

  if (ctx.key !== "unrestricted" && pending.some((step) => step.id !== "adapter.activate")) {
    const bound = await binding(ctx);
    console.log(`绑定代币 ${bound.token}（providerCallGas ${bound.providerCallGas}）`);
    if (ctx.key === "usdyRestricted") {
      console.log(`  blocklist ${bound.blocklist}  allowlist ${bound.allowlist}  sanctionsList ${bound.sanctionsList}`);
    } else if (ctx.key === "ondoGm") {
      console.log(
        `  complianceView ${bound.complianceView}  compliance ${bound.compliance}  pauseManager ${bound.pauseManager}`,
      );
      console.log(`  blocklist ${bound.blocklist}  sanctionsList ${bound.sanctionsList}`);
    }
  }
}

async function buildResult(ctx) {
  const { registered, config, record } = await resolveRegistration(ctx);
  const current = await ctx.publicClient.readContract({
    address: ctx.platform.adapterRegistry,
    abi: registryAbi(),
    functionName: "getCurrentAdapter",
    args: [config.capabilityHash],
  });
  const entry = {
    type: ctx.type,
    contract: ADAPTER_SPECS[ctx.key].contract,
    adapter: config.adapter,
    adapterConfigId: config.adapterConfigId,
    configHash: config.configHash,
    revision: config.revision,
    replacesId: config.replacesId,
    capabilityHash: config.capabilityHash,
    providerHash: config.providerHash,
    capabilities: capabilityNames(config.capabilities),
    status: registered ? enumName(Enum.AdapterStatus, record.status) : "NONE",
    isCurrent: current.exists && current.config.adapterConfigId === config.adapterConfigId,
    binding: null,
    warnings: [],
    transactions: Object.fromEntries(
      Object.entries(ctx.state.steps)
        .filter(([, item]) => item.txHash)
        .map(([id, item]) => [id, item.txHash]),
    ),
    updatedAt: new Date().toISOString(),
  };
  if (ctx.key !== "unrestricted") {
    const bound = await readRestrictedBinding(ctx.publicClient, ctx.key, ctx.spec, `--type ${ctx.type}`);
    entry.binding = bound;
    entry.providerBindingCurrent = bound.providerHash === config.providerHash;
    if (!entry.providerBindingCurrent) entry.warnings.push("代币或名单在适配器部署后变了，适配器会返回 PROVIDER_MISMATCH");
    if (ctx.key === "usdyRestricted") {
      const state = await readUsdyDvpState(ctx.publicClient, bound, ctx.platform.dvp);
      entry.tokenState = state.tokenState;
      entry.warnings.push(...state.warnings);
    } else if (ctx.key === "ondoGm") {
      const state = await readOndoGmDvpState(ctx.publicClient, bound, ctx.platform.dvp);
      entry.tokenState = state.tokenState;
      entry.warnings.push(...state.warnings);
    }
  }
  if (entry.status !== "ACTIVE") entry.warnings.push(`适配器状态为 ${entry.status}，资产版本只能引用 ACTIVE 的适配器`);
  return entry;
}

function mergeIndex(outPath, platform, entry) {
  const index = existsSync(outPath)
    ? readJson(outPath)
    : { chainId: platform.chainId, dvp: platform.dvp, adapterRegistry: platform.adapterRegistry, adapters: [] };
  if (index.dvp !== platform.dvp || index.chainId !== platform.chainId) {
    throw new Error(`${outPath} 属于另一套部署（DvP ${index.dvp}），请用 --out 指定新文件`);
  }
  index.adapters = [...index.adapters.filter((item) => item.adapterConfigId !== entry.adapterConfigId), entry].sort(
    (a, b) => a.capabilityHash.localeCompare(b.capabilityHash) || a.revision - b.revision,
  );
  index.updatedAt = entry.updatedAt;
  writeJsonAtomic(outPath, index);
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/**
 * options: { reportPath, rpcUrl, type, token?, blocklist?, allowlist?, sanctionsList?, providerCallGas?,
 *            keys: {deployer, configurer, governance}, statePath?, outPath?, noActivate?, status? }
 */
export async function deployAdapter(options) {
  const { key, spec } = normalizeRequest(options);
  const type = String(options.type).toLowerCase();
  const platform = loadPlatform(resolve(options.reportPath ?? join(tmpOutRoot, "platform-summary.json")));
  assertAdapterChainPolicy(platform.chainId, key);
  const steps = buildSteps(key, Boolean(options.noActivate));
  const tokenTag = spec ? spec.token.toLowerCase() : "none";
  const statePath = resolve(
    options.statePath ?? join(tmpOutRoot, `adapter-state.${platform.chainId}.${type}.${tokenTag}.json`),
  );
  const outPath = resolve(options.outPath ?? join(tmpOutRoot, `adapters.${platform.chainId}.json`));

  if (options.status) {
    printStatus(steps, existsSync(statePath) ? readJson(statePath) : { steps: {} });
    return null;
  }

  const rpcUrl = String(options.rpcUrl ?? "");
  if (!rpcUrl) throw new Error("缺少 RPC：用 --rpc 或 HTP_RPC_URL 指定");
  assertRpcUrl(rpcUrl);
  const probeClient = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await probeClient.getChainId();
  if (chainId !== platform.chainId) throw new Error(`RPC 返回 chainId=${chainId}，报告里是 ${platform.chainId}`);
  if (key === "ondoGm") {
    await assertMainnetOndoEvidence({
      chainId,
      config: { assetAdapters: { ondoGm: spec } },
      publicClient: probeClient,
    });
  }

  ensureBuild();
  const signers = loadSigners(options.keys ?? {});
  const fingerprint = {
    chainId,
    dvp: platform.dvp,
    adapterRegistry: platform.adapterRegistry,
    type,
    token: spec?.token ?? null,
    providerCallGas: spec?.providerCallGas ?? null,
    deployer: signers.deployer.address,
  };
  const releaseLock = acquireLock(statePath);
  try {
    const state = loadState(statePath, fingerprint);
    const { publicClient, wallets } = createChainClients(rpcUrl, chainId, signers);
    const ctx = {
      chainId,
      key,
      type,
      spec,
      platform,
      publicClient,
      wallets,
      signers,
      finalityConfirmations: platform.finalityConfirmations,
      state,
      binding: null,
      nextNonce: new Map(),
      sentCount: 0,
      saveState: () => {
        state.updatedAt = new Date().toISOString();
        writeJsonAtomic(statePath, state);
      },
    };
    ctx.saveState();
    console.log(`chainId=${chainId} DvP=${platform.dvp} AdapterRegistry=${platform.adapterRegistry}`);
    console.log(`状态文件 ${statePath}`);

    await preflight(ctx, steps);
    await runSteps(ctx, steps, { from: null, start: 0, end: steps.length - 1 });

    const entry = await buildResult(ctx);
    mergeIndex(outPath, platform, entry);
    console.log(`\n结果已写入 ${outPath}`);
    console.log(`本次发送 ${ctx.sentCount} 笔交易`);
    console.log(`${entry.contract}: ${entry.adapter}`);
    console.log(`  revision ${entry.revision}  adapterConfigId ${entry.adapterConfigId}  ${entry.status}${entry.isCurrent ? "（当前）" : ""}`);
    for (const warning of entry.warnings) console.log(`注意：${warning}`);
    return { entry, sentCount: ctx.sentCount };
  } finally {
    releaseLock();
  }
}

// ---------------------------------------------------------------------------
// 自测（仅 127.0.0.1 Anvil，使用 Anvil 公开测试私钥）
// ---------------------------------------------------------------------------

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
  const workDir = join(tmpOutRoot, "self-test-adapter");
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
    const lists = [await deployMock("AddressListMock"), await deployMock("AddressListMock"), await deployMock("AddressListMock")];
    const usdyA = await deployMock("UsdyTokenMock");
    const usdyB = await deployMock("UsdyTokenMock");
    await callMock("UsdyTokenMock", usdyA, "configure", lists);
    await callMock("UsdyTokenMock", usdyB, "configure", lists);
    const erc1404Token = await deployMock("ERC1404TokenMock");
    const deployGmToken = async () => {
      const blocklist = await deployMock("OndoGmListMock");
      const sanctionsList = await deployMock("OndoGmListMock");
      const pauseManager = await deployMock("OndoGmPauseManagerMock");
      const compliance = await deployMock("OndoComplianceMock");
      const complianceView = await deployMock("OndoComplianceViewMock", [compliance, ONDO_GM_IDENTIFIER]);
      const token = await deployMock("IntegrationOndoGmToken", [complianceView, pauseManager]);
      await callMock("OndoComplianceMock", compliance, "configure", [
        ONDO_GM_IDENTIFIER,
        blocklist,
        sanctionsList,
      ]);
      return token;
    };
    const gmTokenA = await deployGmToken();
    const gmTokenB = await deployGmToken();

    const reportPath = join(workDir, "platform-deployment.json");
    const platform = await deployPlatform({
      rawConfig: {
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
        calculators: ["FUND"],
        assetAdapters: { usdyRestricted: { token: usdyA } },
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
      keys: { deployer: ANVIL_KEYS[0], governance: ANVIL_KEYS[1], configurer: ANVIL_KEYS[2] },
      statePath: join(workDir, "platform-state.json"),
      outPath: reportPath,
    });
    const firstUsdy = platform.report.configuration.assetAdapters.usdyRestricted;
    const dvp = platform.report.addresses.dvp;
    await callMock("AddressListMock", lists[1], "setAllowed", [dvp, true]);

    const keys = { deployer: ANVIL_KEYS[0], configurer: ANVIL_KEYS[2], governance: ANVIL_KEYS[1] };
    const base = { reportPath, rpcUrl, keys, outPath: join(workDir, "adapters.json") };
    const statePath = (name) => join(workDir, `state-${name}.json`);

    console.log("\n=== 自测 1：缺少治理私钥（部署者没有 GOVERNANCE_ROLE）时，发交易前拒绝 ===");
    const nonceBefore = await publicClient.getTransactionCount({ address: deployer.address });
    let rejected = false;
    try {
      await deployAdapter({
        ...base,
        keys: { deployer: ANVIL_KEYS[0], configurer: ANVIL_KEYS[2] },
        type: "usdy",
        token: usdyB,
        statePath: statePath("no-gov"),
      });
    } catch (error) {
      rejected = /GOVERNANCE_ROLE/u.test(error.message);
    }
    assertSelfTest(rejected, "部署者没有 GOVERNANCE_ROLE 时应报错");
    assertSelfTest(
      (await publicClient.getTransactionCount({ address: deployer.address })) === nonceBefore,
      "角色不足时不应发出任何交易",
    );

    console.log("\n=== 自测 2：Ondo GM 与 USDY 共用 capability revision 链 ===");
    const firstGm = await deployAdapter({
      ...base,
      type: "ondo-gm",
      token: gmTokenA,
      statePath: statePath("gm-a"),
    });
    assertSelfTest(firstGm.sentCount === 3, `应发 3 笔交易，实际 ${firstGm.sentCount}`);
    assertSelfTest(firstGm.entry.revision === 2, `应为 revision 2，实际 ${firstGm.entry.revision}`);
    assertSelfTest(firstGm.entry.replacesId === firstUsdy.adapterConfigId, "GM replacesId 应指向平台部署的 USDY 适配器");
    assertSelfTest(firstGm.entry.capabilityHash === firstUsdy.capabilityHash, "USDY / GM capabilityHash 应相同");
    assertSelfTest(firstGm.entry.status === "ACTIVE" && firstGm.entry.isCurrent, "首个 GM 适配器应 ACTIVE 且是当前配置");
    assertSelfTest(firstGm.entry.binding.token === gmTokenA, "首个 GM 适配器应绑定指定代币");
    const oldUsdyRecord = await publicClient.readContract({
      address: platform.report.addresses.registries.adapter,
      abi: loadArtifact("AdapterRegistry").abi,
      functionName: "getAdapter",
      args: [firstUsdy.adapterConfigId],
    });
    assertSelfTest(Number(oldUsdyRecord.status) === Enum.AdapterStatus.ACTIVE, "旧 USDY 适配器应保持 ACTIVE");

    const secondGm = await deployAdapter({
      ...base,
      type: "ondo-gm",
      token: gmTokenB,
      statePath: statePath("gm-b"),
    });
    assertSelfTest(secondGm.entry.revision === 3, `第二个 GM 应为 revision 3，实际 ${secondGm.entry.revision}`);
    assertSelfTest(secondGm.entry.replacesId === firstGm.entry.adapterConfigId, "第二个 GM replacesId 应指向首个 GM");
    const oldGmRecord = await publicClient.readContract({
      address: platform.report.addresses.registries.adapter,
      abi: loadArtifact("AdapterRegistry").abi,
      functionName: "getAdapter",
      args: [firstGm.entry.adapterConfigId],
    });
    assertSelfTest(Number(oldGmRecord.status) === Enum.AdapterStatus.ACTIVE, "旧 GM 适配器应保持 ACTIVE");

    console.log("\n=== 自测 3：重跑不发交易 ===");
    const again = await deployAdapter({ ...base, type: "ondo-gm", token: gmTokenB, statePath: statePath("gm-b") });
    assertSelfTest(again.sentCount === 0, `重跑不应发交易，实际 ${again.sentCount}`);
    assertSelfTest(again.entry.adapter === secondGm.entry.adapter, "重跑后地址不应变化");

    console.log("\n=== 自测 4：ERC-1404 先只登记不激活，再激活 ===");
    const staged = await deployAdapter({
      ...base,
      type: "erc1404",
      token: erc1404Token,
      statePath: statePath("erc1404"),
      noActivate: true,
    });
    assertSelfTest(staged.entry.revision === 1 && staged.entry.status === "REGISTERED", "应登记为 revision 1 且未激活");
    const originalErc1404Code = await publicClient.getCode({ address: erc1404Token });
    await publicClient.request({ method: "anvil_setCode", params: [erc1404Token, "0x60006000fd"] });
    const governanceNonceBefore = await publicClient.getTransactionCount({ address: governance.address });
    rejected = false;
    try {
      await deployAdapter({ ...base, type: "erc1404", token: erc1404Token, statePath: statePath("erc1404") });
    } catch (error) {
      rejected = /providerHash/u.test(error.message);
    }
    assertSelfTest(rejected, "登记后 provider 漂移时激活应失败");
    assertSelfTest(
      (await publicClient.getTransactionCount({ address: governance.address })) === governanceNonceBefore,
      "provider 漂移时不应发出激活交易",
    );
    await publicClient.request({ method: "anvil_setCode", params: [erc1404Token, originalErc1404Code] });
    const activated = await deployAdapter({ ...base, type: "erc1404", token: erc1404Token, statePath: statePath("erc1404") });
    assertSelfTest(activated.sentCount === 1, `激活应只发 1 笔交易，实际 ${activated.sentCount}`);
    assertSelfTest(activated.entry.status === "ACTIVE" && activated.entry.capabilities.restrictionMode === "ISSUER_EXTERNAL", "ERC-1404 适配器应已激活");

    console.log("\n=== 自测 5：结果汇总按配置 ID 合并 ===");
    const index = readJson(base.outPath);
    assertSelfTest(index.dvp === dvp, "汇总文件应记录 DvP");
    assertSelfTest(index.adapters.length === 3, `汇总应有 3 个适配器，实际 ${index.adapters.length}`);
  });
  console.log("\n自测全部通过");
}

async function main() {
  const flags = parseArgs(process.argv.slice(2));
  if (flags.help) {
    console.log(usage());
    return;
  }
  if (typeof flags.artifacts === "string") setArtifactsRoot(resolve(process.cwd(), flags.artifacts));
  if (flags["self-test"]) {
    await runSelfTest();
    return;
  }
  if (typeof flags.type !== "string") throw new Error(`必须提供 --type\n\n${usage()}`);
  loadTmpEnv();
  const text = (name) => (typeof flags[name] === "string" ? flags[name] : undefined);
  await deployAdapter({
    type: flags.type,
    token: text("token"),
    blocklist: text("blocklist"),
    allowlist: text("allowlist"),
    sanctionsList: text("sanctions-list"),
    providerCallGas: text("provider-gas"),
    reportPath: text("report") ? resolve(process.cwd(), text("report")) : undefined,
    rpcUrl: text("rpc") ?? (process.env.HTP_RPC_URL || undefined),
    keys: {
      deployer: process.env.HTP_DEPLOYER_KEY,
      configurer: process.env.HTP_CONFIGURER_KEY,
      governance: process.env.HTP_GOVERNANCE_KEY,
    },
    statePath: text("state") ? resolve(process.cwd(), text("state")) : undefined,
    outPath: text("out") ? resolve(process.cwd(), text("out")) : undefined,
    noActivate: Boolean(flags["no-activate"]),
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
