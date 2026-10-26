import { readFileSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const reportPath = resolve(repositoryRoot, "contracts/slither-high-medium.json");

// 精确 allowlist：只接受下列两类已审阅结论。
//   uninitialized-local：Solidity 默认零值声明，随后在同一函数内被无条件赋值。
//   unused-return：有意忽略的返回值，失败路径由后续显式检查覆盖。
// 条目按 `detector|文件:行|符号` 精确匹配，因此源码行号变动后必须同步本表；
// 同步时只允许更新行号，不得新增未经审阅的 detector 类别。
const acceptedFindings = new Set([
  "uninitialized-local|src/DvPSettlement.sol:213|currentStateValidator",
  "uninitialized-local|src/adapters/OndoGmTokenAdapter.sol:101|graph",
  "uninitialized-local|src/libraries/DeploymentVersion.sol:16|dotCount",
  "uninitialized-local|src/libraries/DeploymentVersion.sol:17|segmentStart",
  "uninitialized-local|src/validation/DvPCurrentStateValidator.sol:104|context",
  "uninitialized-local|src/validation/DvPCurrentStateValidator.sol:138|context",
  "uninitialized-local|src/validation/StrictSettlementFailureMapper.sol:211|maker",
  "uninitialized-local|src/validation/StrictSettlementFailureMapper.sol:212|requesterRecord",
  "unused-return|src/DvPSettlement.sol:441|_validateSettlementCurrentState",
  "unused-return|src/adapters/ERC1404Adapter.sol:116|_hasPermissiveFallback",
  "unused-return|src/registry/PrincipalCalculatorRegistry.sol:208|_validateCalculator",
  "unused-return|src/validation/DvPSignedPayloadValidator.sol:112|_checkSignature",
]);

/**
 * @typedef {{
 *   check: string,
 *   elements: Array<{
 *     name: string,
 *     source_mapping: {
 *       filename_short: string,
 *       lines: number[],
 *       is_dependency: boolean
 *     }
 *   }>
 * }} SlitherDetector
 */

/** @param {SlitherDetector} detector */
export function findingId(detector) {
  const element = detector?.elements?.find(
    (candidate) => candidate?.source_mapping?.is_dependency === false,
  );
  const filename = element?.source_mapping?.filename_short;
  const line = element?.source_mapping?.lines?.[0];
  if (
    typeof detector?.check !== "string" ||
    typeof filename !== "string" ||
    !Number.isSafeInteger(line) ||
    typeof element?.name !== "string"
  ) {
    throw new Error(`Malformed Slither detector: ${JSON.stringify(detector)}`);
  }
  return `${detector.check}|${filename}:${line}|${element.name}`;
}

/**
 * @param {{success: boolean, error: unknown, results: {detectors: SlitherDetector[]}}} report
 * @param {Set<string>} [allowlist]
 */
export function verifyFindings(report, allowlist = acceptedFindings) {
  if (report?.success !== true || !Array.isArray(report?.results?.detectors)) {
    throw new Error(`Slither report is malformed or unsuccessful: ${report?.error ?? "unknown error"}`);
  }
  const actual = new Set(report.results.detectors.map(findingId));
  const unexpected = [...actual].filter((finding) => !allowlist.has(finding)).sort();
  const stale = [...allowlist].filter((finding) => !actual.has(finding)).sort();
  if (unexpected.length > 0 || stale.length > 0) {
    throw new Error(
      [
        "Slither finding allowlist drifted.",
        ...(unexpected.length > 0 ? [`Unexpected:\n${unexpected.join("\n")}`] : []),
        ...(stale.length > 0 ? [`Stale:\n${stale.join("\n")}`] : []),
      ].join("\n"),
    );
  }
  return actual.size;
}

function runSelfTest() {
  const allowed = new Set(["uninitialized-local|src/A.sol:7|value"]);
  const report = {
    success: true,
    error: null,
    results: {
      detectors: [
        {
          check: "uninitialized-local",
          elements: [
            {
              name: "value",
              source_mapping: {
                filename_short: "src/A.sol",
                lines: [7],
                is_dependency: false,
              },
            },
          ],
        },
      ],
    },
  };
  if (verifyFindings(report, allowed) !== 1) throw new Error("Slither runner self-test failed");
  try {
    verifyFindings(report, new Set());
    throw new Error("Slither runner accepted an unexpected finding");
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Slither finding allowlist drifted.")) {
      console.log("Slither runner self-test passed.");
      return;
    }
    throw error;
  }
}

function main() {
  if (process.argv.includes("--self-test")) {
    runSelfTest();
    return;
  }

  rmSync(reportPath, { force: true });
  const result = spawnSync(
    "slither",
    [
      "contracts",
      "--exclude-dependencies",
      "--filter-paths",
      "contracts/(test|script|lib)",
      "--exclude-low",
      "--exclude-informational",
      "--exclude-optimization",
      "--json",
      reportPath,
    ],
    { cwd: repositoryRoot, encoding: "utf8", stdio: "inherit" },
  );
  if (result.error) throw result.error;
  if (result.status !== 0 && result.status !== 255) {
    throw new Error(`Slither failed with exit ${result.status}`);
  }

  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  const acceptedCount = verifyFindings(report);
  console.log(
    `Slither high/medium gate passed with ${acceptedCount} exact accepted findings and no unexpected findings.`,
  );
}

main();

