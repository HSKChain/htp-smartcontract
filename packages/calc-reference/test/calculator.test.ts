import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import test from "node:test";

import {
  MAX_UINT256,
  calculateBond,
  calculateCashPrincipal,
  calculateFund,
  calculateStock,
  requireValidCalendarDate,
} from "../src/index.js";

const hash = (suffix: string) => `0x${suffix.padStart(64, "0")}` as const;

test("Fund reference vector prices 100 USDY at NAV 1.14", () => {
  const result = calculateFund(
    {
      navPerUnit: 1_140_000n,
      navDate: 20_260_810,
      navSourceHash: hash("201"),
    },
    100n * 10n ** 18n,
    18,
  );

  assert.equal(result.priceData.length, 2 + 96 * 2);
  assert.equal(result.priceTermsHash, "0x43dd8313df1b71f18f367e8a41d0af124cb97d0297aae168e2d9a0132a7dd439");
  assert.equal(result.quotedPrice, 1_140_000n);
  assert.equal(result.unitCashPrice, 1_140_000n);
  assert.equal(result.cashPrincipal, 114_000_000n);
});

test("Stock and Bond hashes match independently reviewed Phase 3 literals", () => {
  const stock = calculateStock(
    {
      unitPrice: 2_345_678n,
      priceAsOf: 1_780_000_000n,
      referenceMarketHash: hash("701"),
      priceSourceHash: hash("702"),
    },
    25n * 10n ** 6n,
    6,
  );
  assert.equal(stock.priceData.length, 2 + 128 * 2);
  assert.equal(stock.priceTermsHash, "0x5cb821f6c2dccfaae82edcd379059433b9985de79ccbd1dc5da0e21bbd2a767d");
  assert.equal(stock.quotedPrice, 2_345_678n);
  assert.equal(stock.cashPrincipal, 58_641_950n);

  const bond = calculateBond(
    {
      cleanPricePerUnit: 980_000n,
      accruedInterestPerUnit: 12_500n,
      settlementDate: 20_260_812,
      sourceHash: hash("703"),
    },
    3n * 10n ** 8n,
    8,
  );
  assert.equal(bond.priceData.length, 2 + 128 * 2);
  assert.equal(bond.priceTermsHash, "0xd0ef1df61af5833f5bf30eab0e447a60118f6b8525cf0c63954a1ad5cd2182cb");
  assert.equal(bond.quotedPrice, 980_000n);
  assert.equal(bond.unitCashPrice, 992_500n);
  assert.equal(bond.cashPrincipal, 2_977_500n);
});

test("BigInt reference preserves full precision and rounds down", () => {
  assert.equal(calculateCashPrincipal(5n, 3n, 1), 1n);
  assert.equal(calculateCashPrincipal(MAX_UINT256, 10n ** 36n, 36), MAX_UINT256);
  assert.throws(() => calculateCashPrincipal(1n, 1n, 1), /CASH_PRINCIPAL_ZERO/);
  assert.throws(() => calculateCashPrincipal(1n, 1n, 37), /ASSET_DECIMALS_OUT_OF_RANGE/);
});

test("Gregorian and Bond overflow boundaries fail closed", () => {
  requireValidCalendarDate(20_000_229);
  assert.throws(() => requireValidCalendarDate(19_000_229), /INVALID_CALENDAR_DATE/);
  assert.throws(() => requireValidCalendarDate(100_000_101), /INVALID_CALENDAR_DATE/);
  assert.throws(
    () =>
      calculateBond(
        {
          cleanPricePerUnit: MAX_UINT256,
          accruedInterestPerUnit: 1n,
          settlementDate: 20_260_812,
          sourceHash: hash("703"),
        },
        1n,
        0,
      ),
    /BOND_FULL_PRICE_OVERFLOW/,
  );
});

test("generated vectors expose the portable Calculator schema and failure boundaries", () => {
  const document = JSON.parse(
    readFileSync(resolve(import.meta.dirname, "../../../schema/v1/vectors/calculators/all-v1.json"), "utf8"),
  );
  const vectors = [
    ...Object.values(document.valid),
    ...document.fuzzCorpus,
    ...document.invalidCorpus,
    ...Object.values(document.deferredComparisons),
  ];
  const requiredFields = [
    "schemaVersion",
    "assetClass",
    "priceTerms",
    "priceData",
    "priceTermsHash",
    "assetDecimals",
    "executedQuantity",
    "unitCashPrice",
    "cashPrincipal",
    "expected",
  ];

  for (const vector of vectors) {
    assert.equal(vector.schemaVersion, 1);
    for (const field of requiredFields) {
      assert.ok(Object.hasOwn(vector, field), `missing ${field}`);
    }
  }

  assert.equal(document.invalidCorpusSize, 9);
  assert.deepEqual(
    new Set(document.invalidCorpus.map((vector: {expectedError: string}) => vector.expectedError)),
    new Set([
      "ASSET_DECIMALS_OUT_OF_RANGE",
      "BOND_FULL_PRICE_OVERFLOW",
      "CASH_PRINCIPAL_ZERO",
      "INVALID_CALENDAR_DATE",
      "PRICE_DATA_MALFORMED",
      "PRICE_DATA_MALFORMED_INCOMPATIBLE_LENGTH",
    ]),
  );
  assert.equal(document.deferredComparisons.fundHashMismatch.enforcedBy, "DvPSettlement");
  assert.equal(
    document.deferredComparisons.bondTermsWithStockCalculator.enforcedBy,
    "PrincipalCalculatorRegistry",
  );
});
