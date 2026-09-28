/**
 * 费用计算的链下参考实现。
 *
 * 这是 contracts/src/libraries/FeeMath.sol 的可执行对照物，供报价服务在签出金额
 * 之前独立复算。链上会用同一组输入重算全部五个金额并要求精确相等，任何一处舍入
 * 或封顶顺序的分歧都会让签好的成交无法落块，因此本文件必须逐条镜像 Solidity 的
 * 判定顺序，而不是"算出同样的结果"就行。
 *
 * 与本金侧（index.ts）的一个刻意差异：本金侧抛 RangeError，这里返回状态判别联合。
 * 原因是链上 FeeMath 本身就有 tryCalculate / calculate 两条路径，preCheck 依赖前者
 * 区分九种状态并映射成不同的诊断码；用异常表达会把这层区分压平。
 */

export const BPS_DENOMINATOR = 10_000n;

/** 任意可达身份组合的有效聚合费率上限，对应 FeeMath.MAX_AGGREGATE_FEE_BPS。 */
export const MAX_AGGREGATE_FEE_BPS = 1_000n;

const MAX_UINT256 = (1n << 256n) - 1n;

/** 与 FeeMath.CalculationStatus 逐项对齐，顺序即枚举序号。 */
export const FEE_CALCULATION_STATUSES = [
  "SUCCESS",
  "INVALID_CONFIG",
  "INVALID_BUYER_PARTICIPANT_TYPE",
  "INVALID_SELLER_PARTICIPANT_TYPE",
  "INVESTOR_RATE_OUT_OF_RANGE",
  "MAKER_RATE_OUT_OF_RANGE",
  "SELLER_FEE_EXCEEDS_PRINCIPAL",
  "AGGREGATE_FEE_EXCEEDS_PRINCIPAL",
  "OVERFLOW",
  "CONSERVATION_MISMATCH",
] as const;

export type FeeCalculationStatus = (typeof FEE_CALCULATION_STATUSES)[number];

/**
 * 枚举取值与数值必须与 HTPTypes.sol 完全一致：向量要同时喂给 TS 和 Solidity，
 * 这里多造一个链上不存在的取值，Solidity 侧就构造不出对应的 struct。
 */
export const PARTICIPANT_TYPE_IDS = {NONE: 0, INVESTOR: 1, MAKER: 2} as const;
export const ROUNDING_MODE_IDS = {NONE: 0, DOWN: 1} as const;

/** ParticipantType 里只有这两个参与计费；NONE 一律拒绝而非静默按零费率处理。 */
export type FeeParticipantType = "INVESTOR" | "MAKER";

/** RoundingMode 只有 NONE 与 DOWN 两个取值，非 DOWN 走 INVALID_CONFIG。 */
export type FeeRoundingMode = keyof typeof ROUNDING_MODE_IDS;

export interface FeeConfigInput {
  investorRateBps: bigint;
  investorHasCap: boolean;
  investorCapAmount: bigint;
  makerRateBps: bigint;
  makerHasCap: boolean;
  makerCapAmount: bigint;
  roundingMode: FeeRoundingMode;
}

export interface FeeAmounts {
  buyerFee: bigint;
  sellerFee: bigint;
  buyerDebit: bigint;
  sellerCredit: bigint;
  collectorCredit: bigint;
}

export interface FeeCalculationResult extends FeeAmounts {
  status: FeeCalculationStatus;
}

/**
 * 失败时链上返回的部分金额并非全零，preCheck 会把它们一并透出用于归因，
 * 所以参考实现必须复现同样的"已算出多少"，不能一律清零。
 */
function partial(status: FeeCalculationStatus, buyerFee = 0n, sellerFee = 0n): FeeCalculationResult {
  return {status, buyerFee, sellerFee, buyerDebit: 0n, sellerCredit: 0n, collectorCredit: 0n};
}

function isFeeParticipantType(value: string): value is FeeParticipantType {
  return value === "INVESTOR" || value === "MAKER";
}

/** 费率按身份取，不按买卖角色。hasCap 时截到 capAmount（fee > cap 才截，相等不截）。 */
function feeForParticipant(
  cashPrincipal: bigint,
  participantType: FeeParticipantType,
  config: FeeConfigInput,
): bigint {
  const rateBps = participantType === "INVESTOR" ? config.investorRateBps : config.makerRateBps;
  const hasCap = participantType === "INVESTOR" ? config.investorHasCap : config.makerHasCap;
  const capAmount = participantType === "INVESTOR" ? config.investorCapAmount : config.makerCapAmount;

  // 整数除法即 Solidity 的 Math.mulDiv 向下取整。
  const fee = (cashPrincipal * rateBps) / BPS_DENOMINATOR;
  return hasCap && fee > capAmount ? capAmount : fee;
}

/**
 * 镜像 FeeMath.tryCalculate。判定顺序与链上完全一致——顺序本身是契约的一部分：
 * 同一组非法输入在两侧必须给出同一个状态，否则链下按 A 归因、链上按 B 拒绝。
 *
 * 守恒式：buyerDebit = P + buyerFee，sellerCredit = P − sellerFee，
 *         collectorCredit = buyerFee + sellerFee ⇒ debit == credit + collector。
 */
export function tryCalculateFees(
  cashPrincipal: bigint,
  buyerParticipantType: string,
  sellerParticipantType: string,
  config: FeeConfigInput,
): FeeCalculationResult {
  if (config.roundingMode !== "DOWN") return partial("INVALID_CONFIG");
  if (!isFeeParticipantType(buyerParticipantType)) return partial("INVALID_BUYER_PARTICIPANT_TYPE");
  if (!isFeeParticipantType(sellerParticipantType)) return partial("INVALID_SELLER_PARTICIPANT_TYPE");
  if (config.investorRateBps > BPS_DENOMINATOR) return partial("INVESTOR_RATE_OUT_OF_RANGE");
  if (config.makerRateBps > BPS_DENOMINATOR) return partial("MAKER_RATE_OUT_OF_RANGE");

  const buyerFee = feeForParticipant(cashPrincipal, buyerParticipantType, config);
  const sellerFee = feeForParticipant(cashPrincipal, sellerParticipantType, config);

  // 卖方净额不能下溢。
  if (sellerFee > cashPrincipal) return partial("SELLER_FEE_EXCEEDS_PRINCIPAL", buyerFee, sellerFee);

  const computedBuyerDebit = cashPrincipal + buyerFee;
  const computedCollectorCredit = buyerFee + sellerFee;
  if (computedBuyerDebit > MAX_UINT256 || computedCollectorCredit > MAX_UINT256) {
    return partial("OVERFLOW", buyerFee, sellerFee);
  }

  // 单档 100% 各自合法，聚合却能到本金的 200%：买方付 2P、卖方净收 0。此时守恒式
  // 依然成立，所以聚合上界必须单独断言，指望下面的守恒检查兜住是错的。
  if (computedCollectorCredit > cashPrincipal) {
    return partial("AGGREGATE_FEE_EXCEEDS_PRINCIPAL", buyerFee, sellerFee);
  }

  const buyerDebit = computedBuyerDebit;
  const sellerCredit = cashPrincipal - sellerFee;
  const collectorCredit = computedCollectorCredit;

  const conservedCash = sellerCredit + collectorCredit;
  if (conservedCash > MAX_UINT256) {
    return {status: "OVERFLOW", buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit};
  }
  // 算术上应恒等；任何偏差都当协议故障，不能结算。
  if (buyerDebit !== conservedCash) {
    return {
      status: "CONSERVATION_MISMATCH",
      buyerFee,
      sellerFee,
      buyerDebit,
      sellerCredit,
      collectorCredit,
    };
  }

  return {status: "SUCCESS", buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit};
}

/**
 * 镜像 FeeMath.calculate：成功返回金额，失败抛出以状态命名的错误。
 * 报价服务想要"算不出来就中止"的语义时用这个。
 */
export function calculateFees(
  cashPrincipal: bigint,
  buyerParticipantType: string,
  sellerParticipantType: string,
  config: FeeConfigInput,
): FeeAmounts {
  const result = tryCalculateFees(cashPrincipal, buyerParticipantType, sellerParticipantType, config);
  if (result.status !== "SUCCESS") throw new RangeError(result.status);
  const {buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit} = result;
  return {buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit};
}

/**
 * 登记期的聚合费率上限，对应 FeeRegistry._validateFeeTerms。
 * 与 AGGREGATE_FEE_EXCEEDS_PRINCIPAL 是两道独立防线：这一道按费率拦在登记时，
 * 那一道按金额拦在计算时，后者兜住封顶等让实际金额偏离费率的情形。
 *
 * 判的是最坏可达聚合而非两档之和。费率按身份取档，而 (MAKER, MAKER) 是可达组合，
 * 那时两腿共用 makerRateBps，聚合是 2×makerRate。所以上限落在单档上。
 */
export function aggregateFeeRateWithinRegistrableBound(
  investorRateBps: bigint,
  makerRateBps: bigint,
): boolean {
  const higherRateBps = investorRateBps > makerRateBps ? investorRateBps : makerRateBps;
  return 2n * higherRateBps <= MAX_AGGREGATE_FEE_BPS;
}
