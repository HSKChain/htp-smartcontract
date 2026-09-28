import { keccak256 } from "viem";

const CODE_HASH_PATTERN = /^0x[0-9a-fA-F]{64}$/;
const BYTECODE_PATTERN = /^0x(?:[0-9a-fA-F]{2})*$/;

/**
 * @param {unknown} value
 * @param {string} label
 */
function normalizeBytecode(value, label) {
  if (typeof value !== "string" || !BYTECODE_PATTERN.test(value)) {
    throw new Error(`${label} must be 0x-prefixed, whole-byte hex.`);
  }
  return value.toLowerCase();
}

/**
 * @param {unknown} value
 * @param {string} label
 */
function normalizeCodeHash(value, label) {
  if (typeof value !== "string" || !CODE_HASH_PATTERN.test(value)) {
    throw new Error(`${label} must be a 32-byte 0x-prefixed hex value.`);
  }
  return value.toLowerCase();
}

/**
 * Converts a reproducible-build manifest into the minimal artifact baseline
 * consumed before and after deployment. Generating this file does not approve
 * it; approval remains an external release-control action.
 *
 * @param {unknown} reproducibleManifest
 */
export function createApprovedArtifactManifest(reproducibleManifest) {
  if (
    reproducibleManifest === null ||
    typeof reproducibleManifest !== "object" ||
    Array.isArray(reproducibleManifest)
  ) {
    throw new Error("Reproducible artifact manifest must be an object.");
  }

  /** @type {Record<string, {creationBytecode: string, runtimeCodeHash: string}>} */
  const artifacts = {};
  for (const [artifactPath, artifactValue] of Object.entries(reproducibleManifest)) {
    if (
      artifactValue === null ||
      typeof artifactValue !== "object" ||
      Array.isArray(artifactValue)
    ) {
      throw new Error(`Artifact ${artifactPath} must be an object.`);
    }
    const artifact = /** @type {Record<string, unknown>} */ (artifactValue);
    const creationBytecode = normalizeBytecode(
      artifact.creationBytecode,
      `Artifact ${artifactPath} creation bytecode`,
    );
    const runtimeCodeHash = normalizeCodeHash(
      artifact.codeHash,
      `Artifact ${artifactPath} runtime codeHash`,
    );

    // Interfaces, abstract contracts and source-only helper artifacts cannot be
    // deployed and therefore do not belong in a deployment approval baseline.
    if (creationBytecode === "0x") {
      continue;
    }
    artifacts[artifactPath] = { creationBytecode, runtimeCodeHash };
  }

  if (Object.keys(artifacts).length === 0) {
    throw new Error("Reproducible manifest contains no deployable artifacts.");
  }
  return { schemaVersion: 1, artifacts };
}

/**
 * Verifies that a reproducible build has exactly the artifacts, creation
 * bytecode and runtime code hashes recorded by an externally approved
 * manifest.
 *
 * @param {unknown} approvedManifest
 * @param {unknown} reproducibleManifest
 */
export function assertApprovedBuildArtifacts(approvedManifest, reproducibleManifest) {
  const actualManifest = createApprovedArtifactManifest(reproducibleManifest);
  const actualPaths = Object.keys(actualManifest.artifacts).sort();
  if (
    approvedManifest === null ||
    typeof approvedManifest !== "object" ||
    Array.isArray(approvedManifest)
  ) {
    throw new Error("Approved artifact manifest must be an object.");
  }
  const approved = /** @type {Record<string, unknown>} */ (approvedManifest);
  if (
    approved.artifacts === null ||
    typeof approved.artifacts !== "object" ||
    Array.isArray(approved.artifacts)
  ) {
    throw new Error("Approved artifact manifest artifacts must be an object.");
  }
  const approvedPaths = Object.keys(approved.artifacts).sort();
  if (JSON.stringify(actualPaths) !== JSON.stringify(approvedPaths)) {
    throw new Error(
      `Approved artifact set mismatch: expected=${approvedPaths.join(",")}, actual=${actualPaths.join(",")}.`,
    );
  }
  for (const artifactPath of actualPaths) {
    const expected = approvedArtifact(approvedManifest, artifactPath);
    const actual = actualManifest.artifacts[artifactPath];
    if (actual.creationBytecode !== expected.creationBytecode) {
      throw new Error(`Creation bytecode mismatch for ${artifactPath}.`);
    }
    if (actual.runtimeCodeHash !== expected.runtimeCodeHash) {
      throw new Error(`Runtime codeHash mismatch for ${artifactPath}.`);
    }
  }
}

/**
 * @param {unknown} approvedManifest
 * @param {string} artifactPath
 */
function approvedArtifact(approvedManifest, artifactPath) {
  if (
    approvedManifest === null ||
    typeof approvedManifest !== "object" ||
    Array.isArray(approvedManifest)
  ) {
    throw new Error("Approved artifact manifest must be an object.");
  }
  const manifest = /** @type {Record<string, unknown>} */ (approvedManifest);
  if (manifest.schemaVersion !== 1) {
    throw new Error(`Unsupported approved artifact schemaVersion: ${String(manifest.schemaVersion)}.`);
  }
  if (
    manifest.artifacts === null ||
    typeof manifest.artifacts !== "object" ||
    Array.isArray(manifest.artifacts)
  ) {
    throw new Error("Approved artifact manifest artifacts must be an object.");
  }
  const value = /** @type {Record<string, unknown>} */ (manifest.artifacts)[artifactPath];
  if (value === undefined) {
    throw new Error(`Approved artifact not found: ${artifactPath}.`);
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Approved artifact ${artifactPath} must be an object.`);
  }
  const artifact = /** @type {Record<string, unknown>} */ (value);
  return {
    creationBytecode: normalizeBytecode(
      artifact.creationBytecode,
      `Approved artifact ${artifactPath} creation bytecode`,
    ),
    runtimeCodeHash: normalizeCodeHash(
      artifact.runtimeCodeHash,
      `Approved artifact ${artifactPath} runtime codeHash`,
    ),
  };
}

/**
 * @param {unknown} approvedManifest
 * @param {string} artifactPath
 * @param {unknown} creationBytecode
 */
export function assertApprovedCreationBytecode(
  approvedManifest,
  artifactPath,
  creationBytecode,
) {
  const approved = approvedArtifact(approvedManifest, artifactPath);
  const actual = normalizeBytecode(creationBytecode, "Candidate creation bytecode");
  if (actual !== approved.creationBytecode) {
    throw new Error(`Creation bytecode mismatch for ${artifactPath}.`);
  }
}

/**
 * @param {unknown} approvedManifest
 * @param {string} artifactPath
 * @param {unknown} runtimeBytecode
 */
export function assertApprovedRuntimeCodeHash(
  approvedManifest,
  artifactPath,
  runtimeBytecode,
) {
  const approved = approvedArtifact(approvedManifest, artifactPath);
  const runtime = normalizeBytecode(runtimeBytecode, "Deployed runtime bytecode");
  const actualCodeHash = keccak256(/** @type {`0x${string}`} */ (runtime));
  if (actualCodeHash !== approved.runtimeCodeHash) {
    throw new Error(
      `Runtime codeHash mismatch for ${artifactPath}: expected=${approved.runtimeCodeHash}, actual=${actualCodeHash}.`,
    );
  }
}

/**
 * @param {{
 *   approvedManifest: unknown,
 *   artifactPath: string,
 *   creationBytecode: unknown,
 *   runtimeBytecode: unknown,
 * }} input
 */
export function verifyApprovedDeployment(input) {
  assertApprovedCreationBytecode(
    input.approvedManifest,
    input.artifactPath,
    input.creationBytecode,
  );
  assertApprovedRuntimeCodeHash(
    input.approvedManifest,
    input.artifactPath,
    input.runtimeBytecode,
  );
}
