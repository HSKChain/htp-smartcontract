// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

export const TMP_ENV_PATH = join(dirname(fileURLToPath(import.meta.url)), "../../..", "tmp", ".env");

function warnIfLoose() {
  if ((statSync(TMP_ENV_PATH).mode & 0o077) !== 0) {
    console.warn(`警告：${TMP_ENV_PATH} 对其他用户可读，建议执行 chmod 600 tmp/.env`);
  }
}

/** 读取 tmp/.env 全部变量；shell 里已设置的同名变量优先，不会被覆盖。 */
export function loadTmpEnv() {
  if (!existsSync(TMP_ENV_PATH)) return false;
  warnIfLoose();
  process.loadEnvFile(TMP_ENV_PATH);
  return true;
}

/** 只取一个变量：先看 shell，再看 tmp/.env；不会把 .env 里的其他变量加载进进程环境。 */
export function readTmpEnvVar(name) {
  if (process.env[name]) return process.env[name];
  if (!existsSync(TMP_ENV_PATH)) return undefined;
  warnIfLoose();
  return parseEnv(readFileSync(TMP_ENV_PATH, "utf8"))[name] || undefined;
}

/** 避免 Viem/transport 错误把含凭证的 RPC URL 原样写入日志。 */
export function safeErrorMessage(error) {
  const message = error?.shortMessage ?? error?.message ?? String(error);
  return String(message).replace(/\bhttps?:\/\/[^\s]+/giu, "[RPC URL redacted]");
}
