import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import test from "node:test";

import {
  BPS_DENOMINATOR,
  FEE_CALCULATION_STATUSES,
  MAX_AGGREGATE_FEE_BPS,
  aggregateFeeRateWithinRegistrableBound,
  calculateFees,
  tryCalculateFees,
  type FeeConfigInput,
} from "../src/fees.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const vectorsPath = resolve(repositoryRoot, "schema/v1/vectors/fees/amounts-v1.json");

function config(overrides: Partial<FeeConfigInput> = {}): FeeConfigInput {
  return {
    investorRateBps: 25n,
    investorHasCap: false,
    investorCapAmount: 0n,
    makerRateBps: 15n,
    makerHasCap: false,
    makerCapAmount: 0n,
    roundingMode: "DOWN",
    ...overrides,
  };
}

// 与链上 FeeMath.t.sol 使用同一组数值：两侧都从这组人可读的数字出发，
// 任何一侧改了实现都会在这里先撞上。
test("reference fees match the reviewed 1e6 principal baseline", () => {
  const result = tryCalculateFees(1_000_000n, "INVESTOR", "MAKER", config({
    investorHasCap: true,
    investorCapAmount: 2_000n,
  }));

  assert.equal(result.status, "SUCCESS");
  assert.equal(result.buyerFee, 2_000n); // 未封顶为 2500，被 cap 截到 2000
  assert.equal(result.sellerFee, 1_500n);
  assert.equal(result.buyerDebit, 1_002_000n);
  assert.equal(result.sellerCredit, 998_500n);
  assert.equal(result.collectorCredit, 3_500n);
});

test("fees are taken by participant type, not by trade direction", () => {
  const buyerIsInvestor = tryCalculateFees(1_000_000n, "INVESTOR", "MAKER", config());
  const buyerIsMaker = tryCalculateFees(1_000_000n, "MAKER", "INVESTOR", config());

  // 买卖方向对调，两腿费额应当跟着身份走而不是跟着方向走。
  assert.equal(buyerIsInvestor.buyerFee, buyerIsMaker.sellerFee);
  assert.equal(buyerIsInvestor.sellerFee, buyerIsMaker.buyerFee);
});

test("a cap equal to the uncapped fee does not truncate", () => {
  const atCap = tryCalculateFees(1_000_000n, "INVESTOR", "MAKER", config({
    investorHasCap: true,
    investorCapAmount: 2_500n,
  }));
  const belowCap = tryCalculateFees(1_000_000n, "INVESTOR", "MAKER", config({
    investorHasCap: true,
    investorCapAmount: 2_499n,
  }));

  assert.equal(atCap.buyerFee, 2_500n);
  assert.equal(belowCap.buyerFee, 2_499n);
});

test("the aggregate bound rejects two legs that would each be individually legal", () => {
  // 这是 M-12：单档 100% 各自通过费率范围检查，聚合却达到本金的 200%，
  // 买方付 2P、卖方净收 0，而守恒式 debit == credit + collector 依然成立。
  const result = tryCalculateFees(1_000_000n, "INVESTOR", "MAKER", config({
    investorRateBps: BPS_DENOMINATOR,
    makerRateBps: BPS_DENOMINATOR,
  }));

  assert.equal(result.status, "AGGREGATE_FEE_EXCEEDS_PRINCIPAL");
  assert.equal(result.buyerDebit, 0n, "failed calculations must not report settleable amounts");
});

test("registrable aggregate rate bound is inclusive at MAX_AGGREGATE_FEE_BPS", () => {
  const half = MAX_AGGREGATE_FEE_BPS / 2n;
  assert.equal(aggregateFeeRateWithinRegistrableBound(half, half), true);
  assert.equal(aggregateFeeRateWithinRegistrableBound(half + 1n, half), false);
  // 两档之和恰好等于上限却仍被拒：(MAKER, MAKER) 成交时 maker 档会被用两次，
  // 有效聚合是 2×MAX_AGGREGATE_FEE_BPS。
  assert.equal(aggregateFeeRateWithinRegistrableBound(0n, MAX_AGGREGATE_FEE_BPS), false);
});

test("calculateFees throws the status name so callers can branch on it", () => {
  assert.throws(
    () => calculateFees(1_000_000n, "INVESTOR", "MAKER", config({roundingMode: "NONE"})),
    /INVALID_CONFIG/u,
  );
});

test("generated fee vectors round-trip through the reference implementation", () => {
  const vectors = JSON.parse(readFileSync(vectorsPath, "utf8"));

  assert.equal(vectors.schemaVersion, 1);
  assert.equal(vectors.referenceModel, "packages/calc-reference/src/fees.ts");
  assert.equal(vectors.onChainModel, "contracts/src/libraries/FeeMath.sol");

  const all = [
    ...Object.values(vectors.valid as Record<string, unknown>),
    ...(vectors.fuzzCorpus as unknown[]),
    ...(vectors.invalidCorpus as unknown[]),
  ] as Array<{
    name: string;
    input: Record<string, string | number | boolean>;
    status: string;
    expected: string;
    output: Record<string, string>;
  }>;

  assert.equal(vectors.fuzzCorpusSize, (vectors.fuzzCorpus as unknown[]).length);
  assert.equal(vectors.invalidCorpusSize, (vectors.invalidCorpus as unknown[]).length);
  assert.ok(all.length > 200, "fee corpus should be comparable in size to the principal side");

  for (const vector of all) {
    const result = tryCalculateFees(
      BigInt(vector.input.cashPrincipal as string),
      vector.input.buyerParticipantType as string,
      vector.input.sellerParticipantType as string,
      {
        investorRateBps: BigInt(vector.input.investorRateBps as number),
        investorHasCap: vector.input.investorHasCap as boolean,
        investorCapAmount: BigInt(vector.input.investorCapAmount as string),
        makerRateBps: BigInt(vector.input.makerRateBps as number),
        makerHasCap: vector.input.makerHasCap as boolean,
        makerCapAmount: BigInt(vector.input.makerCapAmount as string),
        roundingMode: vector.input.roundingMode as FeeConfigInput["roundingMode"],
      },
    );

    assert.equal(result.status, vector.status, `${vector.name}: status`);
    assert.equal(
      vector.expected,
      result.status === "SUCCESS" ? "success" : "error",
      `${vector.name}: expected flag disagrees with status`,
    );
    assert.equal(result.buyerFee.toString(), vector.output.buyerFee, `${vector.name}: buyerFee`);
    assert.equal(result.sellerFee.toString(), vector.output.sellerFee, `${vector.name}: sellerFee`);
    assert.equal(result.buyerDebit.toString(), vector.output.buyerDebit, `${vector.name}: buyerDebit`);
    assert.equal(result.sellerCredit.toString(), vector.output.sellerCredit, `${vector.name}: sellerCredit`);
    assert.equal(
      result.collectorCredit.toString(),
      vector.output.collectorCredit,
      `${vector.name}: collectorCredit`,
    );

    // 成功向量必须守恒；失败向量不得报出可结算金额。
    if (result.status === "SUCCESS") {
      assert.equal(result.buyerDebit, result.sellerCredit + result.collectorCredit, `${vector.name}: conservation`);
    }
  }
});

test("every FeeMath status is either exercised by a vector or declared unreachable with a reason", () => {
  const vectors = JSON.parse(readFileSync(vectorsPath, "utf8"));
  const covered = new Set<string>(vectors.statusCoverage.covered);
  const unreachable = vectors.statusCoverage.unreachable as Record<string, string>;

  for (const status of FEE_CALCULATION_STATUSES) {
    const accounted = covered.has(status) || status in unreachable;
    assert.ok(accounted, `${status} is neither covered by a vector nor declared unreachable`);
  }

  // 「不可达」必须附理由：没有理由的声明等于把缺口藏起来。
  for (const [status, reason] of Object.entries(unreachable)) {
    assert.ok(reason.length > 40, `${status}: unreachable claim needs a substantive justification`);
    assert.ok(!covered.has(status), `${status} is declared unreachable but a vector reaches it`);
  }
});
