import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import {
  buildSchemaBundle,
  checkSchemaDirectory,
  extractConfigSourceMetadata,
  writeSchemaDirectory,
} from "../src/schema.js";
import { SCHEMA_DOCUMENT_PATHS } from "../src/paths.js";
import { buildSchemaModel } from "../src/model.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

test("manifest drift is rejected", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-manifest-drift-"));
  try {
    const bundle = buildSchemaBundle(repositoryRoot);
    writeSchemaDirectory(bundle, temporaryDirectory);
    checkSchemaDirectory(bundle, temporaryDirectory);

    const manifestPath = join(temporaryDirectory, "manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.schemaVersion = 999;
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /manifest drift/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("current manifest excludes superseded machine names", () => {
  const serialized = JSON.stringify(buildSchemaBundle(repositoryRoot));
  for (const superseded of [
    "RequesterType",
    "cashToken",
    "cashDecimals",
    "proxyCodeHash",
    "CASH_TO_",
    "TOKEN_CHECK_AND_DVP_ETH_CALL",
    "\"scopeHash\"",
  ]) {
    assert.equal(serialized.includes(superseded), false, superseded);
  }
});

test("generated document content and root file set drift are rejected", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-document-drift-"));
  try {
    const bundle = buildSchemaBundle(repositoryRoot);
    writeSchemaDirectory(bundle, temporaryDirectory);
    const enumsPath = join(temporaryDirectory, SCHEMA_DOCUMENT_PATHS.enums);
    const enums = JSON.parse(readFileSync(enumsPath, "utf8"));
    enums.schemaVersion = 999;
    writeFileSync(enumsPath, `${JSON.stringify(enums, null, 2)}\n`);
    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /types\/enums\.json/);

    writeSchemaDirectory(bundle, temporaryDirectory);
    writeFileSync(join(temporaryDirectory, "unexpected.json"), "{}\n");
    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /file set differs/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("error and event catalogs contain production compilation targets only", () => {
  const bundle = buildSchemaBundle(repositoryRoot);
  for (const name of [SCHEMA_DOCUMENT_PATHS.errors, SCHEMA_DOCUMENT_PATHS.events]) {
    const document = bundle.documents[name] as any;
    assert.match(document.generatedFrom, /compiled production ABI/);
    const entries = document.errors ?? document.events;
    assert.ok(entries.length > 0);
    for (const entry of entries) {
      assert.ok(entry.sources.length > 0);
      assert.ok(entry.sources.every((source: string) => source.startsWith("src/")));
      assert.equal(entry.sources.some((source: string) => source.startsWith("test/")), false);
    }
  }
});

test("ConfigId and FeeScope source constant mutations produce detectable schema drift", () => {
  const bundle = buildSchemaBundle(repositoryRoot);
  const current = extractConfigSourceMetadata(buildSchemaModel(repositoryRoot));
  const mutated = structuredClone(current);
  mutated.configIdNamespaces.FEE_NAMESPACE = {
    preimage: "HTP_FEE_CONFIG_MUTATED",
    namespaceHash: "0xdeadbeef",
  };
  mutated.feeScope = {
    constant: "TYPEHASH",
    typeString: "FeeScopeMutated(uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash)",
    typeHash: "0xbeef",
  };
  assert.notEqual(
    mutated.configIdNamespaces.FEE_NAMESPACE?.namespaceHash,
    current.configIdNamespaces.FEE_NAMESPACE?.namespaceHash,
  );
  assert.notEqual(mutated.feeScope.typeHash, current.feeScope.typeHash);

  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-config-source-drift-"));
  try {
    writeSchemaDirectory(bundle, temporaryDirectory);
    const configsPath = join(temporaryDirectory, SCHEMA_DOCUMENT_PATHS.configs);
    const configs = JSON.parse(readFileSync(configsPath, "utf8"));
    assert.deepEqual(configs.sourceConstants, current);
    configs.sourceConstants = mutated;
    writeFileSync(configsPath, `${JSON.stringify(configs, null, 2)}\n`);
    assert.throws(() => checkSchemaDirectory(bundle, temporaryDirectory), /protocol\/configs\.json/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
