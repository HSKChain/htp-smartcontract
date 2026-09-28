import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const REPOSITORY_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COVERAGE_LCOV = "lcov.info";
const PRODUCTION_FACTORY_HASH_PATTERN =
  /(CURRENT_STATE_VALIDATOR_FACTORY_CODE_HASH\s*=\s*)0x[0-9a-fA-F]{64}(;)/u;
const REFERENCE_INTEGRITY_HASH_PATTERN =
  /(REFERENCE_INTEGRITY_CODE_HASH\s*=\s*)0x[0-9a-fA-F]{64}(;)/u;
const SKIPPED_BUILD_INPUTS = [
  "script",
  "DvPMigrationRunbook.t.sol",
  "UpgradeRunbook.t.sol",
  "DeploymentVerification.t.sol",
  "DeploymentReport.t.sol",
  "GovernanceHandoff.t.sol",
  "DeployAndReport.t.sol",
  "DeploymentScript.t.sol",
  "DeploymentTopologyParity.t.sol",
];
const CODE_HASH_ASSERTION_PATTERN =
  "(testValidatorFactoryCodeHashMatchesReviewedLiteral|" +
  "testReferenceIntegrityCodeHashMatchesReviewedLiteral|" +
  "testCapabilitiesAndProviderHashMatchReviewedRules|" +
  "testCapabilitiesDeclareOnlyTokenSpecificErc20AssetChecks)";
const PRODUCTION_PIN_CONTRACT_PATTERN = "(DvPConstructorTest|ERC1404AdapterTest|UsdyRestrictedAdapterTest)";
const PRODUCTION_GAS_CONTRACT_PATTERN =
  "(UsdyBuySettlementTest|UsdySellSettlementTest|FeeSettlementTest|EIP1271SettlementTest|" +
  "UsdyRestrictedAdapterTest|ERC1404AdapterTest|DependentDvpGuardTest|" +
  "PrincipalCalculatorImplementationsAbiTest)";
const EXPECTED_PRODUCTION_LCOV_SOURCES = new Set([
  "src/DvPSettlement.sol",
  "src/adapters/ERC1404Adapter.sol",
  "src/adapters/UnrestrictedERC20Adapter.sol",
  "src/adapters/UsdyRestrictedAdapter.sol",
  "src/calculators/BondPrincipalCalculator.sol",
  "src/calculators/FundPrincipalCalculator.sol",
  "src/calculators/StockPrincipalCalculator.sol",
  "src/libraries/AdapterInputValidation.sol",
  "src/libraries/AdapterReasonCodes.sol",
  "src/libraries/BoundedStaticCall.sol",
  "src/libraries/CalendarDate.sol",
  "src/libraries/ConfigId.sol",
  "src/libraries/DeploymentVersion.sol",
  "src/libraries/FeeMath.sol",
  "src/libraries/FeeScope.sol",
  "src/libraries/HTPHashing.sol",
  "src/libraries/PrincipalMath.sol",
  "src/libraries/ProtocolSecurityLimits.sol",
  "src/libraries/RegistryImplementationValidation.sol",
  "src/libraries/RestrictionProviderLib.sol",
  "src/libraries/SettlementParamsValidation.sol",
  "src/libraries/TokenMetadataValidation.sol",
  "src/registry/AdapterRegistry.sol",
  "src/registry/AssetVersionRegistry.sol",
  "src/registry/EligibilityRegistry.sol",
  "src/registry/FeeRegistry.sol",
  "src/registry/LinearConfigRegistryBase.sol",
  "src/registry/ParticipantRegistry.sol",
  "src/registry/PrincipalCalculatorRegistry.sol",
  "src/registry/SettlementTokenRegistry.sol",
  "src/registry/UUPSRegistryBase.sol",
  "src/validation/ConfigurationReferenceIntegrity.sol",
  "src/validation/DvPCurrentStateValidator.sol",
  "src/validation/DvPCurrentStateValidatorFactory.sol",
  "src/validation/DvPSignedPayloadValidator.sol",
]);

/** @param {string} source @param {string} coverageFactoryHash */
export function replaceFactoryHash(source, coverageFactoryHash) {
  if (!/^0x[0-9a-f]{64}$/u.test(coverageFactoryHash)) {
    throw new Error(`Malformed coverage Factory hash: ${coverageFactoryHash}`);
  }
  const matches = source.match(new RegExp(PRODUCTION_FACTORY_HASH_PATTERN.source, "gu")) ?? [];
  if (matches.length !== 1) {
    throw new Error(`Expected one Validator Factory hash pin, found ${matches.length}`);
  }
  return source.replace(PRODUCTION_FACTORY_HASH_PATTERN, `$1${coverageFactoryHash}$2`);
}

/** @param {string} source @param {string} coverageReferenceHash */
export function replaceReferenceIntegrityHash(source, coverageReferenceHash) {
  if (!/^0x[0-9a-f]{64}$/u.test(coverageReferenceHash)) {
    throw new Error(`Malformed coverage ReferenceIntegrity hash: ${coverageReferenceHash}`);
  }
  const matches = source.match(new RegExp(REFERENCE_INTEGRITY_HASH_PATTERN.source, "gu")) ?? [];
  if (matches.length !== 1) {
    throw new Error(`Expected one ReferenceIntegrity hash pin, found ${matches.length}`);
  }
  return source.replace(REFERENCE_INTEGRITY_HASH_PATTERN, `$1${coverageReferenceHash}$2`);
}

/** @param {string} lcov */
export function filterProductionLcov(lcov) {
  const records = lcov
    .split("end_of_record")
    .map((record) => record.trim())
    .filter((record) => record.split("\n").some((line) => line.startsWith("SF:src/")));
  if (records.length === 0) {
    throw new Error("LCOV report contains no src/ production records");
  }
  return `${records.join("\nend_of_record\n")}\nend_of_record\n`;
}

/** @param {string} lcov @param {Set<string>} [expected] */
export function verifyProductionLcovSources(lcov, expected = EXPECTED_PRODUCTION_LCOV_SOURCES) {
  const actual = new Set(
    lcov
      .split("\n")
      .filter((line) => line.startsWith("SF:"))
      .map((line) => line.slice(3)),
  );
  const missing = [...expected].filter((source) => !actual.has(source)).sort();
  const unexpected = [...actual].filter((source) => !expected.has(source)).sort();
  if (missing.length > 0 || unexpected.length > 0) {
    throw new Error(
      [
        "Production LCOV source inventory drifted.",
        ...(missing.length > 0 ? [`Missing:\n${missing.join("\n")}`] : []),
        ...(unexpected.length > 0 ? [`Unexpected:\n${unexpected.join("\n")}`] : []),
      ].join("\n"),
    );
  }
  return actual.size;
}

/** @param {string} output @param {string} coverageHash @param {string} testName */
export function verifyCoverageProbeOutput(output, coverageHash, testName) {
  const failures = output.match(/^\[FAIL:.*$/gmu) ?? [];
  if (
    failures.length !== 1 ||
    !failures[0]?.includes(testName) ||
    !failures[0]?.includes(coverageHash) ||
    !/Ran 1 test suite[^\n]*0 tests passed, 1 failed, 0 skipped/u.test(output)
  ) {
    throw new Error(`Coverage codeHash probe did not fail in the one expected way:\n${output.trim()}`);
  }
}

/** @param {string} output @param {string} testName */
function readCoverageProbeHash(output, testName) {
  const failure = (output.match(/^\[FAIL:.*$/gmu) ?? []).find((line) => line.includes(testName));
  const assertion = failure?.match(/assertion failed:\s*(0x[0-9a-f]{64})\s*!=/u);
  if (!assertion?.[1]) {
    throw new Error(`Coverage hash was absent from ${testName} output:\n${output.trim()}`);
  }
  return assertion[1];
}

/** @param {string} lcov */
function summarizeProductionLcov(lcov) {
  const totals = { linesFound: 0, linesHit: 0, branchesFound: 0, branchesHit: 0, functionsFound: 0, functionsHit: 0 };
  for (const line of lcov.split("\n")) {
    const [key, rawValue] = line.split(":", 2);
    const value = Number(rawValue);
    if (!Number.isSafeInteger(value)) continue;
    if (key === "LF") totals.linesFound += value;
    else if (key === "LH") totals.linesHit += value;
    else if (key === "BRF") totals.branchesFound += value;
    else if (key === "BRH") totals.branchesHit += value;
    else if (key === "FNF") totals.functionsFound += value;
    else if (key === "FNH") totals.functionsHit += value;
  }
  return totals;
}

/** @param {number} hit @param {number} found */
function percentage(hit, found) {
  return found === 0 ? "100.00" : ((hit * 100) / found).toFixed(2);
}

/**
 * @param {string[]} arguments_
 * @param {{capture?: boolean, coverage?: boolean}} [options]
 */
function runForge(arguments_, options = {}) {
  const environment = { ...process.env };
  if (options.coverage) environment.PHASE19_COVERAGE = "true";
  else delete environment.PHASE19_COVERAGE;
  const result = spawnSync("forge", arguments_, {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit",
    env: environment,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const output = options.capture ? `${result.stdout}\n${result.stderr}`.trim() : "";
    throw new Error(`forge ${arguments_[0]} failed with exit ${result.status}${output ? `\n${output}` : ""}`);
  }
  return result;
}

/** @param {string} temporaryRoot */
function prepareWorkspace(temporaryRoot) {
  const sourceContracts = resolve(REPOSITORY_ROOT, "contracts");
  const targetContracts = resolve(temporaryRoot, "contracts");
  mkdirSync(targetContracts, { recursive: true });

  for (const entry of ["foundry.toml", "src", "test", "script"]) {
    cpSync(resolve(sourceContracts, entry), resolve(targetContracts, entry), { recursive: true });
  }
  symlinkSync(resolve(sourceContracts, "lib"), resolve(targetContracts, "lib"), "dir");
  symlinkSync(resolve(REPOSITORY_ROOT, "schema"), resolve(temporaryRoot, "schema"), "dir");
  symlinkSync(resolve(REPOSITORY_ROOT, "deploy"), resolve(temporaryRoot, "deploy"), "dir");
  return targetContracts;
}

/** @param {string} coverageRoot @param {string} testName */
function coverageBuildArguments(coverageRoot, testName) {
  return [
    "coverage",
    "--root",
    coverageRoot,
    "--allow-failure",
    "--match-test",
    testName,
    "--report",
    "summary",
    "--skip",
    ...SKIPPED_BUILD_INPUTS,
  ];
}

/** @param {string} coverageRoot @param {string} reportPath */
function coverageReportArguments(coverageRoot, reportPath) {
  return [
    "coverage",
    "--root",
    coverageRoot,
    "--exclude-tests",
    "--no-match-coverage",
    "(test|script)/",
    "--no-match-test",
    CODE_HASH_ASSERTION_PATTERN,
    "--report",
    "summary",
    "--report",
    "lcov",
    "--report-file",
    reportPath,
    "--skip",
    ...SKIPPED_BUILD_INPUTS,
  ];
}

function runSelfTest() {
  const sample = [
    "bytes32 private constant CURRENT_STATE_VALIDATOR_FACTORY_CODE_HASH =",
    "    0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;",
  ].join("\n");
  const replacement = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const updated = replaceFactoryHash(sample, replacement);
  if (!updated.includes(replacement) || updated.includes("0xaaaaaaaa")) {
    throw new Error("Factory hash replacement self-test failed");
  }
  for (const invalid of ["0x01", "bb", `0x${"g".repeat(64)}`]) {
    try {
      replaceFactoryHash(sample, invalid);
      throw new Error(`Malformed hash was accepted: ${invalid}`);
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("Malformed coverage Factory hash:")) continue;
      throw error;
    }
  }
  const factorySample = [
    "bytes32 private constant REFERENCE_INTEGRITY_CODE_HASH =",
    "    0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;",
  ].join("\n");
  if (!replaceReferenceIntegrityHash(factorySample, replacement).includes(replacement)) {
    throw new Error("ReferenceIntegrity hash replacement self-test failed");
  }
  const filtered = filterProductionLcov(
    ["TN:", "SF:src/A.sol", "LF:1", "LH:1", "end_of_record", "TN:", "SF:test/A.t.sol", "LF:1", "LH:0", "end_of_record"].join(
      "\n",
    ),
  );
  if (!filtered.includes("SF:src/A.sol") || filtered.includes("SF:test/A.t.sol")) {
    throw new Error("Production LCOV filter self-test failed");
  }
  if (verifyProductionLcovSources(filtered, new Set(["src/A.sol"])) !== 1) {
    throw new Error("Production LCOV source inventory self-test failed");
  }
  const probeHash = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
  const probeName = "testValidatorFactoryCodeHashMatchesReviewedLiteral";
  verifyCoverageProbeOutput(
    `[FAIL: assertion failed: ${probeHash} != 0x${"d".repeat(64)}] ` +
      `${probeName}() (gas: 1)\n` +
      "Ran 1 test suite: 0 tests passed, 1 failed, 0 skipped",
    probeHash,
    probeName,
  );
  console.log("Phase 19 coverage runner self-test passed.");
}

function main() {
  if (process.argv.includes("--self-test")) {
    runSelfTest();
    return;
  }

  const temporaryRoot = mkdtempSync(resolve(tmpdir(), "htp-phase19-coverage-"));
  try {
    const coverageRoot = prepareWorkspace(temporaryRoot);
    const referenceProbeName = "testReferenceIntegrityCodeHashMatchesReviewedLiteral";
    const referenceProbe = runForge(coverageBuildArguments(coverageRoot, referenceProbeName), {
      capture: true,
      coverage: true,
    });
    const referenceProbeOutput = `${referenceProbe.stdout}\n${referenceProbe.stderr}`;
    const coverageReferenceHash = readCoverageProbeHash(referenceProbeOutput, referenceProbeName);
    verifyCoverageProbeOutput(referenceProbeOutput, coverageReferenceHash, referenceProbeName);
    const factoryPath = resolve(coverageRoot, "src", "validation", "DvPCurrentStateValidatorFactory.sol");
    const originalFactory = readFileSync(factoryPath, "utf8");
    writeFileSync(factoryPath, replaceReferenceIntegrityHash(originalFactory, coverageReferenceHash));

    const factoryProbeName = "testValidatorFactoryCodeHashMatchesReviewedLiteral";
    const factoryProbe = runForge(coverageBuildArguments(coverageRoot, factoryProbeName), {
      capture: true,
      coverage: true,
    });
    const factoryProbeOutput = `${factoryProbe.stdout}\n${factoryProbe.stderr}`;
    const coverageFactoryHash = readCoverageProbeHash(factoryProbeOutput, factoryProbeName);
    verifyCoverageProbeOutput(factoryProbeOutput, coverageFactoryHash, factoryProbeName);
    const dvpPath = resolve(coverageRoot, "src", "DvPSettlement.sol");
    const originalDvp = readFileSync(dvpPath, "utf8");
    writeFileSync(dvpPath, replaceFactoryHash(originalDvp, coverageFactoryHash));

    const temporaryReport = resolve(coverageRoot, COVERAGE_LCOV);
    runForge(coverageReportArguments(coverageRoot, temporaryReport), { coverage: true });
    if (!existsSync(temporaryReport)) {
      throw new Error("forge coverage completed without an LCOV report");
    }

    const targetReport = resolve(REPOSITORY_ROOT, "contracts", COVERAGE_LCOV);
    const productionLcov = filterProductionLcov(readFileSync(temporaryReport, "utf8"));
    const productionSourceCount = verifyProductionLcovSources(productionLcov);
    writeFileSync(targetReport, productionLcov);
    const totals = summarizeProductionLcov(productionLcov);
    console.log(
      `Phase 19 LCOV report written to ${targetReport}; coverage ` +
        `ReferenceIntegrity hash ${coverageReferenceHash}; Factory hash ${coverageFactoryHash}.`,
    );
    console.log(`Production LCOV source inventory: ${productionSourceCount} exact files.`);
    console.log(
      `Production coverage: lines ${percentage(totals.linesHit, totals.linesFound)}% ` +
        `(${totals.linesHit}/${totals.linesFound}), branches ` +
        `${percentage(totals.branchesHit, totals.branchesFound)}% ` +
        `(${totals.branchesHit}/${totals.branchesFound}), functions ` +
        `${percentage(totals.functionsHit, totals.functionsFound)}% ` +
        `(${totals.functionsHit}/${totals.functionsFound}).`,
    );
    console.log(
      "Four production bytecode-hash literal assertions were excluded from coverage only; run production pin tests separately.",
    );
    runForge([
      "test",
      "--root",
      "contracts",
      "--match-contract",
      PRODUCTION_PIN_CONTRACT_PATTERN,
    ]);
    console.log("Production Factory and Adapter codeHash pin tests passed.");
    runForge([
      "test",
      "--root",
      "contracts",
      "--match-contract",
      PRODUCTION_GAS_CONTRACT_PATTERN,
    ]);
    console.log("Production Gas regression budgets passed.");
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

if (basename(process.argv[1] ?? "") === basename(fileURLToPath(import.meta.url))) {
  main();
}

