import {mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {keccak256, stringToHex, type Hex} from "viem";

import {
  MAX_UINT256,
  calculateBond,
  calculateFund,
  calculateStock,
  encodeBondPriceTerms,
  encodeFundPriceTerms,
  encodeStockPriceTerms,
  hashBondPriceTerms,
  hashFundPriceTerms,
  hashStockPriceTerms,
  type BondPriceTerms,
  type CalculationResult,
  type FundPriceTerms,
  type StockPriceTerms,
} from "./index.js";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const sourceHash = (suffix: string) => `0x${suffix.padStart(64, "0")}` as `0x${string}`;

type PriceTerms = StockPriceTerms | FundPriceTerms | BondPriceTerms;

function serializePriceTerms(priceTerms: PriceTerms | null) {
  if (priceTerms === null) return null;
  return Object.fromEntries(
    Object.entries(priceTerms).map(([key, value]) => [key, typeof value === "bigint" ? value.toString() : value]),
  );
}

function serializeResult(
  assetClass: "STOCK" | "FUND" | "BOND",
  priceTerms: PriceTerms,
  executedQuantity: bigint,
  assetDecimals: number,
  result: CalculationResult,
) {
  const assetClassId = {STOCK: 1, FUND: 2, BOND: 3}[assetClass];
  return {
    schemaVersion: 1,
    assetClass,
    assetClassId,
    priceTerms: serializePriceTerms(priceTerms),
    priceData: result.priceData,
    priceTermsHash: result.priceTermsHash,
    executedQuantity: executedQuantity.toString(),
    assetDecimals,
    quotedPrice: result.quotedPrice.toString(),
    unitCashPrice: result.unitCashPrice.toString(),
    cashPrincipal: result.cashPrincipal.toString(),
    expected: "success",
  };
}

function serializeErrorVector(input: {
  assetClass: "STOCK" | "FUND" | "BOND";
  priceTerms: PriceTerms | null;
  priceData: Hex;
  priceTermsHash: Hex | null;
  executedQuantity: bigint;
  assetDecimals: number;
  expectedError: string;
  expectedErrorSelector: Hex;
}) {
  return {
    schemaVersion: 1,
    assetClass: input.assetClass,
    assetClassId: {STOCK: 1, FUND: 2, BOND: 3}[input.assetClass],
    priceTerms: serializePriceTerms(input.priceTerms),
    priceData: input.priceData,
    priceTermsHash: input.priceTermsHash,
    executedQuantity: input.executedQuantity.toString(),
    assetDecimals: input.assetDecimals,
    quotedPrice: null,
    unitCashPrice: null,
    cashPrincipal: null,
    expected: "error",
    expectedError: input.expectedError,
    expectedErrorSelector: input.expectedErrorSelector,
  };
}

function buildFuzzCorpus() {
  const vectors = [];
  for (let assetDecimals = 0; assetDecimals <= 36; assetDecimals += 1) {
    const scale = 10n ** BigInt(assetDecimals);
    for (let sample = 0; sample < 3; sample += 1) {
      const remainder =
        scale === 1n ? 0n : BigInt((assetDecimals + 1) * (sample + 1) ** 2) % scale;
      const executedQuantity =
        scale * BigInt(assetDecimals + 2 + sample * 41) + remainder;
      const variation = BigInt(assetDecimals * 3 + sample);

      const stockTerms: StockPriceTerms = {
        unitPrice: 2_345_678n + variation,
        priceAsOf: 1_780_000_000n + variation,
        referenceMarketHash: sourceHash("701"),
        priceSourceHash: sourceHash("702"),
      };
      vectors.push(
        serializeResult(
          "STOCK",
          stockTerms,
          executedQuantity,
          assetDecimals,
          calculateStock(stockTerms, executedQuantity, assetDecimals),
        ),
      );

      const fundTerms: FundPriceTerms = {
        navPerUnit: 1_140_000n + variation,
        navDate: 20_000_229,
        navSourceHash: sourceHash("201"),
      };
      vectors.push(
        serializeResult(
          "FUND",
          fundTerms,
          executedQuantity,
          assetDecimals,
          calculateFund(fundTerms, executedQuantity, assetDecimals),
        ),
      );

      const bondTerms: BondPriceTerms = {
        cleanPricePerUnit: 980_000n + variation,
        accruedInterestPerUnit: BigInt(assetDecimals * 17 + sample),
        settlementDate: 20_000_229,
        sourceHash: sourceHash("703"),
      };
      vectors.push(
        serializeResult(
          "BOND",
          bondTerms,
          executedQuantity,
          assetDecimals,
          calculateBond(bondTerms, executedQuantity, assetDecimals),
        ),
      );
    }
  }

  const boundaryQuantity = MAX_UINT256;
  const boundaryDecimals = 36;
  const boundaryStock: StockPriceTerms = {
    unitPrice: 2_345_678n,
    priceAsOf: 1_780_000_000n,
    referenceMarketHash: sourceHash("701"),
    priceSourceHash: sourceHash("702"),
  };
  const boundaryFund: FundPriceTerms = {
    navPerUnit: 1_140_000n,
    navDate: 20_000_229,
    navSourceHash: sourceHash("201"),
  };
  const boundaryBond: BondPriceTerms = {
    cleanPricePerUnit: 980_000n,
    accruedInterestPerUnit: 12_500n,
    settlementDate: 20_000_229,
    sourceHash: sourceHash("703"),
  };
  vectors.push(
    serializeResult(
      "STOCK",
      boundaryStock,
      boundaryQuantity,
      boundaryDecimals,
      calculateStock(boundaryStock, boundaryQuantity, boundaryDecimals),
    ),
    serializeResult(
      "FUND",
      boundaryFund,
      boundaryQuantity,
      boundaryDecimals,
      calculateFund(boundaryFund, boundaryQuantity, boundaryDecimals),
    ),
    serializeResult(
      "BOND",
      boundaryBond,
      boundaryQuantity,
      boundaryDecimals,
      calculateBond(boundaryBond, boundaryQuantity, boundaryDecimals),
    ),
  );

  return vectors;
}

function errorSelector(signature: string): Hex {
  return keccak256(stringToHex(signature)).slice(0, 10) as Hex;
}

function buildInvalidCorpus() {
  const validFund: FundPriceTerms = {
    navPerUnit: 1n,
    navDate: 20_000_229,
    navSourceHash: sourceHash("201"),
  };
  const overflowingBond: BondPriceTerms = {
    cleanPricePerUnit: MAX_UINT256,
    accruedInterestPerUnit: 1n,
    settlementDate: 20_000_229,
    sourceHash: sourceHash("703"),
  };
  const invalidDateFund = {...validFund, navDate: 19_000_229};
  const zeroPriceStock: StockPriceTerms = {
    unitPrice: 0n,
    priceAsOf: 1n,
    referenceMarketHash: sourceHash("701"),
    priceSourceHash: sourceHash("702"),
  };
  const validFundPriceData = encodeFundPriceTerms(validFund);

  return [
    serializeErrorVector({
      assetClass: "FUND",
      priceTerms: validFund,
      priceData: validFundPriceData,
      priceTermsHash: hashFundPriceTerms(validFund),
      executedQuantity: 1n,
      assetDecimals: 1,
      expectedError: "CASH_PRINCIPAL_ZERO",
      expectedErrorSelector: errorSelector("CashPrincipalZero()"),
    }),
    serializeErrorVector({
      assetClass: "FUND",
      priceTerms: validFund,
      priceData: validFundPriceData,
      priceTermsHash: hashFundPriceTerms(validFund),
      executedQuantity: 0n,
      assetDecimals: 0,
      expectedError: "CASH_PRINCIPAL_ZERO",
      expectedErrorSelector: errorSelector("CashPrincipalZero()"),
    }),
    serializeErrorVector({
      assetClass: "FUND",
      priceTerms: validFund,
      priceData: validFundPriceData,
      priceTermsHash: hashFundPriceTerms(validFund),
      executedQuantity: 1n,
      assetDecimals: 37,
      expectedError: "ASSET_DECIMALS_OUT_OF_RANGE",
      expectedErrorSelector: errorSelector("AssetDecimalsOutOfRange(uint8)"),
    }),
    serializeErrorVector({
      assetClass: "BOND",
      priceTerms: overflowingBond,
      priceData: encodeBondPriceTerms(overflowingBond),
      priceTermsHash: hashBondPriceTerms(overflowingBond),
      executedQuantity: 1n,
      assetDecimals: 0,
      expectedError: "BOND_FULL_PRICE_OVERFLOW",
      expectedErrorSelector: errorSelector("BondFullPriceOverflow(uint256,uint256)"),
    }),
    serializeErrorVector({
      assetClass: "FUND",
      priceTerms: invalidDateFund,
      priceData: encodeFundPriceTerms(invalidDateFund),
      priceTermsHash: hashFundPriceTerms(invalidDateFund),
      executedQuantity: 1n,
      assetDecimals: 0,
      expectedError: "INVALID_CALENDAR_DATE",
      expectedErrorSelector: errorSelector("InvalidCalendarDate(uint32)"),
    }),
    serializeErrorVector({
      assetClass: "STOCK",
      priceTerms: zeroPriceStock,
      priceData: encodeStockPriceTerms(zeroPriceStock),
      priceTermsHash: hashStockPriceTerms(zeroPriceStock),
      executedQuantity: 1n,
      assetDecimals: 0,
      expectedError: "PRICE_DATA_MALFORMED",
      expectedErrorSelector: errorSelector("PriceDataMalformed(uint8)"),
    }),
    serializeErrorVector({
      assetClass: "BOND",
      priceTerms: null,
      priceData: "0x",
      priceTermsHash: null,
      executedQuantity: 1n,
      assetDecimals: 0,
      expectedError: "PRICE_DATA_MALFORMED",
      expectedErrorSelector: errorSelector("PriceDataMalformed(uint8)"),
    }),
    serializeErrorVector({
      assetClass: "FUND",
      priceTerms: validFund,
      priceData: `${validFundPriceData}00` as Hex,
      priceTermsHash: hashFundPriceTerms(validFund),
      executedQuantity: 1n,
      assetDecimals: 0,
      expectedError: "PRICE_DATA_MALFORMED",
      expectedErrorSelector: errorSelector("PriceDataMalformed(uint8)"),
    }),
    {
      ...serializeErrorVector({
        assetClass: "STOCK",
        priceTerms: validFund,
        priceData: validFundPriceData,
        priceTermsHash: hashFundPriceTerms(validFund),
        executedQuantity: 1n,
        assetDecimals: 0,
        expectedError: "PRICE_DATA_MALFORMED_INCOMPATIBLE_LENGTH",
        expectedErrorSelector: errorSelector("PriceDataMalformed(uint8)"),
      }),
      inputMutation: "FUND_ENCODING_FOR_STOCK_CALCULATOR",
    },
  ];
}

function buildBootstrap() {
  const fundTerms: FundPriceTerms = {
    navPerUnit: 1_140_000n,
    navDate: 20_260_810,
    navSourceHash: sourceHash("201"),
  };
  const stockTerms: StockPriceTerms = {
    unitPrice: 2_345_678n,
    priceAsOf: 1_780_000_000n,
    referenceMarketHash: sourceHash("701"),
    priceSourceHash: sourceHash("702"),
  };
  const bondTerms: BondPriceTerms = {
    cleanPricePerUnit: 980_000n,
    accruedInterestPerUnit: 12_500n,
    settlementDate: 20_260_812,
    sourceHash: sourceHash("703"),
  };
  const roundingTerms: FundPriceTerms = {
    navPerUnit: 3n,
    navDate: 20_000_229,
    navSourceHash: sourceHash("204"),
  };
  const fuzzCorpus = buildFuzzCorpus();
  const invalidCorpus = buildInvalidCorpus();
  const hashMismatchBase = serializeResult(
    "FUND",
    fundTerms,
    100n * 10n ** 18n,
    18,
    calculateFund(fundTerms, 100n * 10n ** 18n, 18),
  );
  const assetClassMismatchBase = serializeResult(
    "BOND",
    bondTerms,
    3n * 10n ** 8n,
    8,
    calculateBond(bondTerms, 3n * 10n ** 8n, 8),
  );

  return {
    schemaVersion: 1,
    status: "candidate",
    referenceModel: "packages/calc-reference/src/index.ts",
    valid: {
      fundUsd100: serializeResult(
        "FUND",
        fundTerms,
        100n * 10n ** 18n,
        18,
        calculateFund(fundTerms, 100n * 10n ** 18n, 18),
      ),
      stockDecimals6: serializeResult(
        "STOCK",
        stockTerms,
        25n * 10n ** 6n,
        6,
        calculateStock(stockTerms, 25n * 10n ** 6n, 6),
      ),
      bondDecimals8: serializeResult(
        "BOND",
        bondTerms,
        3n * 10n ** 8n,
        8,
        calculateBond(bondTerms, 3n * 10n ** 8n, 8),
      ),
      bondZeroAccrued: serializeResult(
        "BOND",
        {...bondTerms, accruedInterestPerUnit: 0n},
        3n * 10n ** 8n,
        8,
        calculateBond({...bondTerms, accruedInterestPerUnit: 0n}, 3n * 10n ** 8n, 8),
      ),
      fundDecimals0: serializeResult("FUND", roundingTerms, 5n, 0, calculateFund(roundingTerms, 5n, 0)),
      fundRoundsDown: serializeResult("FUND", roundingTerms, 5n, 1, calculateFund(roundingTerms, 5n, 1)),
      fundDecimals36FullPrecision: serializeResult(
        "FUND",
        {...roundingTerms, navPerUnit: 10n ** 36n},
        MAX_UINT256,
        36,
        calculateFund({...roundingTerms, navPerUnit: 10n ** 36n}, MAX_UINT256, 36),
      ),
    },
    deferredComparisons: {
      fundHashMismatch: {
        ...hashMismatchBase,
        suppliedPriceTermsHash: sourceHash("bad"),
        expected: "downstream-error",
        expectedError: "PRICE_TERMS_HASH_MISMATCH",
        enforcedBy: "DvPSettlement",
      },
      bondTermsWithStockCalculator: {
        ...assetClassMismatchBase,
        selectedCalculatorAssetClass: "STOCK",
        expected: "downstream-error",
        expectedError: "CALCULATOR_ASSET_CLASS_MISMATCH",
        enforcedBy: "PrincipalCalculatorRegistry",
      },
    },
    fuzzCorpusSize: fuzzCorpus.length,
    fuzzCorpus,
    invalidCorpusSize: invalidCorpus.length,
    invalidCorpus,
  };
}

export function writeOrCheckCalculator(targetRoot: string, write: boolean): void {
  const outputPath = resolve(targetRoot, "schema/v1/vectors/calculators/all-v1.json");
  const output = `${JSON.stringify(buildBootstrap(), null, 2)}\n`;
  if (write) {
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, output);
    console.log(`Wrote ${outputPath}`);
    return;
  }
  let current: string;
  try {
    current = readFileSync(outputPath, "utf8");
  } catch {
    throw new Error(`Calculator vectors are missing: ${outputPath}`);
  }
  if (current !== output) {
    throw new Error("Calculator vector drift detected; run npm run calculator:generate");
  }
  console.log("Calculator vectors are current");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    writeOrCheckCalculator(repositoryRoot, process.argv.includes("--write"));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
