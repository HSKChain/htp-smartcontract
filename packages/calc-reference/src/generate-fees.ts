/**
 * 费用黄金向量生成器。
 *
 * 与本金侧 generate.ts 同构：产出一份两端共同消费的 JSON，TS 侧校验参考实现没有
 * 漂移，Solidity 侧（test/fuzz/FeeMathFuzz.t.sol）逐条喂给 FeeMath 断言五个金额
 * 与状态码完全一致。链上会用同一组输入重算并要求精确相等，所以这份向量是"链下
 * 签出的金额能不能落块"的唯一自动化保障。
 *
 * 向量的期望值一律由 tryCalculateFees 现算，不手写字面量：手写值只能证明"两边
 * 都等于我写下的那个数"，证明不了两边彼此一致。
 */

import {mkdirSync, readFileSync, writeFileSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {keccak256, stringToHex, type Hex} from "viem";

import {
  BPS_DENOMINATOR,
  MAX_AGGREGATE_FEE_BPS,
  PARTICIPANT_TYPE_IDS,
  ROUNDING_MODE_IDS,
  tryCalculateFees,
  type FeeCalculationStatus,
  type FeeConfigInput,
  type FeeParticipantType,
} from "./fees.js";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

const MAX_UINT256 = (1n << 256n) - 1n;

function errorSelector(signature: string): Hex {
  return keccak256(stringToHex(signature)).slice(0, 10) as Hex;
}

/**
 * 每个非 SUCCESS 状态对应的链上 revert。FeeMath.calculate 把状态映射成这些错误，
 * 映射关系本身是链下归因的依据，因此进向量而不是留在注释里。
 * CONSERVATION_MISMATCH 是兜底分支：算术上不可达，但保留映射以防实现漂移。
 */
const STATUS_TO_SELECTOR: Record<Exclude<FeeCalculationStatus, "SUCCESS">, Hex> = {
  INVALID_CONFIG: errorSelector("InvalidFeeConfig()"),
  INVALID_BUYER_PARTICIPANT_TYPE: errorSelector("InvalidFeeParticipantType(uint8)"),
  INVALID_SELLER_PARTICIPANT_TYPE: errorSelector("InvalidFeeParticipantType(uint8)"),
  INVESTOR_RATE_OUT_OF_RANGE: errorSelector("FeeRateOutOfRange(uint8,uint16)"),
  MAKER_RATE_OUT_OF_RANGE: errorSelector("FeeRateOutOfRange(uint8,uint16)"),
  SELLER_FEE_EXCEEDS_PRINCIPAL: errorSelector("SellerFeeExceedsPrincipal(uint256,uint256)"),
  AGGREGATE_FEE_EXCEEDS_PRINCIPAL: errorSelector("AggregateFeeExceedsPrincipal(uint256,uint256,uint256)"),
  OVERFLOW: errorSelector("FeeOverflow()"),
  CONSERVATION_MISMATCH: errorSelector("CashConservationMismatch()"),
};

interface VectorInput {
  cashPrincipal: bigint;
  buyerParticipantType: string;
  sellerParticipantType: string;
  config: FeeConfigInput;
}

function participantTypeId(name: string): number {
  const id = (PARTICIPANT_TYPE_IDS as Record<string, number | undefined>)[name];
  if (id === undefined) throw new Error(`unknown ParticipantType in vector input: ${name}`);
  return id;
}

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

function serialize(name: string, input: VectorInput) {
  const result = tryCalculateFees(
    input.cashPrincipal,
    input.buyerParticipantType,
    input.sellerParticipantType,
    input.config,
  );
  // 直接比较而不是复用布尔量：TS 只能从前者收窄出「不是 SUCCESS」，
  // 索引 STATUS_TO_SELECTOR 需要这层收窄。
  const expectedErrorSelector = result.status === "SUCCESS" ? null : STATUS_TO_SELECTOR[result.status];
  return {
    name,
    input: {
      cashPrincipal: input.cashPrincipal.toString(),
      // 同时给出名字与枚举数值：名字给人读，数值给 Solidity 侧直接构造 struct。
      buyerParticipantType: input.buyerParticipantType,
      buyerParticipantTypeId: participantTypeId(input.buyerParticipantType),
      sellerParticipantType: input.sellerParticipantType,
      sellerParticipantTypeId: participantTypeId(input.sellerParticipantType),
      investorRateBps: Number(input.config.investorRateBps),
      investorHasCap: input.config.investorHasCap,
      investorCapAmount: input.config.investorCapAmount.toString(),
      makerRateBps: Number(input.config.makerRateBps),
      makerHasCap: input.config.makerHasCap,
      makerCapAmount: input.config.makerCapAmount.toString(),
      roundingMode: input.config.roundingMode,
      roundingModeId: ROUNDING_MODE_IDS[input.config.roundingMode],
    },
    expected: expectedErrorSelector === null ? "success" : "error",
    status: result.status,
    expectedErrorSelector,
    output: {
      buyerFee: result.buyerFee.toString(),
      sellerFee: result.sellerFee.toString(),
      buyerDebit: result.buyerDebit.toString(),
      sellerCredit: result.sellerCredit.toString(),
      collectorCredit: result.collectorCredit.toString(),
    },
  };
}

/**
 * 命名 bootstrap 向量：每条对应一个人能讲清楚的业务场景，出问题时便于定位。
 * 与 fuzz 语料的分工是——这里保可读性，那里保覆盖面。
 */
function buildValidVectors() {
  return {
    // 历史基线：与既有 resolution-and-amounts.json 的 amount 向量同参数，
    // 保证换用新流水线后数值没有变动。
    investorBuysFromMakerWithBuyerCap: serialize("investorBuysFromMakerWithBuyerCap", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorHasCap: true, investorCapAmount: 2_000n}),
    }),
    // 两侧同为 INVESTOR：费率按身份取而非按买卖方向，两腿应当同额。
    investorOnBothLegsPaysSymmetricFees: serialize("investorOnBothLegsPaysSymmetricFees", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "INVESTOR",
      config: config(),
    }),
    // 零费率：collector 不应收到任何款项，守恒式退化成 debit == credit。
    zeroRatesLeaveTheCollectorEmpty: serialize("zeroRatesLeaveTheCollectorEmpty", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorRateBps: 0n, makerRateBps: 0n}),
    }),
    // 向下取整：1 wei 本金配 25 bps，两腿都应落到 0 而不是 1。
    subUnitFeesRoundDownToZero: serialize("subUnitFeesRoundDownToZero", {
      cashPrincipal: 1n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config(),
    }),
    // 封顶恰好等于未封顶费额：相等不截断，用于钉住边界方向。
    capEqualToUncappedFeeDoesNotTruncate: serialize("capEqualToUncappedFeeDoesNotTruncate", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorHasCap: true, investorCapAmount: 2_500n}),
    }),
    // 封顶为零：有 cap 且为 0 表示免费，不等于"没有 cap"。
    zeroCapMeansNoFee: serialize("zeroCapMeansNoFee", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorHasCap: true, investorCapAmount: 0n}),
    }),
    // 单档取满可登记上限（MAX/2）时，最坏可达组合 (MAKER, MAKER) 的聚合恰好等于
    // MAX_AGGREGATE_FEE_BPS 而不越过。钉住的正是这条包含边界。
    aggregateExactlyAtRegistrableBound: serialize("aggregateExactlyAtRegistrableBound", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "MAKER",
      sellerParticipantType: "MAKER",
      config: config({
        investorRateBps: MAX_AGGREGATE_FEE_BPS / 2n,
        makerRateBps: MAX_AGGREGATE_FEE_BPS / 2n,
      }),
    }),
    // 卖方费率 100%：sellerCredit 归零但不下溢，仍是合法计算（登记期另有费率上限拦截）。
    sellerFeeEqualToPrincipalZeroesTheCredit: serialize("sellerFeeEqualToPrincipalZeroesTheCredit", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorRateBps: 0n, makerRateBps: BPS_DENOMINATOR}),
    }),
  };
}

/**
 * fuzz 语料：本金量级 × 费率 × 封顶形态 × 参与方组合的笛卡尔积。
 * 本金量级特意覆盖不能整除 10000 的值，逼出取整余数。
 */
function buildFuzzCorpus() {
  const principals = [
    1n,
    7n,
    9_999n,
    10_000n,
    10_001n,
    1_000_000n,
    123_456_789n,
    10n ** 18n,
    10n ** 18n + 1n,
    (1n << 128n) - 1n,
  ];
  const rates: Array<[bigint, bigint]> = [
    [0n, 0n],
    [1n, 0n],
    [25n, 15n],
    [333n, 667n],
    [MAX_AGGREGATE_FEE_BPS, 0n],
    [0n, MAX_AGGREGATE_FEE_BPS],
  ];
  const participantPairs: Array<[FeeParticipantType, FeeParticipantType]> = [
    ["INVESTOR", "MAKER"],
    ["MAKER", "INVESTOR"],
    ["INVESTOR", "INVESTOR"],
    ["MAKER", "MAKER"],
  ];

  const vectors: ReturnType<typeof serialize>[] = [];
  let index = 0;
  for (const cashPrincipal of principals) {
    for (const [investorRateBps, makerRateBps] of rates) {
      for (const [buyer, seller] of participantPairs) {
        // 三种封顶形态轮转：不封顶、封在半额（必然截断）、封在极大值（必然不截断）。
        const capMode = index % 3;
        const uncapped = (cashPrincipal * investorRateBps) / BPS_DENOMINATOR;
        const overrides: Partial<FeeConfigInput> =
          capMode === 0
            ? {}
            : capMode === 1
              ? {investorHasCap: true, investorCapAmount: uncapped / 2n}
              : {investorHasCap: true, investorCapAmount: MAX_UINT256};

        vectors.push(
          serialize(`fuzz-${index}`, {
            cashPrincipal,
            buyerParticipantType: buyer,
            sellerParticipantType: seller,
            config: config({investorRateBps, makerRateBps, ...overrides}),
          }),
        );
        index += 1;
      }
    }
  }
  return vectors;
}

/**
 * 失败语料：覆盖全部可达的非 SUCCESS 状态。
 * 九个状态里有两个在当前算术下构造不出输入（见 statusCoverage.unreachable），
 * 它们是防御性分支而非遗漏，显式声明以免读者去找不存在的向量。
 */
function buildInvalidCorpus() {
  return [
    // RoundingMode 只有 NONE 与 DOWN；NONE 是未配置的默认值，必须拒而非当成 DOWN。
    serialize("roundingModeNoneIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({roundingMode: "NONE"}),
    }),
    serialize("unknownBuyerParticipantTypeIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "NONE",
      sellerParticipantType: "MAKER",
      config: config(),
    }),
    serialize("unknownSellerParticipantTypeIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "NONE",
      config: config(),
    }),
    serialize("investorRateAboveOneHundredPercentIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorRateBps: BPS_DENOMINATOR + 1n}),
    }),
    serialize("makerRateAboveOneHundredPercentIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({makerRateBps: BPS_DENOMINATOR + 1n}),
    }),
    // 两腿各 100%：聚合达本金 200%，买方付 2P、卖方净收 0，而守恒式依然成立。
    // 这正是 M-12 的场景，必须被独立的聚合上界拦下。
    serialize("aggregateFeeAtTwoHundredPercentIsRejected", {
      cashPrincipal: 1_000_000n,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({investorRateBps: BPS_DENOMINATOR, makerRateBps: BPS_DENOMINATOR}),
    }),
    // 本金取 uint256 上界，P + buyerFee 溢出。
    serialize("buyerDebitOverflowIsRejected", {
      cashPrincipal: MAX_UINT256,
      buyerParticipantType: "INVESTOR",
      sellerParticipantType: "MAKER",
      config: config({
        investorRateBps: 1n,
        investorHasCap: true,
        investorCapAmount: MAX_UINT256,
        makerRateBps: 0n,
      }),
    }),
  ];
}

export function buildFeeBootstrap() {
  const valid = buildValidVectors();
  const fuzzCorpus = buildFuzzCorpus();
  const invalidCorpus = buildInvalidCorpus();

  const covered = new Set<string>([
    ...Object.values(valid).map((vector) => vector.status),
    ...fuzzCorpus.map((vector) => vector.status),
    ...invalidCorpus.map((vector) => vector.status),
  ]);

  return {
    schemaVersion: 1,
    status: "candidate",
    referenceModel: "packages/calc-reference/src/fees.ts",
    onChainModel: "contracts/src/libraries/FeeMath.sol",
    constants: {
      bpsDenominator: BPS_DENOMINATOR.toString(),
      maxAggregateFeeBps: MAX_AGGREGATE_FEE_BPS.toString(),
    },
    // 显式声明哪些状态被覆盖、哪些不可达，读者不必自己数，也不会去找不存在的向量。
    statusCoverage: {
      covered: [...covered].sort(),
      unreachable: {
        SELLER_FEE_EXCEEDS_PRINCIPAL:
          "fee = min(P * rate / 10000, cap) and rate <= 10000 is enforced by the preceding " +
          "range check, so fee <= P always holds and a cap can only lower it further. The " +
          "branch becomes reachable only if the rate ceiling is ever relaxed above 100%.",
        CONSERVATION_MISMATCH:
          "buyerDebit == sellerCredit + collectorCredit is an algebraic identity under the " +
          "current formulas; the branch exists to catch implementation drift, not reachable input.",
      },
    },
    valid,
    fuzzCorpusSize: fuzzCorpus.length,
    fuzzCorpus,
    invalidCorpusSize: invalidCorpus.length,
    invalidCorpus,
  };
}

export function writeOrCheckFeeCalculator(targetRoot: string, write: boolean): void {
  const outputPath = resolve(targetRoot, "schema/v1/vectors/fees/amounts-v1.json");
  const output = `${JSON.stringify(buildFeeBootstrap(), null, 2)}\n`;
  if (write) {
    mkdirSync(dirname(outputPath), {recursive: true});
    writeFileSync(outputPath, output);
    console.log(`Wrote ${outputPath}`);
    return;
  }
  let current: string;
  try {
    current = readFileSync(outputPath, "utf8");
  } catch {
    throw new Error(`Fee vectors are missing: ${outputPath}`);
  }
  if (current !== output) {
    throw new Error("Fee vector drift detected; run npm run fee:generate");
  }
  console.log("Fee vectors are current");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    writeOrCheckFeeCalculator(repositoryRoot, process.argv.includes("--write"));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
