import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import { selectProductionBuildInfo } from "../src/build-info.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

test("selectProductionBuildInfo returns the unique complete AST+ABI candidate", () => {
  const selected = selectProductionBuildInfo(repositoryRoot);
  assert.match(selected.solcLongVersion, /^0\.8\.36/);
  assert.ok(
    Array.isArray(selected.buildInfo.output.sources["src/types/HTPTypes.sol"].ast.nodes),
  );
  assert.ok(
    selected.buildInfo.output.contracts["src/interfaces/IDvPSettlement.sol"].IDvPSettlement.abi.some(
      (entry: { type: string }) => entry.type === "function",
    ),
  );
});

test("selectProductionBuildInfo fails closed when build-info is missing", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "htp-no-build-info-"));
  try {
    assert.throws(() => selectProductionBuildInfo(temporaryDirectory), /build-info/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
