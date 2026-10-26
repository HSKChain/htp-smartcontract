import { existsSync, readdirSync } from "node:fs";
import { relative, resolve, sep } from "node:path";

export const SCHEMA_V1_ROOT_ENTRIES = [
  "abi",
  "index.json",
  "manifest.json",
  "protocol",
  "types",
  "vectors",
] as const;

export const SCHEMA_V1_OPTIONAL_ROOT_ENTRIES = ["subgraph-boundary.md"] as const;

export const STALE_SCHEMA_V1_ROOT_ENTRIES = [
  "enums.json",
  "eip712.json",
  "configs.json",
  "roles.json",
  "layouts.json",
  "errors.json",
  "events.json",
  "golden",
] as const;

export const SCHEMA_DOCUMENT_PATHS = {
  enums: "types/enums.json",
  structs: "types/structs.json",
  layouts: "types/layouts.json",
  eip712: "protocol/eip712.json",
  configs: "protocol/configs.json",
  roles: "protocol/roles.json",
  errors: "protocol/errors.json",
  events: "protocol/events.json",
  interfaceVersions: "protocol/interface-versions.json",
} as const;

export const PROTOCOL_OPTIONAL_FILES = ["constants.json"] as const;

export const PROTOCOL_CONSTANTS_PATH = "protocol/constants.json";

export const VECTOR_PATHS = {
  domain: "vectors/eip712/domain.json",
  firmQuote: "vectors/eip712/firm-quote.json",
  tradeIntent: "vectors/eip712/trade-intent.json",
  nonceCancellation: "vectors/eip712/nonce-cancellation.json",
  tradeTermsSnapshot: "vectors/eip712/trade-terms-snapshot.json",
  priceterms: "vectors/configs/priceterms.json",
  configIds: "vectors/configs/config-ids.json",
  feeScope: "vectors/configs/fee-scope.json",
  assetVersion: "vectors/configs/asset-version.json",
  settlementToken: "vectors/configs/settlement-token.json",
  adapter: "vectors/configs/adapter.json",
  principalCalculator: "vectors/configs/principal-calculator.json",
  marketRule: "vectors/configs/market-rule.json",
  fee: "vectors/configs/fee.json",
  revisionRules: "vectors/configs/revision-rules.json",
  identifiers: "vectors/identifiers/canonical-identifiers.json",
  calculator: "vectors/calculators/all-v1.json",
  // 费用侧两份分工不同：resolution-and-amounts 描述 resolver 优先级与 Epoch 边界
  // 这类契约性事实；amounts-v1 是可执行的金额向量，由 calc-reference 生成、
  // TS 与 Solidity 双端消费。
  fees: "vectors/fees/resolution-and-amounts.json",
  feeAmounts: "vectors/fees/amounts-v1.json",
  settlement: "vectors/settlement/buy-sell-permit.json",
  adapters: "vectors/adapters/usdy.json",
  ondoGmAdapter: "vectors/adapters/ondo-gm-aaplon.json",
} as const;

export function schemaRepoPath(relativeToV1: string): string {
  return `schema/v1/${relativeToV1}`;
}

export function listRelativeFiles(directory: string): string[] {
  if (!existsSync(directory)) return [];
  const walk = (current: string): string[] =>
    readdirSync(current, { withFileTypes: true }).flatMap((entry) => {
      const path = resolve(current, entry.name);
      return entry.isDirectory() ? walk(path) : [relative(directory, path).split(sep).join("/")];
    });
  return walk(directory).sort();
}

export const ALL_VECTOR_FILES = Object.values(VECTOR_PATHS).map((path) => path.replace(/^vectors\//u, ""));

export function assertVectorFileSet(repositoryRoot: string): void {
  const root = resolve(repositoryRoot, "schema/v1/vectors");
  const actual = listRelativeFiles(root);
  const expected = [...ALL_VECTOR_FILES].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `vector file set differs\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(actual)}`,
    );
  }
}
