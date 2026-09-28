import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256 } from "viem";
import {
  assertApprovedBuildArtifacts,
  assertApprovedCreationBytecode,
  assertApprovedRuntimeCodeHash,
  createApprovedArtifactManifest,
} from "./reproducible-artifacts.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contractsRoot = resolve(root, "contracts");
const selfTest = process.argv.includes("--self-test");
const approvedManifestPath = optionValue("--approved-artifact-manifest");
const writeManifestPath = optionValue("--write-artifact-manifest");
const temporaryRoot = mkdtempSync(join(tmpdir(), "htp-reproducible-build-"));
const probeSourceDirectory = resolve(contractsRoot, ".reproducibility-probe");

/**
 * @param {string} name
 */
function optionValue(name) {
  /** @type {string[]} */
  const values = [];
  for (let index = 2; index < process.argv.length; index += 1) {
    const argument = process.argv[index];
    if (argument === name) {
      const value = process.argv[index + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new Error(`${name} requires a path.`);
      }
      values.push(value);
      index += 1;
    } else if (argument.startsWith(`${name}=`)) {
      values.push(argument.slice(name.length + 1));
    }
  }
  if (values.length > 1) {
    throw new Error(`${name} may only be provided once.`);
  }
  return values[0];
}

/**
 * @param {string} directory
 * @returns {string[]}
 */
function listFiles(directory) {
  /** @type {string[]} */
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFiles(path));
    } else {
      files.push(path);
    }
  }
  return files;
}

/**
 * @param {string} directory
 */
function hasSoliditySources(directory) {
  try {
    return listFiles(directory).some((path) => path.endsWith(".sol"));
  } catch {
    return false;
  }
}

/**
 * @param {unknown} value
 * @returns {unknown}
 */
function sortDeep(value) {
  if (Array.isArray(value)) {
    return value.map(sortDeep);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, sortDeep(nested)]),
    );
  }
  return value;
}

/**
 * @param {string} outDirectory
 */
function collectManifest(outDirectory) {
  /** @type {Record<string, unknown>} */
  const manifest = {};
  for (const artifactPath of listFiles(outDirectory).filter((path) => path.endsWith(".json"))) {
    /** @type {any} */
    const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
    if (!Array.isArray(artifact.abi) || typeof artifact.bytecode?.object !== "string") {
      continue;
    }
    const creationBytecode = artifact.bytecode.object;
    const runtimeBytecode =
      typeof artifact.deployedBytecode?.object === "string" ? artifact.deployedBytecode.object : "0x";
    const normalizedRuntime =
      runtimeBytecode.startsWith("0x") ? runtimeBytecode : `0x${runtimeBytecode}`;
    manifest[relative(outDirectory, artifactPath)] = sortDeep({
      abi: artifact.abi,
      creationBytecode,
      runtimeBytecode,
      metadata: artifact.metadata ?? null,
      codeHash: keccak256(/** @type {`0x${string}`} */ (normalizedRuntime)),
    });
  }
  if (Object.keys(manifest).length === 0) {
    throw new Error("Forge produced no contract artifacts to compare.");
  }
  return sortDeep(manifest);
}

const projectHasSources = ["src", "test", "script"].some((path) =>
  hasSoliditySources(resolve(contractsRoot, path)),
);
if (!projectHasSources) {
  rmSync(probeSourceDirectory, { recursive: true, force: true });
  mkdirSync(probeSourceDirectory, { recursive: true });
  writeFileSync(
    resolve(probeSourceDirectory, "ReproducibilityProbe.sol"),
    [
      "// SPDX-License-Identifier: Apache-2.0",
      "pragma solidity 0.8.36;",
      "",
      "contract ReproducibilityProbe {",
      "    function combine(uint256 left, uint256 right) external pure returns (uint256) {",
      "        return left + right;",
      "    }",
      "}",
      "",
    ].join("\n"),
  );
}

/**
 * @param {string} name
 * @param {string[]} [compilerOverrides]
 */
function build(name, compilerOverrides = []) {
  const outputDirectory = resolve(temporaryRoot, `${name}-out`);
  const cacheDirectory = resolve(temporaryRoot, `${name}-cache`);
  const buildInfoDirectory = resolve(temporaryRoot, `${name}-build-info`);
  const args = [
    "build",
    "--root",
    contractsRoot,
    "--out",
    outputDirectory,
    "--cache-path",
    cacheDirectory,
    "--build-info",
    "--build-info-path",
    buildInfoDirectory,
    "--skip",
    "test",
    "--skip",
    "script",
  ];
  if (!projectHasSources) {
    args.push("--contracts", relative(contractsRoot, probeSourceDirectory));
  }
  args.push(...compilerOverrides);
  execFileSync("forge", args, {
    cwd: root,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (!statSync(outputDirectory).isDirectory()) {
    throw new Error(`Missing Forge output directory: ${outputDirectory}`);
  }
  return collectManifest(outputDirectory);
}

/**
 * @param {unknown} manifest
 */
function serialize(manifest) {
  return `${JSON.stringify(manifest)}\n`;
}

/**
 * @param {unknown} manifest
 */
function digest(manifest) {
  return createHash("sha256").update(serialize(manifest)).digest("hex");
}

try {
  const first = build("first");
  const second = build("second");
  const firstSerialized = serialize(first);
  const secondSerialized = serialize(second);
  if (firstSerialized !== secondSerialized) {
    throw new Error(
      `Reproducibility mismatch: first=${digest(first)}, second=${digest(second)}`,
    );
  }
  const deploymentArtifactManifest = createApprovedArtifactManifest(first);

  if (approvedManifestPath !== undefined) {
    const approvedManifest = JSON.parse(
      readFileSync(resolve(root, approvedManifestPath), "utf8"),
    );
    assertApprovedBuildArtifacts(approvedManifest, first);
    console.log(
      `Approved artifact manifest matched (${Object.keys(deploymentArtifactManifest.artifacts).length} deployable artifacts).`,
    );
  }

  if (writeManifestPath !== undefined) {
    const outputPath = resolve(root, writeManifestPath);
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, serialize(deploymentArtifactManifest));
    console.log(
      `Artifact manifest candidate written to ${relative(root, outputPath)}; generation does not grant production approval.`,
    );
  }

  if (selfTest) {
    /** @type {Array<[string, string[]]>} */
    const mutations = [
      ["optimizer-runs", ["--optimizer-runs", "201"]],
      ["via-ir", ["--via-ir"]],
      ["metadata", ["--no-metadata"]],
    ];
    for (const [name, args] of mutations) {
      const mutated = build(`mutated-${name}`, args);
      if (firstSerialized === serialize(mutated)) {
        throw new Error(`${name} mutation was not detected.`);
      }
    }

    const [artifactPath, approvedArtifact] = Object.entries(
      deploymentArtifactManifest.artifacts,
    )[0];
    const creationBytecode = approvedArtifact.creationBytecode;
    const mutatedCreationBytecode = `${creationBytecode.slice(0, 2)}${
      creationBytecode.slice(2, 4) === "00" ? "01" : "00"
    }${creationBytecode.slice(4)}`;
    let creationMutationDetected = false;
    try {
      assertApprovedCreationBytecode(
        deploymentArtifactManifest,
        artifactPath,
        mutatedCreationBytecode,
      );
    } catch {
      creationMutationDetected = true;
    }
    if (!creationMutationDetected) {
      throw new Error("Approved creation bytecode mutation was not detected.");
    }

    const runtimeBytecode = /** @type {any} */ (first)[artifactPath].runtimeBytecode;
    const mutatedRuntimeBytecode = `${runtimeBytecode.slice(0, 2)}${
      runtimeBytecode.slice(2, 4) === "00" ? "01" : "00"
    }${runtimeBytecode.slice(4)}`;
    let runtimeMutationDetected = false;
    try {
      assertApprovedRuntimeCodeHash(
        deploymentArtifactManifest,
        artifactPath,
        mutatedRuntimeBytecode,
      );
    } catch {
      runtimeMutationDetected = true;
    }
    if (!runtimeMutationDetected) {
      throw new Error("Deployed runtime codeHash mutation was not detected.");
    }
  }

  console.log(
    `Reproducible build passed (${Object.keys(/** @type {object} */ (first)).length} artifacts, sha256=${digest(first)}).`,
  );
  if (selfTest) {
    console.log(
      "Mutation self-test passed for optimizer runs, viaIR, metadata, approved creation bytecode, and deployed runtime codeHash.",
    );
  }
} finally {
  rmSync(temporaryRoot, { recursive: true, force: true });
  if (!projectHasSources) {
    rmSync(probeSourceDirectory, { recursive: true, force: true });
  }
}
