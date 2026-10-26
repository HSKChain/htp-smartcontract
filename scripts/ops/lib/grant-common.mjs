// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
// grant-executor / grant-gov-cfg / grant-admin 共用：参数解析、读部署地址、管理员预检、逐笔授权并确认生效。
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  stringToHex,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { readTmpEnvVar, safeErrorMessage } from "./env.mjs";

const tmpDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..", "tmp");
// 报告不含 RPC：已知链用内置端点，其他链用 HTP_RPC_URL；没有报告 chainId 时按 133 处理
const DEFAULT_CHAIN_ID = 133;
const DEFAULT_RPC_URLS = Object.freeze({ 133: "https://testnet.hashkeychain.net" });
const DEFAULT_REPORTS = [join(tmpDir, "out", "platform-summary.json"), join(tmpDir, "out", "platform-deployment.json")];
const VISIBILITY_TIMEOUT_MS = 60_000;
const RECEIPT_TIMEOUT_MS = 180_000;
const RECEIPT_BLOCK_BUDGET_MS = 30_000;

export const ROLE_IDS = Object.freeze({
  DEFAULT_ADMIN: `0x${"00".repeat(32)}`,
  GOVERNANCE: keccak256(stringToHex("GOVERNANCE_ROLE")),
  CONFIGURER: keccak256(stringToHex("CONFIGURER_ROLE")),
  EXECUTOR: keccak256(stringToHex("EXECUTOR_ROLE")),
});

const REGISTRY_NAMES = Object.freeze({
  adapter: "AdapterRegistry",
  calculator: "PrincipalCalculatorRegistry",
  settlementToken: "SettlementTokenRegistry",
  assetVersion: "AssetVersionRegistry",
  eligibility: "EligibilityRegistry",
  fee: "FeeRegistry",
  marketRule: "MarketRuleRegistry",
  participant: "ParticipantRegistry",
});

const ACCESS_ABI = parseAbi([
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function grantRole(bytes32 role, address account)",
  "function renounceRole(bytes32 role, address callerConfirmation)",
]);

export const COMMON_OPTIONS_HELP = `  --account <addr>   被授权地址（必填）
  --report <path>    精简版或部署报告 JSON，默认 tmp/out/platform-summary.json
  --dvp <addr>       直接指定 DvP 地址，覆盖报告里的
  --finality-confirmations <n>  不使用报告时必填
  --rpc <url>        RPC；不传时按报告 chainId 选：133 用 ${DEFAULT_RPC_URLS[133]}，其他链用 HTP_RPC_URL
  --dry-run          只打印计划和当前持有情况，不发交易
  --help             打印帮助

RPC 的 chainId 必须与报告一致，否则不执行。
私钥：只读 HTP_ADMIN_KEY（DEFAULT_ADMIN_ROLE 持有者），shell 变量优先，其次 tmp/.env`;

export function parseArgs(argv, extraFlags = [], usage = "") {
  const known = new Set([
    "account",
    "report",
    "dvp",
    "finality-confirmations",
    "rpc",
    "dry-run",
    "help",
    ...extraFlags,
  ]);
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) throw new Error(`未知参数: ${token}`);
    const key = token.slice(2);
    if (key === "private-key") throw new Error("不支持 --private-key，请在 tmp/.env 里设置 HTP_ADMIN_KEY");
    if (!known.has(key)) throw new Error(`未知选项: --${key}\n\n${usage}`);
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

export function asAddress(value, label) {
  if (value === undefined || value === null || value === "" || value === true) return null;
  if (!isAddress(value, { strict: false })) throw new Error(`${label} 不是合法地址: ${value}`);
  const address = getAddress(value);
  if (address === zeroAddress) throw new Error(`${label} 不能是零地址`);
  return address;
}

export function requireAccount(flags, usage) {
  const account = asAddress(flags.account, "--account");
  if (!account) throw new Error(`请传 --account\n\n${usage}`);
  return account;
}

export function loadDeployment(flags, defaultReports = DEFAULT_REPORTS) {
  const candidates = flags.report ? [resolve(process.cwd(), flags.report)] : defaultReports;
  const reportPath = candidates.find((path) => existsSync(path));
  if (flags.report && !reportPath) throw new Error(`找不到报告文件 ${candidates[0]}`);
  const report = reportPath ? JSON.parse(readFileSync(reportPath, "utf8")) : null;
  const registriesRaw = report?.addresses?.registries ?? report?.contracts?.registries ?? {};
  const registries = Object.entries(REGISTRY_NAMES).map(([key, name]) => ({
    name,
    address: asAddress(registriesRaw[key], `registries.${key}`),
  }));
  const dvp = asAddress(flags.dvp, "--dvp") ?? asAddress(report?.addresses?.dvp ?? report?.contracts?.dvp, "report.dvp");
  const chainId = report?.metadata?.chainId ?? report?.chainId ?? null;
  if (report && flags["finality-confirmations"] !== undefined) {
    throw new Error("使用部署报告时不允许覆盖 finalityConfirmations");
  }
  const rawFinality = report
    ? report.metadata?.finalityConfirmations ?? report.finalityConfirmations
    : flags["finality-confirmations"];
  const finalityConfirmations =
    typeof rawFinality === "string" && /^[1-9]\d*$/u.test(rawFinality) ? Number(rawFinality) : rawFinality;
  if (report && (!Number.isSafeInteger(chainId) || chainId <= 0)) throw new Error(`报告 chainId 非法: ${chainId}`);
  if (!Number.isSafeInteger(finalityConfirmations) || finalityConfirmations <= 0) {
    throw new Error(`报告 finalityConfirmations 非法: ${finalityConfirmations}`);
  }
  return {
    reportPath: reportPath ?? null,
    chainId,
    finalityConfirmations,
    dvp() {
      if (!dvp) throw new Error("找不到 DvP 地址，请用 --report 或 --dvp 指定");
      return { name: "DvPSettlement", address: dvp };
    },
    registries() {
      const missing = registries.filter((item) => !item.address).map((item) => item.name);
      if (missing.length > 0) throw new Error(`报告里缺少 ${missing.join(", ")} 地址，请用 --report 指定部署报告`);
      return registries;
    },
  };
}

export async function connect(flags, deployment) {
  const expectedChainId = deployment.chainId ?? DEFAULT_CHAIN_ID;
  const rpcUrl =
    (typeof flags.rpc === "string" ? flags.rpc : null) ??
    DEFAULT_RPC_URLS[expectedChainId] ??
    readTmpEnvVar("HTP_RPC_URL");
  if (!rpcUrl) throw new Error(`报告 chainId=${expectedChainId} 没有内置 RPC，请用 --rpc 或在 tmp/.env 设置 HTP_RPC_URL`);
  if (!/^https?:\/\/127\.0\.0\.1(?::\d+)?(?:\/|$)/u.test(rpcUrl) && !/^https:\/\//u.test(rpcUrl)) {
    throw new Error("RPC 只允许 https 公网端点或 http://127.0.0.1");
  }
  const rawKey = readTmpEnvVar("HTP_ADMIN_KEY");
  if (!rawKey) throw new Error("请在 tmp/.env 里设置 HTP_ADMIN_KEY（DEFAULT_ADMIN_ROLE 持有者私钥）");
  const privateKey = rawKey.startsWith("0x") ? rawKey : `0x${rawKey}`;
  if (!/^0x[0-9a-fA-F]{64}$/u.test(privateKey)) throw new Error("HTP_ADMIN_KEY 必须是 32 字节 hex 私钥");
  const admin = privateKeyToAccount(privateKey);

  const chainId = await createPublicClient({ transport: http(rpcUrl) }).getChainId();
  if (chainId !== expectedChainId) {
    throw new Error(
      `RPC chainId=${chainId} 与报告 chainId=${expectedChainId}（${deployment.reportPath ?? "无报告"}）不一致，未发送任何交易；请检查 --rpc / HTP_RPC_URL / --report`,
    );
  }
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "HSK", symbol: "HSK", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const wallet = createWalletClient({ chain, account: admin, transport: http(rpcUrl) });
  let nonce = null;
  return {
    chainId,
    admin,
    publicClient,
    hasRole: (address, role, account) =>
      publicClient.readContract({ address, abi: ACCESS_ABI, functionName: "hasRole", args: [ROLE_IDS[role], account] }),
    async send(address, functionName, args) {
      nonce ??= await publicClient.getTransactionCount({ address: admin.address, blockTag: "pending" });
      const hash = await wallet.writeContract({ address, abi: ACCESS_ABI, functionName, args, nonce });
      nonce += 1;
      const receipt = await publicClient.waitForTransactionReceipt({
        hash,
        timeout: Math.max(RECEIPT_TIMEOUT_MS, deployment.finalityConfirmations * RECEIPT_BLOCK_BUDGET_MS),
        confirmations: deployment.finalityConfirmations,
      });
      if (receipt.status !== "success") throw new Error(`${functionName} 交易回滚 ${hash}`);
      return hash;
    },
  };
}

// 负载均衡的 RPC 节点同步有先后，交易上链后轮询到期望状态再继续。
async function waitForRole(chain, task, account, expected) {
  const started = Date.now();
  for (;;) {
    try {
      if ((await chain.hasRole(task.address, task.role, account)) === expected) return true;
    } catch {
      // 落后节点可能报错，继续等
    }
    if (Date.now() - started > VISIBILITY_TIMEOUT_MS) return false;
    await new Promise((r) => setTimeout(r, 1_000));
  }
}

export async function assertAdminEverywhere(chain, tasks) {
  const targets = new Map(tasks.map((task) => [task.address, task.name]));
  for (const [address, name] of targets) {
    if (!(await chain.hasRole(address, "DEFAULT_ADMIN", chain.admin.address))) {
      throw new Error(`${chain.admin.address} 在 ${name} (${address}) 上没有 DEFAULT_ADMIN_ROLE，未发送任何交易`);
    }
  }
}

/** tasks: [{ role, name, address }]。已持有的跳过；dryRun 只打印。返回新授权笔数。 */
export async function grantAll(chain, tasks, account, dryRun) {
  for (const task of tasks) task.already = await chain.hasRole(task.address, task.role, account);
  const todo = tasks.filter((task) => !task.already);
  await assertAdminEverywhere(chain, todo);
  console.log(`共 ${tasks.length} 项，已持有 ${tasks.length - todo.length} 项，待授予 ${todo.length} 项`);
  if (dryRun) {
    for (const task of tasks) console.log(`  ${task.already ? "已持有" : "待授予"}  ${task.role.padEnd(13)} ${task.name}`);
    return 0;
  }
  for (const task of todo) {
    console.log(`→ ${task.name} grantRole(${task.role}_ROLE)`);
    const hash = await chain.send(task.address, "grantRole", [ROLE_IDS[task.role], account]);
    if (!(await waitForRole(chain, task, account, true))) {
      throw new Error(`${task.name} ${task.role} 交易已成功（${hash}），但 ${VISIBILITY_TIMEOUT_MS / 1000}s 内仍读不到生效，稍后重跑可核对`);
    }
    console.log(`  ${hash}`);
  }
  return todo.length;
}

/** 调用者放弃自己在 tasks 各合约上的角色。 */
export async function renounceAll(chain, tasks) {
  for (const task of tasks) {
    if (!(await chain.hasRole(task.address, task.role, chain.admin.address))) {
      console.log(`  已不持有 ${task.role} ${task.name}，跳过`);
      continue;
    }
    console.log(`→ ${task.name} renounceRole(${task.role}_ROLE)`);
    const hash = await chain.send(task.address, "renounceRole", [ROLE_IDS[task.role], chain.admin.address]);
    if (!(await waitForRole(chain, task, chain.admin.address, false))) {
      throw new Error(`${task.name} renounce 交易已成功（${hash}），但 ${VISIBILITY_TIMEOUT_MS / 1000}s 内仍读到持有，稍后重跑可核对`);
    }
    console.log(`  ${hash}`);
  }
}

export function printHeader(chain, deployment, account, what) {
  console.log(`chainId=${chain.chainId} admin=${chain.admin.address}`);
  console.log(`grantTo=${account}  ${what}`);
  console.log(`report=${deployment.reportPath ?? "(未使用)"}`);
}

export function runMain(main) {
  main().catch((error) => {
    console.error(safeErrorMessage(error));
    process.exitCode = 1;
  });
}
