// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { Enum } from "./lib/htp-hash.mjs";

test("operational FeeVersionStatus mirrors the generated Solidity schema", () => {
  const schema = JSON.parse(readFileSync("schema/v1/types/enums.json", "utf8"));
  const feeVersionStatus = schema.enums.find((entry) => entry.name === "FeeVersionStatus");
  assert.ok(feeVersionStatus);
  assert.deepEqual(
    Enum.FeeVersionStatus,
    Object.fromEntries(feeVersionStatus.members.map(({ name, value }) => [name, value])),
  );
});
