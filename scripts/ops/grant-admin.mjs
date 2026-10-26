#!/usr/bin/env node
// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
/**
 * grant-admin.mjs —— 给一个地址授予 DEFAULT_ADMIN_ROLE，可选移交（旧管理员放弃权限）
 *
 * DEFAULT_ADMIN_ROLE 是最高权限：可以授予和撤销所有其他角色（包括 DEFAULT_ADMIN 本身）。
 * 授予范围：8 个 Registry + DvP，共 9 个合约。
 * 生产环境的管理员应当是多签；本脚本会提示目标地址是合约还是普通地址（EOA）。
 *
 * ------------------------------------------------------------------------
 * 准备
 * ------------------------------------------------------------------------
 *   在 tmp/.env 里填写 HTP_ADMIN_KEY=0x...（当前 DEFAULT_ADMIN_ROLE 持有者的私钥）。
 *   本脚本只读取这一个私钥变量；shell 里设置的同名变量优先。
 *   链按报告里的 chainId 自动选：133 用内置 HashKey 测试网 RPC，其他链用 tmp/.env 的 HTP_RPC_URL；
 *   RPC 的 chainId 与报告不一致时不执行。
 *   合约地址默认从 tmp/out/platform-summary.json 读取（没有时读 platform-deployment.json）。
 *
 * ------------------------------------------------------------------------
 * 用法（在仓库根目录执行）
 * ------------------------------------------------------------------------
 *   # 1. 先预览，不发交易
 *   node scripts/ops/grant-admin.mjs --account 0xNEW... --dry-run
 *
 *   # 2. 增加一个管理员（旧管理员保留）
 *   node scripts/ops/grant-admin.mjs --account 0xNEW...
 *
 *   # 3. 移交：授予新管理员，确认 9 个合约全部生效后，当前私钥对应的地址放弃自己的管理员权限
 *   node scripts/ops/grant-admin.mjs --account 0xNEW... --renounce-self
 *
 *   # 操作另一套部署 / 换 RPC
 *   node scripts/ops/grant-admin.mjs --account 0xNEW... --report path/to/platform-summary.json --rpc https://...
 *
 * ------------------------------------------------------------------------
 * 移交（--renounce-self）的安全措施
 * ------------------------------------------------------------------------
 *   - 新地址不能等于当前地址。
 *   - 先授予，再逐个确认新地址在全部 9 个合约上都持有 DEFAULT_ADMIN，任何一个不满足就不放弃。
 *   - 合约自带保护：最后一个 DEFAULT_ADMIN 无法被移除（LastDefaultAdminCannotBeRemoved），不会锁死。
 *   - 放弃是不可逆的：之后只能由新管理员把权限授回来。执行前请确认新地址的私钥 / 多签可用。
 *   - 只放弃 DEFAULT_ADMIN；当前地址持有的 GOVERNANCE / CONFIGURER 等其他角色不受影响，需要时请新管理员撤销。
 *
 * ------------------------------------------------------------------------
 * 行为
 * ------------------------------------------------------------------------
 *   - 发交易前检查 HTP_ADMIN_KEY 在 9 个合约上都有 DEFAULT_ADMIN_ROLE，缺一个就整体不执行。
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
  renounceAll,
  requireAccount,
  runMain,
} from "./lib/grant-common.mjs";

const USAGE = `node scripts/ops/grant-admin.mjs --account <addr> [options]

给地址授予 DEFAULT_ADMIN_ROLE（8 个 Registry + DvP）。

  --renounce-self    授予并确认生效后，当前地址放弃自己的 DEFAULT_ADMIN（移交，不可逆）
${COMMON_OPTIONS_HELP}
`;

runMain(async () => {
  const flags = parseArgs(process.argv.slice(2), ["renounce-self"], USAGE);
  if (flags.help) return console.log(USAGE);
  const account = requireAccount(flags, USAGE);
  const deployment = loadDeployment(flags);
  const tasks = [...deployment.registries(), deployment.dvp()].map((target) => ({ role: "DEFAULT_ADMIN", ...target }));
  const renounce = Boolean(flags["renounce-self"]);
  const dryRun = Boolean(flags["dry-run"]);

  const chain = await connect(flags, deployment);
  if (renounce && account === chain.admin.address) throw new Error("--renounce-self 时新管理员不能是当前地址");
  printHeader(chain, deployment, account, `角色：DEFAULT_ADMIN${renounce ? "（移交：完成后当前地址放弃）" : ""}`);

  const code = await chain.publicClient.getCode({ address: account });
  console.log(code && code !== "0x" ? "目标地址是合约（多签等）" : "注意：目标地址是普通地址（EOA），生产环境建议用多签");

  const granted = await grantAll(chain, tasks, account, dryRun);
  if (dryRun) {
    if (renounce) console.log(`（dry-run）实际执行时，确认后 ${chain.admin.address} 会放弃 9 个合约上的 DEFAULT_ADMIN`);
    return;
  }
  console.log(`已确认：${account} 在 9 个合约上持有 DEFAULT_ADMIN（${granted} 笔新授权）`);
  if (!renounce) return;

  for (const task of tasks) {
    if (!(await chain.hasRole(task.address, "DEFAULT_ADMIN", account))) {
      throw new Error(`${task.name} 上新管理员尚未生效，停止移交，当前地址未放弃任何权限`);
    }
  }
  console.log(`开始移交：${chain.admin.address} 放弃 DEFAULT_ADMIN`);
  await renounceAll(chain, tasks);
  console.log(`移交完成：DEFAULT_ADMIN 现在由 ${account} 持有，${chain.admin.address} 已放弃`);
});
