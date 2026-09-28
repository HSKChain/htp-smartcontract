import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";

import { buildSchemaModel } from "../src/model.js";
import { SCHEMA_DOCUMENT_PATHS } from "../src/paths.js";
import { buildSchemaBundle } from "../src/schema.js";
import { emptyEncodingSize } from "../src/solidity-layout.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

function layoutOf(
  bundle: ReturnType<typeof buildSchemaBundle>,
  name: string,
) {
  const layouts = bundle.documents[SCHEMA_DOCUMENT_PATHS.layouts] as {
    structs: Array<{
      name: string;
      dynamic: boolean;
      headByteLength: number;
      fields: Array<{ name: string; headOffset: number; dynamic: boolean }>;
    }>;
  };
  const struct = layouts.structs.find((entry) => entry.name === name);
  assert.ok(struct, name);
  return struct;
}

test("generated layouts encode FirmQuote ABI head offsets from the AST", () => {
  const bundle = buildSchemaBundle(repositoryRoot);
  const firmQuote = layoutOf(bundle, "FirmQuote");
  assert.equal(firmQuote.dynamic, true);
  assert.equal(firmQuote.headByteLength, 31 * 32);
  assert.equal(firmQuote.fields[13]?.name, "priceData");
  assert.equal(firmQuote.fields[13]?.dynamic, true);
  assert.equal(firmQuote.fields[13]?.headOffset, 13 * 32);
  assert.equal(firmQuote.fields[9]?.name, "assetToken");
  assert.equal(firmQuote.fields[9]?.headOffset, 9 * 32);
});

test("generated layouts encode TradeIntent, Snapshot, FeeConfig, and SettlementParams heads", () => {
  const bundle = buildSchemaBundle(repositoryRoot);
  const tradeIntent = layoutOf(bundle, "TradeIntent");
  assert.equal(tradeIntent.dynamic, true);
  assert.equal(tradeIntent.headByteLength, 39 * 32);
  assert.equal(tradeIntent.fields[16]?.name, "priceData");
  assert.equal(tradeIntent.fields[16]?.headOffset, 16 * 32);

  const snapshot = layoutOf(bundle, "TradeTermsSnapshot");
  assert.equal(snapshot.dynamic, true);
  assert.equal(snapshot.headByteLength, 45 * 32);
  assert.equal(snapshot.fields[19]?.name, "priceData");
  assert.equal(snapshot.fields[19]?.headOffset, 19 * 32);

  const feeConfig = layoutOf(bundle, "FeeConfig");
  assert.equal(feeConfig.dynamic, false);
  assert.equal(feeConfig.headByteLength, 24 * 32);
  assert.equal(feeConfig.fields[6]?.name, "scopeKeyHash");
  assert.equal(feeConfig.fields[7]?.name, "matchedScopeHash");
  assert.equal(feeConfig.fields[7]?.headOffset, 7 * 32);

  const settlementParams = layoutOf(bundle, "SettlementParams");
  assert.equal(settlementParams.dynamic, true);
  assert.equal(settlementParams.headByteLength, 672);
  assert.equal(settlementParams.fields[0]?.name, "firmQuote");
  assert.equal(settlementParams.fields[5]?.name, "assetPermit");
  assert.equal(settlementParams.fields[5]?.dynamic, false);
  assert.equal(settlementParams.fields[5]?.headOffset, 160);
});

test("empty dynamic encodings place the first tail at the ABI head length", () => {
  const model = buildSchemaModel(repositoryRoot);
  assert.equal(emptyEncodingSize(model.structs.FirmQuote!, model.structs), 31 * 32 + 32);
  assert.equal(emptyEncodingSize(model.structs.TradeIntent!, model.structs), 39 * 32 + 32);
  assert.equal(emptyEncodingSize(model.structs.FeeConfig!, model.structs), 24 * 32);
});
