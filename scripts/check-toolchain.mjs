import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lockPath = resolve(root, "contracts/toolchain.lock.json");
/** @type {any} */
const lock = JSON.parse(readFileSync(lockPath, "utf8"));
/** @type {string[]} */
const failures = [];

/**
 * @param {string} command
 * @param {string[]} args
 * @param {string} [cwd]
 */
function run(command, args, cwd = root) {
  return execFileSync(command, args, {
    cwd,
    encoding: "utf8",
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

/**
 * @param {string} label
 * @param {unknown} actual
 * @param {unknown} expected
 */
function expectEqual(label, actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    failures.push(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

/** @type {any} */
const forgeConfig = JSON.parse(run("forge", ["config", "--root", "contracts", "--json"]));
const forgeVersionOutput = run("forge", ["--version"]);
const forgeVersionMatch = forgeVersionOutput.match(/forge Version: ([^\s]+)/);
const forgeCommitMatch = forgeVersionOutput.match(/Commit SHA: ([0-9a-f]+)/);
const solcVersionOutput = run("solc", ["--version"]);

expectEqual("Foundry version", forgeVersionMatch?.[1], `${lock.tools.foundry.version}-stable`);
expectEqual("Foundry commit", forgeCommitMatch?.[1], lock.tools.foundry.commit);
expectEqual("Node version", process.versions.node, lock.tools.node);
expectEqual("npm version", run("npm", ["--version"]), lock.tools.npm);
expectEqual("Slither version", run("slither", ["--version"]), lock.tools.slither);

if (!solcVersionOutput.includes(`Version: ${lock.tools.solc.longVersion}`)) {
  failures.push(`solc version does not contain ${lock.tools.solc.longVersion}`);
}

expectEqual("solc config", forgeConfig.solc, lock.tools.solc.configVersion);
expectEqual("auto_detect_solc", forgeConfig.auto_detect_solc, false);
expectEqual("evm_version", forgeConfig.evm_version, lock.compiler.evmVersion);
expectEqual("optimizer", forgeConfig.optimizer, lock.compiler.optimizer);
expectEqual("optimizer_runs", forgeConfig.optimizer_runs, lock.compiler.optimizerRuns);
expectEqual("via_ir", forgeConfig.via_ir, lock.compiler.viaIR);
expectEqual("bytecode_hash", forgeConfig.bytecode_hash, lock.compiler.bytecodeHash);
expectEqual("cbor_metadata", forgeConfig.cbor_metadata, lock.compiler.cborMetadata);
expectEqual("use_literal_content", forgeConfig.use_literal_content, lock.compiler.useLiteralContent);
expectEqual("build_info", forgeConfig.build_info, lock.compiler.buildInfo);
expectEqual("ast", forgeConfig.ast, lock.compiler.ast);
expectEqual("remappings", forgeConfig.remappings, lock.compiler.remappings);

for (const dependency of lock.dependencies) {
  const dependencyPath = resolve(root, dependency.path);
  const licensePath = resolve(root, dependency.licenseFile);
  if (!existsSync(dependencyPath)) {
    failures.push(`${dependency.name}: missing ${dependency.path}`);
    continue;
  }
  if (!existsSync(licensePath)) {
    failures.push(`${dependency.name}: missing license ${dependency.licenseFile}`);
  }
  expectEqual(
    `${dependency.name} commit`,
    run("git", ["-C", dependencyPath, "rev-parse", "HEAD"]),
    dependency.commit,
  );
  if (run("git", ["-C", dependencyPath, "status", "--short"]) !== "") {
    failures.push(`${dependency.name}: dependency worktree is dirty`);
  }
}

if (failures.length > 0) {
  console.error("Toolchain verification failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Toolchain verification passed.");
