import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";

import { encodeEip712TypeString, mergeEip712Types } from "../src/eip712.js";
import { buildSchemaModel } from "../src/model.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

test("EIP-712 types come from HTPHashing type strings, not storage structs", () => {
  const model = buildSchemaModel(repositoryRoot);
  const types = mergeEip712Types([
    ...Object.values(model.typehashes).map((entry) => entry.typeString),
    model.feeScope.typeString,
  ]);
  assert.deepEqual(
    types.FirmQuote?.map((field) => field.name),
    [
      "schemaVersion",
      "rfqIdHash",
      "quoteIdHash",
      "tradeIdHash",
      "quoteVersion",
      "quotingMaker",
      "requester",
      "requesterType",
      "assetVersionId",
      "requesterSide",
      "assetToken",
      "settlementToken",
      "assetClass",
      "priceTermsHash",
      "priceData",
      "principalCalculatorConfigId",
      "principalCalculatorConfigHash",
      "adapterConfigId",
      "adapterConfigHash",
      "settlementTokenConfigId",
      "settlementTokenConfigHash",
      "marketRuleConfigId",
      "marketRuleConfigHash",
      "minExecutableQuantity",
      "maxExecutableQuantity",
      "stepQuantity",
      "feePolicyEpoch",
      "feeVersionId",
      "matchedScopeHash",
      "feeConstraintHash",
      "quoteNonce",
      "expiresAt",
    ],
  );
  assert.equal(
    types.FeeConfig?.some((field) => field.name === "configHash"),
    false,
  );
  assert.equal(
    model.structs.FeeConfig?.fields.some((field) => field.name === "configHash"),
    true,
  );
  assert.equal(
    encodeEip712TypeString("FirmQuote", types),
    model.typehashes.FIRM_QUOTE_TYPEHASH?.typeString,
  );
  assert.equal(
    encodeEip712TypeString("FeeScope", types),
    model.feeScope.typeString,
  );
});
