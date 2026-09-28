import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import {
  buildSchemaBundle,
  checkSchemaDirectory,
  writeSchemaDirectory,
} from "../src/schema.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

test("ABI drift is rejected", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-abi-drift-"));
  try {
    const bundle = buildSchemaBundle(repositoryRoot);
    const interfaceName = Object.keys(bundle.abis).sort()[0];
    assert.ok(interfaceName, "at least one public interface ABI is required");
    writeSchemaDirectory(bundle, temporaryDirectory);
    checkSchemaDirectory(bundle, temporaryDirectory);

    const abiPath = join(temporaryDirectory, "abi", `${interfaceName}.json`);
    const abi = JSON.parse(readFileSync(abiPath, "utf8"));
    abi.push({ type: "function", name: "tampered", inputs: [], outputs: [] });
    writeFileSync(abiPath, `${JSON.stringify(abi, null, 2)}\n`);

    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /ABI drift/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("stale ABI from a deleted interface is rejected", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-stale-abi-"));
  try {
    const bundle = buildSchemaBundle(repositoryRoot);
    writeSchemaDirectory(bundle, temporaryDirectory);
    writeFileSync(
      join(temporaryDirectory, "abi", "DeletedInterface.json"),
      `${JSON.stringify([], null, 2)}\n`,
    );
    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /file set differs/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
