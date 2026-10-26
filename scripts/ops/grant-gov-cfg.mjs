#!/usr/bin/env node
// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
/**
 * grant-gov-cfg.mjs —— 给一个地址授予 GOVERNANCE_ROLE + CONFIGURER_ROLE
 *
 * 授予范围（共 17 项）：
 *   GOVERNANCE  8 个 Registry + DvP
 *     Registry 上：激活 / 封存 / 暂停后恢复 / 废弃配置，创建费率 Epoch，登记依赖 DvP
 *     DvP 上：恢复全局暂停、退役 DvP
 *   CONFIGURER  8 个 Registry（DvP 上没有这个角色）
 *     登记适配器 / 计算器 / 结算币 / 资产版本 / 市场规则 / 费率，
 *     写入 Participant、Eligibility（写入即生效，生产环境应授给多签）
 *
 *   只想授 Registry、不动 DvP 的治理权限：加 --no-dvp（共 16 项）。
 *
 * ------------------------------------------------------------------------
 * 准备
 * ------------------------------------------------------------------------
 *   在 tmp/.env 里填写 HTP_ADMIN_KEY=0x...（DEFAULT_ADMIN_ROLE 持有者的私钥）。
 *   本脚本只读取这一个私钥变量；shell 里设置的同名变量优先。
 *   链按报告里的 chainId 自动选：133 用内置 HashKey 测试网 RPC，其他链用 tmp/.env 的 HTP_RPC_URL；
 *   RPC 的 chainId 与报告不一致时不执行。
 *   合约地址默认从 tmp/out/platform-summary.json 读取（没有时读 platform-deployment.json）。
 *
 * ------------------------------------------------------------------------
 * 用法（在仓库根目录执行）
 * ------------------------------------------------------------------------
 *   # 授予
 *   node scripts/ops/grant-gov-cfg.mjs --account 0xABC...
 *
 *   # 先预览：逐项列出「已持有 / 待授予」，不发交易
 *   node scripts/ops/grant-gov-cfg.mjs --account 0xABC... --dry-run
 *
 *   # 不授 DvP 的 GOVERNANCE
 *   node scripts/ops/grant-gov-cfg.mjs --account 0xABC... --no-dvp
 *
 *   # 操作另一套部署 / 换 RPC
 *   node scripts/ops/grant-gov-cfg.mjs --account 0xABC... --report path/to/platform-summary.json --rpc https://...
 *
 * ------------------------------------------------------------------------
 * 行为
 * ------------------------------------------------------------------------
 *   - 发交易前检查 HTP_ADMIN_KEY 在每个目标合约上都有 DEFAULT_ADMIN_ROLE，缺一个就整体不执行。
 *   - 已持有的项自动跳过，中途失败直接重跑同一条命令即可。
 *   - 每笔上链后轮询 hasRole 确认生效（兼容测试网 RPC 多节点同步延迟）。
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

const USAGE = `node scripts/ops/grant-gov-cfg.mjs --account <addr> [options]

给地址授予 GOVERNANCE（8 个 Registry + DvP）和 CONFIGURER（8 个 Registry）。

  --no-dvp           不授 DvP 的 GOVERNANCE，只授 Registry
${COMMON_OPTIONS_HELP}
`;

runMain(async () => {
  const flags = parseArgs(process.argv.slice(2), ["no-dvp"], USAGE);
  if (flags.help) return console.log(USAGE);
  const account = requireAccount(flags, USAGE);
  const deployment = loadDeployment(flags);
  const registries = deployment.registries();
  const tasks = [
    ...registries.map((registry) => ({ role: "GOVERNANCE", ...registry })),
    ...(flags["no-dvp"] ? [] : [{ role: "GOVERNANCE", ...deployment.dvp() }]),
    ...registries.map((registry) => ({ role: "CONFIGURER", ...registry })),
  ];

  const chain = await connect(flags, deployment);
  printHeader(chain, deployment, account, `角色：GOVERNANCE + CONFIGURER${flags["no-dvp"] ? "（不含 DvP）" : ""}`);
  const granted = await grantAll(chain, tasks, account, Boolean(flags["dry-run"]));
  if (!flags["dry-run"]) console.log(`完成：${account} 已持有 GOVERNANCE + CONFIGURER（${granted} 笔新授权）`);
});
