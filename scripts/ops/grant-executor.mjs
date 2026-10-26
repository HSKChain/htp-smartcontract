#!/usr/bin/env node
// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
/**
 * grant-executor.mjs —— 给一个地址授予 DvP 的 EXECUTOR_ROLE
 *
 * 作用：EXECUTOR 是唯一能调用 DvPSettlement.settle 执行结算的角色，通常授给后端结算服务的热钱包。
 * 只授予 DvP 这一个合约（Registry 上没有这个角色）。
 *
 * ------------------------------------------------------------------------
 * 准备
 * ------------------------------------------------------------------------
 *   在 tmp/.env 里填写 HTP_ADMIN_KEY=0x...（DvP 上 DEFAULT_ADMIN_ROLE 持有者的私钥）。
 *   本脚本只读取这一个私钥变量；shell 里设置的同名变量优先。
 *   链按报告里的 chainId 自动选：133 用内置 HashKey 测试网 RPC，其他链用 tmp/.env 的 HTP_RPC_URL；
 *   RPC 的 chainId 与报告不一致时不执行。
 *   DvP 地址默认从 tmp/out/platform-summary.json 读取（没有时读 platform-deployment.json）。
 *
 * ------------------------------------------------------------------------
 * 用法（在仓库根目录执行）
 * ------------------------------------------------------------------------
 *   # 授予
 *   node scripts/ops/grant-executor.mjs --account 0xABC...
 *
 *   # 先预览是否已经持有，不发交易
 *   node scripts/ops/grant-executor.mjs --account 0xABC... --dry-run
 *
 *   # 操作另一套部署：直接指定 DvP 地址或报告
 *   node scripts/ops/grant-executor.mjs --account 0xABC... --dvp 0xDVP... --finality-confirmations 5
 *   node scripts/ops/grant-executor.mjs --account 0xABC... --report path/to/platform-summary.json
 *
 *   # 手动指定 RPC（覆盖自动选择）
 *   node scripts/ops/grant-executor.mjs --account 0xABC... --rpc https://...
 *
 * ------------------------------------------------------------------------
 * 行为
 * ------------------------------------------------------------------------
 *   - 发交易前检查 HTP_ADMIN_KEY 在 DvP 上有 DEFAULT_ADMIN_ROLE，没有就不执行。
 *   - 已持有则跳过，可重复执行。
 *   - 上链后轮询 hasRole 确认生效（兼容测试网 RPC 多节点同步延迟）。
 */

import {
  COMMON_OPTIONS_HELP,
  connect,
  grantAll,
  loadDeployment,
  parseArgs,
  printHeader,
  requireAccount,
  runMain,
} from "./lib/grant-common.mjs";

const USAGE = `node scripts/ops/grant-executor.mjs --account <addr> [options]

给地址授予 DvP 的 EXECUTOR_ROLE（可调用 settle）。

${COMMON_OPTIONS_HELP}
`;

runMain(async () => {
  const flags = parseArgs(process.argv.slice(2), [], USAGE);
  if (flags.help) return console.log(USAGE);
  const account = requireAccount(flags, USAGE);
  const deployment = loadDeployment(flags);
  const tasks = [{ role: "EXECUTOR", ...deployment.dvp() }];

  const chain = await connect(flags, deployment);
  printHeader(chain, deployment, account, "角色：DvP EXECUTOR");
  const granted = await grantAll(chain, tasks, account, Boolean(flags["dry-run"]));
  if (!flags["dry-run"]) console.log(`完成：${account} 已持有 DvP EXECUTOR_ROLE（${granted} 笔新授权）`);
});
