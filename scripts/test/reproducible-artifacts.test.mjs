import assert from "node:assert/strict";
import test from "node:test";
import { keccak256 } from "viem";

import {
  assertApprovedBuildArtifacts,
  assertApprovedCreationBytecode,
  assertApprovedRuntimeCodeHash,
  createApprovedArtifactManifest,
  verifyApprovedDeployment,
} from "../reproducible-artifacts.mjs";

const artifactPath = "DvPSettlement.sol/DvPSettlement.json";
const creationBytecode = "0x6001600055";
const runtimeBytecode = "0x60016000f3";

function reproducibleManifest() {
  return {
    [artifactPath]: {
      abi: [{ type: "constructor", inputs: [] }],
      creationBytecode,
      runtimeBytecode,
      metadata: { compiler: { version: "0.8.36" } },
      codeHash: keccak256(runtimeBytecode),
    },
  };
}

test("creates a deployment approval manifest from reproducible artifacts", () => {
  const manifest = createApprovedArtifactManifest(reproducibleManifest());

  assert.deepEqual(manifest, {
    schemaVersion: 1,
    artifacts: {
      [artifactPath]: {
        creationBytecode,
        runtimeCodeHash: keccak256(runtimeBytecode),
      },
    },
  });
});

test("accepts approved creation bytecode and deployed runtime code", () => {
  const manifest = createApprovedArtifactManifest(reproducibleManifest());

  assert.doesNotThrow(() =>
    assertApprovedBuildArtifacts(manifest, reproducibleManifest()),
  );
  assert.doesNotThrow(() =>
    verifyApprovedDeployment({
      approvedManifest: manifest,
      artifactPath,
      creationBytecode,
      runtimeBytecode,
    }),
  );
});

test("rejects creation-bytecode and runtime-code mutations", () => {
  const manifest = createApprovedArtifactManifest(reproducibleManifest());
  const mutatedBuild = reproducibleManifest();
  mutatedBuild[artifactPath].creationBytecode = "0x6002600055";

  assert.throws(
    () => assertApprovedBuildArtifacts(manifest, mutatedBuild),
    /Creation bytecode mismatch/,
  );
  assert.throws(
    () => assertApprovedCreationBytecode(manifest, artifactPath, "0x6002600055"),
    /Creation bytecode mismatch/,
  );
  assert.throws(
    () => assertApprovedRuntimeCodeHash(manifest, artifactPath, "0x60026000f3"),
    /Runtime codeHash mismatch/,
  );
});

test("rejects missing artifacts and malformed approval manifests", () => {
  const manifest = createApprovedArtifactManifest(reproducibleManifest());

  assert.throws(
    () =>
      assertApprovedBuildArtifacts(
        { ...manifest, artifacts: { ...manifest.artifacts, "Extra.sol/Extra.json": {} } },
        reproducibleManifest(),
      ),
    /Approved artifact set mismatch/,
  );
  assert.throws(
    () => assertApprovedCreationBytecode(manifest, "Missing.sol/Missing.json", creationBytecode),
    /Approved artifact not found/,
  );
  assert.throws(
    () => createApprovedArtifactManifest({ [artifactPath]: { creationBytecode } }),
    /runtime codeHash/,
  );
});
