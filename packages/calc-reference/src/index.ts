import {
  encodeAbiParameters,
  keccak256,
  stringToHex,
  type Hex,
} from "viem";

// 费用侧的参考实现。本金决定 cashPrincipal，费用在其之上决定实际收付的五个金额，
// 两者共用同一个入口以便报价服务一次导入。
export {
  BPS_DENOMINATOR,
  FEE_CALCULATION_STATUSES,
  MAX_AGGREGATE_FEE_BPS,
  aggregateFeeRateWithinRegistrableBound,
  calculateFees,
  tryCalculateFees,
  type FeeAmounts,
  type FeeCalculationResult,
  type FeeCalculationStatus,
  type FeeConfigInput,
  type FeeParticipantType,
  type FeeRoundingMode,
} from "./fees.js";

export const MAX_UINT256 = (1n << 256n) - 1n;
const MAX_UINT64 = (1n << 64n) - 1n;
const ZERO_HASH = `0x${"00".repeat(32)}` as Hex;

export const STOCK_PRICE_TERMS_TYPE =
  "StockPriceTerms(uint256 unitPrice,uint64 priceAsOf,bytes32 referenceMarketHash,bytes32 priceSourceHash)";
export const FUND_PRICE_TERMS_TYPE =
  "FundPriceTerms(uint256 navPerUnit,uint32 navDate,bytes32 navSourceHash)";
export const BOND_PRICE_TERMS_TYPE =
  "BondPriceTerms(uint256 cleanPricePerUnit,uint256 accruedInterestPerUnit,uint32 settlementDate,bytes32 sourceHash)";

export const STOCK_PRICE_TERMS_TYPEHASH = keccak256(stringToHex(STOCK_PRICE_TERMS_TYPE));
export const FUND_PRICE_TERMS_TYPEHASH = keccak256(stringToHex(FUND_PRICE_TERMS_TYPE));
export const BOND_PRICE_TERMS_TYPEHASH = keccak256(stringToHex(BOND_PRICE_TERMS_TYPE));

export interface StockPriceTerms {
  unitPrice: bigint;
  priceAsOf: bigint;
  referenceMarketHash: Hex;
  priceSourceHash: Hex;
}

export interface FundPriceTerms {
  navPerUnit: bigint;
  navDate: number;
  navSourceHash: Hex;
}

export interface BondPriceTerms {
  cleanPricePerUnit: bigint;
  accruedInterestPerUnit: bigint;
  settlementDate: number;
  sourceHash: Hex;
}

export interface CalculationResult {
  priceData: Hex;
  priceTermsHash: Hex;
  quotedPrice: bigint;
  unitCashPrice: bigint;
  cashPrincipal: bigint;
}

function assertUint256(value: bigint, field: string): void {
  if (value < 0n || value > MAX_UINT256) {
    throw new RangeError(`${field}: UINT256_OUT_OF_RANGE`);
  }
}

function assertRequiredUint(value: bigint, field: string): void {
  assertUint256(value, field);
  if (value === 0n) {
    throw new RangeError(`${field}: REQUIRED_PRICE_FIELD_MISSING`);
  }
}

function assertRequiredHash(value: Hex, field: string): void {
  if (value === ZERO_HASH) {
    throw new RangeError(`${field}: REQUIRED_PRICE_FIELD_MISSING`);
  }
}

export function requireValidCalendarDate(date: number): void {
  if (!Number.isSafeInteger(date)) {
    throw new RangeError("INVALID_CALENDAR_DATE");
  }

  const year = Math.trunc(date / 10_000);
  const month = Math.trunc(date / 100) % 100;
  const day = date % 100;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [0, 31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  if (
    year < 1 ||
    year > 9999 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth[month]!
  ) {
    throw new RangeError("INVALID_CALENDAR_DATE");
  }
}

export function calculateCashPrincipal(
  executedQuantity: bigint,
  unitCashPrice: bigint,
  assetDecimals: number,
): bigint {
  assertUint256(executedQuantity, "executedQuantity");
  assertUint256(unitCashPrice, "unitCashPrice");
  if (!Number.isInteger(assetDecimals) || assetDecimals < 0 || assetDecimals > 36) {
    throw new RangeError("ASSET_DECIMALS_OUT_OF_RANGE");
  }

  const result = (executedQuantity * unitCashPrice) / 10n ** BigInt(assetDecimals);
  if (result > MAX_UINT256) {
    throw new RangeError("CASH_PRINCIPAL_OVERFLOW");
  }
  if (result === 0n) {
    throw new RangeError("CASH_PRINCIPAL_ZERO");
  }
  return result;
}

export function encodeStockPriceTerms(terms: StockPriceTerms): Hex {
  return encodeAbiParameters(
    [
      {type: "uint256", name: "unitPrice"},
      {type: "uint64", name: "priceAsOf"},
      {type: "bytes32", name: "referenceMarketHash"},
      {type: "bytes32", name: "priceSourceHash"},
    ],
    [terms.unitPrice, terms.priceAsOf, terms.referenceMarketHash, terms.priceSourceHash],
  );
}

export function encodeFundPriceTerms(terms: FundPriceTerms): Hex {
  return encodeAbiParameters(
    [
      {type: "uint256", name: "navPerUnit"},
      {type: "uint32", name: "navDate"},
      {type: "bytes32", name: "navSourceHash"},
    ],
    [terms.navPerUnit, terms.navDate, terms.navSourceHash],
  );
}

export function encodeBondPriceTerms(terms: BondPriceTerms): Hex {
  return encodeAbiParameters(
    [
      {type: "uint256", name: "cleanPricePerUnit"},
      {type: "uint256", name: "accruedInterestPerUnit"},
      {type: "uint32", name: "settlementDate"},
      {type: "bytes32", name: "sourceHash"},
    ],
    [terms.cleanPricePerUnit, terms.accruedInterestPerUnit, terms.settlementDate, terms.sourceHash],
  );
}

export function hashStockPriceTerms(terms: StockPriceTerms): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        {type: "bytes32"},
        {type: "uint256"},
        {type: "uint64"},
        {type: "bytes32"},
        {type: "bytes32"},
      ],
      [
        STOCK_PRICE_TERMS_TYPEHASH,
        terms.unitPrice,
        terms.priceAsOf,
        terms.referenceMarketHash,
        terms.priceSourceHash,
      ],
    ),
  );
}

export function hashFundPriceTerms(terms: FundPriceTerms): Hex {
  return keccak256(
    encodeAbiParameters(
      [{type: "bytes32"}, {type: "uint256"}, {type: "uint32"}, {type: "bytes32"}],
      [FUND_PRICE_TERMS_TYPEHASH, terms.navPerUnit, terms.navDate, terms.navSourceHash],
    ),
  );
}

export function hashBondPriceTerms(terms: BondPriceTerms): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        {type: "bytes32"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint32"},
        {type: "bytes32"},
      ],
      [
        BOND_PRICE_TERMS_TYPEHASH,
        terms.cleanPricePerUnit,
        terms.accruedInterestPerUnit,
        terms.settlementDate,
        terms.sourceHash,
      ],
    ),
  );
}

export function calculateStock(
  terms: StockPriceTerms,
  executedQuantity: bigint,
  assetDecimals: number,
): CalculationResult {
  assertRequiredUint(terms.unitPrice, "unitPrice");
  if (terms.priceAsOf <= 0n || terms.priceAsOf > MAX_UINT64) {
    throw new RangeError("priceAsOf: REQUIRED_PRICE_FIELD_MISSING");
  }
  assertRequiredHash(terms.referenceMarketHash, "referenceMarketHash");
  assertRequiredHash(terms.priceSourceHash, "priceSourceHash");

  return {
    priceData: encodeStockPriceTerms(terms),
    priceTermsHash: hashStockPriceTerms(terms),
    quotedPrice: terms.unitPrice,
    unitCashPrice: terms.unitPrice,
    cashPrincipal: calculateCashPrincipal(executedQuantity, terms.unitPrice, assetDecimals),
  };
}

export function calculateFund(
  terms: FundPriceTerms,
  executedQuantity: bigint,
  assetDecimals: number,
): CalculationResult {
  assertRequiredUint(terms.navPerUnit, "navPerUnit");
  requireValidCalendarDate(terms.navDate);
  assertRequiredHash(terms.navSourceHash, "navSourceHash");

  return {
    priceData: encodeFundPriceTerms(terms),
    priceTermsHash: hashFundPriceTerms(terms),
    quotedPrice: terms.navPerUnit,
    unitCashPrice: terms.navPerUnit,
    cashPrincipal: calculateCashPrincipal(executedQuantity, terms.navPerUnit, assetDecimals),
  };
}

export function calculateBond(
  terms: BondPriceTerms,
  executedQuantity: bigint,
  assetDecimals: number,
): CalculationResult {
  assertRequiredUint(terms.cleanPricePerUnit, "cleanPricePerUnit");
  assertUint256(terms.accruedInterestPerUnit, "accruedInterestPerUnit");
  requireValidCalendarDate(terms.settlementDate);
  assertRequiredHash(terms.sourceHash, "sourceHash");

  const unitCashPrice = terms.cleanPricePerUnit + terms.accruedInterestPerUnit;
  if (unitCashPrice > MAX_UINT256) {
    throw new RangeError("BOND_FULL_PRICE_OVERFLOW");
  }

  return {
    priceData: encodeBondPriceTerms(terms),
    priceTermsHash: hashBondPriceTerms(terms),
    quotedPrice: terms.cleanPricePerUnit,
    unitCashPrice,
    cashPrincipal: calculateCashPrincipal(executedQuantity, unitCashPrice, assetDecimals),
  };
}
