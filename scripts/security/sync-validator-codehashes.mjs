import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256 } from "viem";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const contractsOut = resolve(repositoryRoot, "contracts/out");
const CODE_HASH_LITERAL = "0x[0-9a-fA-F]{64}";

// DvPSettlement pins the Factory runtime codeHash, and the Factory pins both
// helper runtime codeHashes. Because `bytecode_hash = "ipfs"` and
// `use_literal_content = true`, every source byte in a compilation unit feeds
// the metadata hash, so any edit anywhere in the validator layer moves these
// values. Rewriting the helper pins changes the Factory source, which changes
// the Factory codeHash, so the phases below must run leaf-to-root in order.
const PIN_GROUPS = [
  {
    phase: 1,
    artifact: "ConfigurationReferenceIntegrity",
    locations: [
      {
        file: "contracts/src/validation/DvPCurrentStateValidatorFactory.sol",
        anchor: "REFERENCE_INTEGRITY_CODE_HASH =",
      },
      {
        file: "contracts/test/validation/DvPCurrentStateValidatorFactory.t.sol",
        anchor: "REFERENCE_INTEGRITY_CODE_HASH =",
      },
      {
        file: "contracts/test/unit/DvPConstructor.t.sol",
        anchor: "vm.computeCreateAddress(address(currentStateValidatorFactory), 1).codehash,",
      },
    ],
  },
  {
    phase: 1,
    artifact: "StrictSettlementFailureMapper",
    locations: [
      {
        file: "contracts/src/validation/DvPCurrentStateValidatorFactory.sol",
        anchor: "STRICT_FAILURE_MAPPER_CODE_HASH =",
      },
      {
        file: "contracts/test/validation/DvPCurrentStateValidatorFactory.t.sol",
        anchor: "STRICT_FAILURE_MAPPER_CODE_HASH =",
      },
      {
        file: "contracts/test/unit/DvPConstructor.t.sol",
        anchor: "vm.computeCreateAddress(address(currentStateValidatorFactory), 2).codehash,",
      },
    ],
  },
  {
    phase: 2,
    artifact: "DvPCurrentStateValidatorFactory",
    locations: [
      {
        file: "contracts/src/DvPSettlement.sol",
        anchor: "CURRENT_STATE_VALIDATOR_FACTORY_CODE_HASH =",
      },
      {
        file: "contracts/test/validation/DvPCurrentStateValidatorFactory.t.sol",
        anchor: "FACTORY_CODE_HASH =",
      },
      {
        file: "contracts/test/unit/DvPConstructor.t.sol",
        anchor: "address(currentStateValidatorFactory).codehash,",
      },
    ],
  },
];

/**
 * @param {string} value
 */
function escapeForRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

/**
 * Matches the pinned literal that immediately follows an anchor. Requiring a
 * unique match keeps the rewrite fail-closed when a file is restructured.
 *
 * @param {{anchor: string}} location
 */
function locationPattern(location) {
  return new RegExp(`(${escapeForRegExp(location.anchor)}\\s*)(${CODE_HASH_LITERAL})`, "gu");
}

function build() {
  execFileSync("forge", ["build", "--root", "contracts"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/**
 * @param {string} artifact
 */
function runtimeCodeHash(artifact) {
  const artifactPath = resolve(contractsOut, `${artifact}.sol`, `${artifact}.json`);
  /** @type {any} */
  const parsed = JSON.parse(readFileSync(artifactPath, "utf8"));
  const runtime = parsed?.deployedBytecode?.object;
  if (typeof runtime !== "string" || !/^0x(?:[0-9a-fA-F]{2})+$/u.test(runtime)) {
    throw new Error(`${artifact} has no usable deployedBytecode; run a build first.`);
  }
  return keccak256(/** @type {`0x${string}`} */ (runtime.toLowerCase()));
}

/**
 * @param {{file: string, anchor: string}} location
 */
function readPin(location) {
  const filePath = resolve(repositoryRoot, location.file);
  const source = readFileSync(filePath, "utf8");
  const matches = [...source.matchAll(locationPattern(location))];
  if (matches.length !== 1) {
    throw new Error(
      `${location.file}: expected exactly one pin after "${location.anchor}", found ${matches.length}.`,
    );
  }
  return matches[0][2].toLowerCase();
}

/**
 * @param {{file: string, anchor: string}} location
 * @param {string} codeHash
 */
function writePin(location, codeHash) {
  const filePath = resolve(repositoryRoot, location.file);
  const source = readFileSync(filePath, "utf8");
  const updated = source.replace(locationPattern(location), `$1${codeHash}`);
  if (updated !== source) {
    writeFileSync(filePath, updated);
    return true;
  }
  return false;
}

/**
 * @param {number} phase
 */
function applyPhase(phase) {
  let rewritten = 0;
  for (const group of PIN_GROUPS.filter((candidate) => candidate.phase === phase)) {
    const codeHash = runtimeCodeHash(group.artifact);
    for (const location of group.locations) {
      readPin(location);
      if (writePin(location, codeHash)) {
        rewritten += 1;
        console.log(`  updated ${location.file} -> ${group.artifact} ${codeHash}`);
      }
    }
  }
  return rewritten;
}

function verify() {
  /** @type {string[]} */
  const failures = [];
  for (const group of PIN_GROUPS) {
    const expected = runtimeCodeHash(group.artifact);
    for (const location of group.locations) {
      const actual = readPin(location);
      if (actual !== expected) {
        failures.push(`${location.file}: ${group.artifact} pin is ${actual}, build produces ${expected}`);
      }
    }
  }
  return failures;
}

const checkOnly = process.argv.includes("--check");

build();

if (!checkOnly) {
  console.log("Phase 1: helper codeHashes pinned inside the Factory.");
  if (applyPhase(1) > 0) {
    build();
  }
  console.log("Phase 2: Factory codeHash pinned inside DvPSettlement.");
  if (applyPhase(2) > 0) {
    build();
  }
}

const failures = verify();
if (failures.length > 0) {
  console.error("Validator codeHash pins are stale:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  console.error("Run `npm run codehash:sync` after cleaning vendored dependencies.");
  process.exit(1);
}

console.log(`Validator codeHash pins verified (${PIN_GROUPS.reduce((total, group) => total + group.locations.length, 0)} locations).`);
