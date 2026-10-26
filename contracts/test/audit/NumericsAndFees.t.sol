// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT (Module D). Not part of the production suite.

import {Test} from "forge-std/Test.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {CalendarDate} from "src/libraries/CalendarDate.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {PrincipalMath} from "src/libraries/PrincipalMath.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FundPriceTerms,
    ParticipantType,
    ReasonCode,
    RoundingMode,
    ScopeType,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract TmpAuditFeeHarness {
    function tryCalculate(
        uint256 cashPrincipal,
        ParticipantType buyerType,
        ParticipantType sellerType,
        FeeConfig calldata config
    )
        external
        pure
        returns (
            FeeMath.CalculationStatus status,
            uint256 buyerFee,
            uint256 sellerFee,
            uint256 buyerDebit,
            uint256 sellerCredit,
            uint256 collectorCredit
        )
    {
        return FeeMath.tryCalculate(cashPrincipal, buyerType, sellerType, config);
    }

    function principal(uint256 quantity, uint256 unitCashPrice, uint8 assetDecimals) external pure returns (uint256) {
        return PrincipalMath.calculate(quantity, unitCashPrice, assetDecimals);
    }

    function calendarValid(uint32 date) external pure returns (bool) {
        return CalendarDate.isValid(date);
    }

    function scopeHash(uint64 epoch, ScopeType scopeType, bytes32 key) external pure returns (bytes32) {
        return FeeScope.matchedHashWithoutValidation(epoch, scopeType, key);
    }
}

contract TmpAuditModuleDMathTest is Test {
    TmpAuditFeeHarness internal harness = new TmpAuditFeeHarness();
    IPrincipalCalculator internal fund = IPrincipalCalculator(address(new FundPrincipalCalculator()));
    IPrincipalCalculator internal stock = IPrincipalCalculator(address(new StockPrincipalCalculator()));
    IPrincipalCalculator internal bond = IPrincipalCalculator(address(new BondPrincipalCalculator()));

    // ---------------------------------------------------------------
    // D-A. Cash conservation across every participant pair reachable
    //      from settle(): (INVESTOR,MAKER) (MAKER,INVESTOR) (MAKER,MAKER).
    // ---------------------------------------------------------------
    struct FeeOutcome {
        FeeMath.CalculationStatus status;
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 buyerDebit;
        uint256 sellerCredit;
        uint256 collectorCredit;
    }

    function testFuzzConservationHoldsForEveryReachableParticipantPair(
        uint256 cashPrincipal,
        uint32 rateSeed,
        uint256 capSeed,
        uint8 flagSeed
    ) public view {
        cashPrincipal = bound(cashPrincipal, 0, type(uint256).max / 4);
        FeeConfig memory config;
        config.roundingMode = RoundingMode.DOWN;
        // 聚合费用高于本金现在会被拒，守恒性只在可达空间上验证；被拒的那条路径由
        // testAggregateFeeAbovePrincipalIsNowRejected 覆盖。两档各自 ≤ 50% 而不是
        // 「之和 ≤ 100%」，因为可达的身份组合包含 (MAKER, MAKER)，那时两腿共用
        // makerRateBps，聚合是 2 × makerRate 而不是两档相加。
        config.investorRateBps = uint16(bound(uint256(rateSeed) & 0xffff, 0, 5_000));
        config.makerRateBps = uint16(bound(uint256(rateSeed) >> 16, 0, 5_000));
        config.investorHasCap = (flagSeed & 0x08) != 0;
        config.investorCapAmount = config.investorHasCap ? capSeed : 0;
        config.makerHasCap = (flagSeed & 0x10) != 0;
        config.makerCapAmount = config.makerHasCap ? (capSeed / 3) : 0;

        (ParticipantType buyerType, ParticipantType sellerType) = _reachablePair(flagSeed);
        FeeOutcome memory outcome = _run(cashPrincipal, buyerType, sellerType, config);

        // With rate <= 10000 bps and principal <= max/4 no overflow branch can trigger.
        assertEq(uint8(outcome.status), uint8(FeeMath.CalculationStatus.SUCCESS), "status");

        // Manual derivation, recomputed here from first principles.
        uint256 expectedBuyerFee = _expectedFee(cashPrincipal, buyerType, config);
        uint256 expectedSellerFee = _expectedFee(cashPrincipal, sellerType, config);
        assertEq(outcome.buyerFee, expectedBuyerFee, "buyerFee");
        assertEq(outcome.sellerFee, expectedSellerFee, "sellerFee");
        assertEq(outcome.buyerDebit, cashPrincipal + expectedBuyerFee, "buyerDebit");
        assertEq(outcome.sellerCredit, cashPrincipal - expectedSellerFee, "sellerCredit");
        assertEq(outcome.collectorCredit, expectedBuyerFee + expectedSellerFee, "collectorCredit");
        // The identity settle() relies on.
        assertEq(outcome.buyerDebit, outcome.sellerCredit + outcome.collectorCredit, "conservation");
        // Seller net can be zero but never underflows.
        assertLe(outcome.sellerFee, cashPrincipal, "sellerFee<=P");
    }

    function _run(uint256 cashPrincipal, ParticipantType buyerType, ParticipantType sellerType, FeeConfig memory config)
        private
        view
        returns (FeeOutcome memory outcome)
    {
        (
            outcome.status,
            outcome.buyerFee,
            outcome.sellerFee,
            outcome.buyerDebit,
            outcome.sellerCredit,
            outcome.collectorCredit
        ) = harness.tryCalculate(cashPrincipal, buyerType, sellerType, config);
    }

    // ---------------------------------------------------------------
    // D-B（已修复）。两档各 100% 曾让 collectorCredit 达到本金的两倍、
    //      卖方交割资产却零收款，而 FeeMath 返回 SUCCESS——守恒式对此成立，
    //      CONSERVATION_MISMATCH 与 SELLER_FEE_EXCEEDS 都抓不住。
    //      现由独立的聚合断言拦下。
    // ---------------------------------------------------------------
    function testAggregateFeeAtTwoHundredPercentIsNowRejected() public view {
        FeeConfig memory config;
        config.roundingMode = RoundingMode.DOWN;
        config.investorRateBps = 10_000;
        config.makerRateBps = 10_000;

        uint256 principal = 1_000_000;
        (FeeMath.CalculationStatus status,,, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            harness.tryCalculate(principal, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.AGGREGATE_FEE_EXCEEDS_PRINCIPAL));
        // 失败路径不得回填任何金额，避免调用方误用。
        assertEq(buyerDebit, 0);
        assertEq(sellerCredit, 0);
        assertEq(collectorCredit, 0);
    }

    // 卖方单腿的护栏拦不住聚合超限，因此聚合上界必须单独断言。
    function testFuzzAggregateFeeAbovePrincipalIsNowRejected(uint16 rateSeed) public view {
        uint16 rate = uint16(bound(rateSeed, 5_001, 10_000));
        FeeConfig memory config;
        config.roundingMode = RoundingMode.DOWN;
        config.investorRateBps = rate;
        config.makerRateBps = rate;
        uint256 principal = 1e12;

        (FeeMath.CalculationStatus status,,,,,) =
            harness.tryCalculate(principal, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        // 2 × rate > 100% 且本金足够大，聚合必然越过本金。
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.AGGREGATE_FEE_EXCEEDS_PRINCIPAL));
    }

    // ---------------------------------------------------------------
    // D-C. Rounding direction: cashPrincipal is a strict floor, so the
    //      truncated remainder is always taken from the seller's side.
    // ---------------------------------------------------------------
    function testFuzzPrincipalIsExactFloorAndNeverOverchargesBuyer(
        uint128 quantitySeed,
        uint128 priceSeed,
        uint8 decimalsSeed
    ) public {
        uint256 quantity = bound(uint256(quantitySeed), 1, type(uint128).max);
        uint256 price = bound(uint256(priceSeed), 1, type(uint128).max);
        uint8 decimals = uint8(bound(uint256(decimalsSeed), 0, 36));
        uint256 scale = 10 ** uint256(decimals);

        // Independent reference: the product fits in uint256 for uint128 inputs.
        uint256 exactProduct = quantity * price;
        uint256 referenceFloor = exactProduct / scale;
        if (referenceFloor == 0) {
            vm.expectRevert(HTPErrors.CashPrincipalZero.selector);
            harness.principal(quantity, price, decimals);
            return;
        }

        uint256 actual = harness.principal(quantity, price, decimals);
        assertEq(actual, referenceFloor, "floor");
        // Buyer never pays more than the exact value ...
        assertLe(actual * scale, exactProduct, "no overcharge");
        // ... and the shortfall is strictly below one settlement unit.
        assertLt(exactProduct - actual * scale, scale, "shortfall < 1 unit");
    }

    // ---------------------------------------------------------------
    // D-D. Cross-decimals matrix: asset 6/8/18 x settlement 6/18.
    //      The settlement token decimals never enter the formula.
    // ---------------------------------------------------------------
    function testCrossDecimalsMatrixHasNoSettlementDecimalsDependency() public view {
        uint8[3] memory assetDecimals = [uint8(6), 8, 18];
        // Two price scales representing 1.14 quoted in 6dp and in 18dp cash.
        uint256[2] memory prices = [uint256(1_140_000), uint256(1_140_000) * 1e12];

        for (uint256 a = 0; a < assetDecimals.length; ++a) {
            for (uint256 p = 0; p < prices.length; ++p) {
                uint8 decimals = assetDecimals[a];
                uint256 quantity = 100 * (10 ** uint256(decimals));
                uint256 expected = quantity * prices[p] / (10 ** uint256(decimals));
                assertEq(harness.principal(quantity, prices[p], decimals), expected);
                // 100 units always costs 100 * price regardless of asset decimals.
                assertEq(harness.principal(quantity, prices[p], decimals), 100 * prices[p]);
            }
        }
    }

    // Full-precision intermediate: q * p exceeds uint256 but q*p/10^d does not.
    // Verified against an independent 512-bit multiply, not against mulDiv.
    function testFuzzFullPrecisionIntermediateProductIsExact(
        uint256 quantitySeed,
        uint256 priceSeed,
        uint8 decimalsSeed
    ) public view {
        uint256 quantity = bound(quantitySeed, 1, type(uint256).max);
        uint256 price = bound(priceSeed, 1, type(uint256).max);
        uint8 decimals = uint8(bound(uint256(decimalsSeed), 1, 36));
        uint256 scale = 10 ** uint256(decimals);

        (uint256 productHigh,) = _mul512(quantity, price);
        // Skip parameter sets whose quotient itself overflows uint256.
        if (productHigh >= scale) return;

        uint256 actual;
        try harness.principal(quantity, price, decimals) returns (uint256 value) {
            actual = value;
        } catch {
            // Only legitimate reason left is a zero quotient.
            assertEq(productHigh, 0);
            assertLt(_mul512Low(quantity, price), scale);
            return;
        }
        _assertExactFloor(quantity, price, actual, scale);
    }

    function testFullPrecisionAtTheOverflowBoundary() public {
        // max * 10^36 / 10^36 == max. The intermediate product needs 512 bits.
        (uint256 high,) = _mul512(type(uint256).max, 10 ** 36);
        assertGt(high, 0, "product genuinely exceeds uint256");
        assertEq(harness.principal(type(uint256).max, 10 ** 36, 36), type(uint256).max);
        _assertExactFloor(type(uint256).max, 10 ** 36, type(uint256).max, 10 ** 36);

        // A non-trivial 512-bit case with a remainder.
        uint256 quantity = 1 << 200;
        uint256 price = (1 << 100) + 7;
        (uint256 high2,) = _mul512(quantity, price);
        assertGt(high2, 0, "second product exceeds uint256");
        uint256 actual = harness.principal(quantity, price, 36);
        _assertExactFloor(quantity, price, actual, 10 ** 36);

        // One unit above the representable quotient must revert, not wrap.
        vm.expectRevert();
        harness.principal(type(uint256).max, 10 ** 36 + 1, 36);
    }

    // ---------------------------------------------------------------
    // D-E. Rounding grinding: repeated settlements cannot accumulate a
    //      drift larger than one settlement unit per settlement, and the
    //      market rule quantum structure usually removes it entirely.
    // ---------------------------------------------------------------
    function testFuzzTruncationLossPerSettlementBoundedByOneUnit(uint128 quantitySeed, uint64 priceSeed) public view {
        uint256 price = bound(uint256(priceSeed), 1, type(uint64).max);
        uint256 quantity = bound(uint256(quantitySeed), 1, type(uint128).max);
        uint8 decimals = 18;
        uint256 scale = 1e18;
        uint256 exact = quantity * price;
        if (exact / scale == 0) return;
        uint256 charged = harness.principal(quantity, price, decimals);
        uint256 lossInSettlementUnits = (exact - charged * scale) / scale;
        assertEq(lossInSettlementUnits, 0, "loss strictly under one unit");
    }

    // When quantityStep * priceTick is a multiple of 10^assetDecimals the
    // truncation is exactly zero, which is what the production market rule does.
    function testQuantumAlignedGridHasZeroTruncation() public view {
        uint8 decimals = 18;
        uint256 step = 1e18;
        uint256 tick = 10_000;
        for (uint256 m = 1; m <= 5; ++m) {
            for (uint256 n = 1; n <= 5; ++n) {
                uint256 quantity = m * step;
                uint256 price = n * tick;
                assertEq(harness.principal(quantity, price, decimals), quantity * price / 1e18);
                assertEq(harness.principal(quantity, price, decimals) * 1e18, quantity * price);
            }
        }
    }

    // ---------------------------------------------------------------
    // D-F. Zero and extreme inputs.
    // ---------------------------------------------------------------
    function testZeroAndExtremeInputs() public {
        // quantity = 0 -> CashPrincipalZero
        vm.expectRevert(HTPErrors.CashPrincipalZero.selector);
        harness.principal(0, 1e18, 18);
        // price = 0 -> CashPrincipalZero
        vm.expectRevert(HTPErrors.CashPrincipalZero.selector);
        harness.principal(1e18, 0, 18);
        // decimals = 37 -> AssetDecimalsOutOfRange
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.AssetDecimalsOutOfRange.selector, uint8(37)));
        harness.principal(1e18, 1e18, 37);
        // decimals = 0 is accepted (no scaling)
        assertEq(harness.principal(7, 11, 0), 77);
        // max quantity with unit price 1 and no scaling
        assertEq(harness.principal(type(uint256).max, 1, 0), type(uint256).max);

        // rate above 100% is rejected, exactly 100% is accepted.
        FeeConfig memory config;
        config.roundingMode = RoundingMode.DOWN;
        config.investorRateBps = 10_001;
        (FeeMath.CalculationStatus status,,,,,) =
            harness.tryCalculate(1_000, ParticipantType.INVESTOR, ParticipantType.MAKER, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.INVESTOR_RATE_OUT_OF_RANGE));

        // rounding mode NONE is rejected (fail-closed on unset config).
        FeeConfig memory noRounding;
        noRounding.investorRateBps = 25;
        (FeeMath.CalculationStatus noRoundingStatus,,,,,) =
            harness.tryCalculate(1_000, ParticipantType.INVESTOR, ParticipantType.MAKER, noRounding);
        assertEq(uint8(noRoundingStatus), uint8(FeeMath.CalculationStatus.INVALID_CONFIG));

        // cashPrincipal = 0 is accepted by FeeMath itself (PrincipalMath is the gate).
        FeeConfig memory zeroPrincipal;
        zeroPrincipal.roundingMode = RoundingMode.DOWN;
        zeroPrincipal.investorRateBps = 10_000;
        zeroPrincipal.makerRateBps = 10_000;
        (
            FeeMath.CalculationStatus zeroStatus,
            uint256 zeroBuyerFee,,
            uint256 zeroDebit,
            uint256 zeroCredit,
            uint256 zeroCollector
        ) = harness.tryCalculate(0, ParticipantType.INVESTOR, ParticipantType.MAKER, zeroPrincipal);
        assertEq(uint8(zeroStatus), uint8(FeeMath.CalculationStatus.SUCCESS));
        assertEq(zeroBuyerFee, 0);
        assertEq(zeroDebit, 0);
        assertEq(zeroCredit, 0);
        assertEq(zeroCollector, 0);
    }

    // NONE participant type is rejected on both sides.
    function testNoneParticipantTypeRejected() public view {
        FeeConfig memory config;
        config.roundingMode = RoundingMode.DOWN;
        (FeeMath.CalculationStatus buyerStatus,,,,,) =
            harness.tryCalculate(1_000, ParticipantType.NONE, ParticipantType.MAKER, config);
        assertEq(uint8(buyerStatus), uint8(FeeMath.CalculationStatus.INVALID_BUYER_PARTICIPANT_TYPE));
        (FeeMath.CalculationStatus sellerStatus,,,,,) =
            harness.tryCalculate(1_000, ParticipantType.MAKER, ParticipantType.NONE, config);
        assertEq(uint8(sellerStatus), uint8(FeeMath.CalculationStatus.INVALID_SELLER_PARTICIPANT_TYPE));
    }

    // ---------------------------------------------------------------
    // D-G. FeeScope key/hash injectivity (abi.encode, not encodePacked).
    // ---------------------------------------------------------------
    function testFuzzFeeScopeHashIsInjective(
        uint64 epochA,
        uint8 typeA,
        bytes32 keyA,
        uint64 epochB,
        uint8 typeB,
        bytes32 keyB
    ) public view {
        ScopeType scopeA = ScopeType(uint8(bound(uint256(typeA), 1, 5)));
        ScopeType scopeB = ScopeType(uint8(bound(uint256(typeB), 1, 5)));
        bytes32 hashA = harness.scopeHash(epochA, scopeA, keyA);
        bytes32 hashB = harness.scopeHash(epochB, scopeB, keyB);
        bool sameInput = epochA == epochB && scopeA == scopeB && keyA == keyB;
        if (sameInput) {
            assertEq(hashA, hashB);
        } else {
            assertTrue(hashA != hashB, "distinct scope tuples must not collide");
        }
    }

    // ASSET_CLASS key 1..3 and CHAIN key 1..3 share the same raw bytes but
    // never the same matchedScopeHash because scopeType is a separate word.
    function testAssetClassAndChainKeysDoNotCollide() public view {
        for (uint256 value = 1; value <= 3; ++value) {
            bytes32 assetClassHash = harness.scopeHash(7, ScopeType.ASSET_CLASS, bytes32(value));
            bytes32 chainHash = harness.scopeHash(7, ScopeType.CHAIN, bytes32(value));
            bytes32 instrumentHash = harness.scopeHash(7, ScopeType.INSTRUMENT, bytes32(value));
            bytes32 assetVersionHash = harness.scopeHash(7, ScopeType.ASSET_VERSION, bytes32(value));
            assertTrue(assetClassHash != chainHash);
            assertTrue(assetClassHash != instrumentHash);
            assertTrue(assetClassHash != assetVersionHash);
            assertTrue(chainHash != instrumentHash);
            assertTrue(chainHash != assetVersionHash);
            assertTrue(instrumentHash != assetVersionHash);
        }
    }

    // GLOBAL is the only scope whose canonical key is zero.
    function testGlobalScopeUsesZeroKeyAndIsDistinctFromEveryOtherScope() public view {
        bytes32 globalHash = harness.scopeHash(7, ScopeType.GLOBAL, bytes32(0));
        assertTrue(globalHash != harness.scopeHash(7, ScopeType.CHAIN, bytes32(0)));
        assertTrue(globalHash != harness.scopeHash(8, ScopeType.GLOBAL, bytes32(0)));
    }

    // ---------------------------------------------------------------
    // D-H. CalendarDate differential test against an independent
    //      day-number round trip (Howard Hinnant civil_from_days).
    // ---------------------------------------------------------------
    function testFuzzCalendarDateMatchesIndependentReference(uint32 dateSeed) public view {
        uint32 date = uint32(bound(uint256(dateSeed), 0, 99_999_999));
        assertEq(harness.calendarValid(date), _referenceCalendarValid(date), "calendar parity");
    }

    function testCalendarDateBoundaryVectors() public view {
        assertTrue(harness.calendarValid(20_000_229)); // 2000 is a leap year (div by 400)
        assertTrue(harness.calendarValid(20_240_229)); // 2024 leap
        assertFalse(harness.calendarValid(19_000_229)); // 1900 not leap (div by 100)
        assertFalse(harness.calendarValid(20_230_229)); // 2023 not leap
        assertTrue(harness.calendarValid(20_231_231)); // year end
        assertFalse(harness.calendarValid(20_231_232)); // day 32
        assertFalse(harness.calendarValid(20_231_301)); // month 13
        assertFalse(harness.calendarValid(20_230_001)); // month 0
        assertFalse(harness.calendarValid(20_230_100)); // day 0
        assertTrue(harness.calendarValid(10_101)); // year 1, 1 Jan
        assertFalse(harness.calendarValid(101)); // year 0
        assertTrue(harness.calendarValid(99_991_231)); // year 9999 upper bound
        assertFalse(harness.calendarValid(100_001_231)); // year 10000 rejected
        assertFalse(harness.calendarValid(type(uint32).max)); // 4294967295 -> year 429496
        assertFalse(harness.calendarValid(20_230_431)); // 31 April
        assertTrue(harness.calendarValid(20_230_430));
        assertFalse(harness.calendarValid(20_230_631)); // 31 June
        assertFalse(harness.calendarValid(20_230_931)); // 31 September
        assertFalse(harness.calendarValid(20_231_131)); // 31 November
    }

    // ---------------------------------------------------------------
    // D-I. Bond: accrued interest is an unvalidated free input that
    //      bypasses the market-rule price tick (tick binds clean price).
    // ---------------------------------------------------------------
    function testBondAccruedInterestIsUnboundedAndBypassesPriceTick() public view {
        uint256 cleanPrice = 10_000; // tick-aligned for priceTick = 10_000
        uint256 hugeAccrued = 999_999; // not tick-aligned, arbitrary magnitude
        bytes memory priceData = abi.encode(cleanPrice, hugeAccrued, uint256(20_260_812), bytes32(uint256(0x703)));

        (, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal) = bond.calculate(priceData, 1e18, 18);
        assertEq(quotedPrice, cleanPrice, "tick check only sees clean price");
        assertEq(unitCashPrice, cleanPrice + hugeAccrued);
        assertEq(cashPrincipal, cleanPrice + hugeAccrued);
        assertEq(quotedPrice % 10_000, 0, "clean price passes tick");
        assertTrue(unitCashPrice % 10_000 != 0, "effective price is not tick aligned");
        // 100x the clean price can be smuggled through accrued interest.
        bytes memory inflated = abi.encode(cleanPrice, cleanPrice * 99, uint256(20_260_812), bytes32(uint256(0x703)));
        (, uint256 inflatedQuoted,, uint256 inflatedPrincipal) = bond.calculate(inflated, 1e18, 18);
        assertEq(inflatedQuoted, cleanPrice);
        assertEq(inflatedPrincipal, cleanPrice * 100);
    }

    // Bond settlementDate is calendar-checked only; it is never compared to
    // block.timestamp, tradeDeadline, or the accrued amount.
    function testBondSettlementDateIsNotBoundToBlockTime() public view {
        bytes memory stale = abi.encode(uint256(10_000), uint256(1), uint256(19_700_101), bytes32(uint256(0x703)));
        (,,, uint256 principal) = bond.calculate(stale, 1e18, 18);
        assertEq(principal, 10_001);
        bytes memory future = abi.encode(uint256(10_000), uint256(1), uint256(99_991_231), bytes32(uint256(0x703)));
        (,,, uint256 futurePrincipal) = bond.calculate(future, 1e18, 18);
        assertEq(futurePrincipal, 10_001);
    }

    // Fund/NAV navDate has the same property.
    function testFundNavDateIsNotBoundToBlockTime() public view {
        bytes memory stale = abi.encode(
            FundPriceTerms({navPerUnit: 1_140_000, navDate: 19_700_101, navSourceHash: bytes32(uint256(1))})
        );
        (,,, uint256 principal) = fund.calculate(stale, 1e18, 18);
        assertEq(principal, 1_140_000);
    }

    // Stock priceAsOf likewise: any non-zero uint64 is accepted.
    function testStockPriceAsOfIsNotBoundToBlockTime() public view {
        bytes memory terms = abi.encode(uint256(1_140_000), uint256(1), bytes32(uint256(1)), bytes32(uint256(2)));
        (,,, uint256 principal) = stock.calculate(terms, 1e18, 18);
        assertEq(principal, 1_140_000);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------
    function _reachablePair(uint8 pairSeed)
        private
        pure
        returns (ParticipantType buyerType, ParticipantType sellerType)
    {
        uint8 selector = uint8(pairSeed % 3);
        if (selector == 0) return (ParticipantType.INVESTOR, ParticipantType.MAKER);
        if (selector == 1) return (ParticipantType.MAKER, ParticipantType.INVESTOR);
        return (ParticipantType.MAKER, ParticipantType.MAKER);
    }

    function _expectedFee(uint256 cashPrincipal, ParticipantType participantType, FeeConfig memory config)
        private
        pure
        returns (uint256)
    {
        uint16 rate = participantType == ParticipantType.INVESTOR ? config.investorRateBps : config.makerRateBps;
        bool hasCap = participantType == ParticipantType.INVESTOR ? config.investorHasCap : config.makerHasCap;
        uint256 cap = participantType == ParticipantType.INVESTOR ? config.investorCapAmount : config.makerCapAmount;
        // cashPrincipal <= max/4 so the intermediate product fits after the
        // rate factor is folded in via the distributive split below.
        uint256 whole = cashPrincipal / 10_000;
        uint256 remainder = cashPrincipal % 10_000;
        uint256 fee = whole * rate + (remainder * rate) / 10_000;
        if (hasCap && fee > cap) fee = cap;
        return fee;
    }

    // Independent 512-bit multiply (no OpenZeppelin Math involved).
    function _mul512(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        unchecked {
            low = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            high = mm - low;
            if (mm < low) high -= 1;
        }
    }

    function _mul512Low(uint256 a, uint256 b) private pure returns (uint256 low) {
        (, low) = _mul512(a, b);
    }

    // Assert quotient * scale + remainder == quantity * price exactly in 512 bits,
    // with 0 <= remainder < scale. This pins both exactness and floor direction.
    function _assertExactFloor(uint256 quantity, uint256 price, uint256 quotient, uint256 scale) private pure {
        uint256 remainder = mulmod(quantity, price, scale);
        require(remainder < scale, "remainder");
        (uint256 productHigh, uint256 productLow) = _mul512(quantity, price);
        (uint256 checkHigh, uint256 checkLow) = _mul512(quotient, scale);
        unchecked {
            uint256 summed = checkLow + remainder;
            if (summed < checkLow) checkHigh += 1;
            checkLow = summed;
        }
        require(checkHigh == productHigh && checkLow == productLow, "quotient*scale+rem != q*p");
    }

    function _referenceCalendarValid(uint32 date) private pure returns (bool) {
        uint256 year = date / 10_000;
        uint256 month = (date / 100) % 100;
        uint256 day = date % 100;
        if (year < 1 || year > 9999) return false;
        if (month < 1 || month > 12) return false;
        if (day < 1) return false;
        // Independent month length table with an independent leap rule.
        uint256[13] memory lengths = [uint256(0), 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        uint256 limit = lengths[month];
        if (month == 2 && _referenceIsLeap(year)) limit = 29;
        return day <= limit;
    }

    function _referenceIsLeap(uint256 year) private pure returns (bool) {
        if (year % 400 == 0) return true;
        if (year % 100 == 0) return false;
        return year % 4 == 0;
    }
}

// =====================================================================
// End-to-end settle() level probes against the production topology.
// =====================================================================
contract TmpAuditModuleDSettleTest is DvPPreCheckTestBase {
    uint64 private constant AUDIT_EPOCH = 2;

    function testBaselineSettleSucceeds() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), params.snapshot.sellerCredit);
        assertEq(settlementToken.balanceOf(COLLECTOR), params.snapshot.collectorCredit);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    // Field-by-field proof that every signed money field is recomputed on chain.
    // Each mutation is applied to BOTH TradeIntent and Snapshot and both
    // signatures are regenerated, i.e. the counterparties fully "agree" to the
    // wrong number. settle() must still refuse.
    function testEverySignedAmountFieldIsRecomputedOnChain() public {
        _expectAmountRejected(0, HTPErrors.CashPrincipalZero.selector); // cashPrincipal
        _expectAmountRejected(1, HTPErrors.FeeSnapshotMismatch.selector); // buyerFee
        _expectAmountRejected(2, HTPErrors.FeeSnapshotMismatch.selector); // sellerFee
        _expectAmountRejected(3, HTPErrors.FeeSnapshotMismatch.selector); // buyerDebit
        _expectAmountRejected(4, HTPErrors.FeeSnapshotMismatch.selector); // sellerCredit
        _expectAmountRejected(5, HTPErrors.FeeSnapshotMismatch.selector); // collectorCredit
    }

    // A conservation-breaking snapshot (buyerDebit inflated, collectorCredit
    // inflated to match) is rejected by the fee recomputation, i.e. the balance
    // delta post-condition is never even reached.
    function testConservationBreakingSnapshotIsRejectedBeforeAnyTransfer() public {
        SettlementParams memory params = _validPreCheckParams();
        uint256 stolen = 1_000_000;
        params.tradeIntent.buyerDebit += stolen;
        params.snapshot.buyerDebit += stolen;
        params.tradeIntent.collectorCredit += stolen;
        params.snapshot.collectorCredit += stolen;
        params.tradeIntent.buyerFee += stolen;
        params.snapshot.buyerFee += stolen;
        _resign(params);

        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), params.snapshot.buyerDebit);
        uint256 sellerAssetBefore = assetToken.balanceOf(params.snapshot.seller);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
        assertEq(assetToken.balanceOf(params.snapshot.seller), sellerAssetBefore, "no asset moved");
    }

    // executedQuantity is NOT recomputed: it is a free Requester choice inside
    // the Maker-signed band. The principal follows it, so this is intended.
    function testExecutedQuantityIsFreeWithinTheSignedBand() public {
        SettlementParams memory params = _validPreCheckParams();
        // Quote band is [1 ether, ... ] with step 1 ether; move to 9 ether.
        params.tradeIntent.executedQuantity = 9 ether;
        params.snapshot.executedQuantity = 9 ether;
        uint256 principal = 9 * 1_140_000;
        _setAmounts(params, principal);
        _resign(params);

        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(params.snapshot.cashPrincipal, 10_260_000);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 9 ether);
    }

    // executedQuantity = 0 is rejected before any registry work.
    function testZeroExecutedQuantityIsRejected() public {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.executedQuantity = 0;
        params.snapshot.executedQuantity = 0;
        _resign(params);
        vm.prank(EXECUTOR);
        vm.expectRevert(HTPErrors.InvalidQuantityRange.selector);
        dvp.settle(params);
    }

    // PoC: 100% on both fee tiers settles cleanly. Seller delivers 10 units of
    // the asset and receives ZERO cash; the collector takes 2x the principal.
    // 修复后：两档各 100%（聚合 200%）在登记期即被 AggregateFeeRateOutOfRange 拒绝，
    // 断言见 test/unit/FeeRegistryConfig.t.sol。这里改为端到端确认——在可登记的
    // 费率下，资产交割必然换回正的现金对付，收费方拿不走本金量级的金额。
    // 500/500 是可登记的极值：上限判的是最坏可达聚合 2×较高档，不是两档之和。
    function testSellerAlwaysReceivesCashUnderRegistrableFees() public {
        SettlementParams memory params = _auditFeeParams(500, 500);
        uint256 principal = params.snapshot.cashPrincipal;

        assertGt(params.snapshot.sellerCredit, 0, "seller must be paid for delivered assets");
        assertLe(params.snapshot.collectorCredit, principal, "fees can never exceed the principal");
        assertEq(
            params.snapshot.buyerDebit, params.snapshot.sellerCredit + params.snapshot.collectorCredit, "conservation"
        );

        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), params.snapshot.buyerDebit);
        settlementToken.setBalance(params.snapshot.buyer, params.snapshot.buyerDebit);
        uint256 sellerCashBefore = settlementToken.balanceOf(params.snapshot.seller);

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(
            settlementToken.balanceOf(params.snapshot.seller) - sellerCashBefore,
            params.snapshot.sellerCredit,
            "seller receives exactly the signed net amount"
        );
        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    // Deprecating the fee version does NOT stop new settlements; only PAUSED does.
    function testDeprecatedFeeVersionStillSettles() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(feeConfig.feeVersionId, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(settlementToken.balanceOf(COLLECTOR), params.snapshot.collectorCredit);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------
    function _expectAmountRejected(uint8 fieldIndex, bytes4 expectedSelector) private {
        SettlementParams memory params = _validPreCheckParams();
        if (fieldIndex == 0) {
            params.tradeIntent.cashPrincipal += 1;
            params.snapshot.cashPrincipal += 1;
        } else if (fieldIndex == 1) {
            params.tradeIntent.buyerFee += 1;
            params.snapshot.buyerFee += 1;
        } else if (fieldIndex == 2) {
            params.tradeIntent.sellerFee += 1;
            params.snapshot.sellerFee += 1;
        } else if (fieldIndex == 3) {
            params.tradeIntent.buyerDebit += 1;
            params.snapshot.buyerDebit += 1;
        } else if (fieldIndex == 4) {
            params.tradeIntent.sellerCredit += 1;
            params.snapshot.sellerCredit += 1;
        } else {
            params.tradeIntent.collectorCredit += 1;
            params.snapshot.collectorCredit += 1;
        }
        _resign(params);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), params.snapshot.buyerDebit + 10);
        vm.prank(EXECUTOR);
        vm.expectPartialRevert(expectedSelector);
        dvp.settle(params);
    }

    function _setAmounts(SettlementParams memory params, uint256 principal) private {
        params.tradeIntent.cashPrincipal = principal;
        params.snapshot.cashPrincipal = principal;
        _applyFeeAmounts(params, ParticipantType.INVESTOR, ParticipantType.MAKER, feeConfig);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), params.snapshot.buyerDebit);
    }

    function _auditFeeParams(uint16 investorRateBps, uint16 makerRateBps)
        private
        returns (SettlementParams memory params)
    {
        uint64 validFrom = CREATED_AT + 1;
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: AUDIT_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: validFrom,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash =
            FeeScope.matchedHash(AUDIT_EPOCH, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId);
        FeeConfig memory audited = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: AUDIT_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionConfig.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: investorRateBps,
            investorHasCap: false,
            investorCapAmount: 0,
            makerRateBps: makerRateBps,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: validFrom,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        audited.feeConstraintHash = HTPHashing.hashFeeConstraint(audited);
        audited.configHash = HTPHashing.hashFeeConfig(audited);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(audited);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(AUDIT_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(audited.feeVersionId, audited.configHash);
        vm.warp(validFrom);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(AUDIT_EPOCH, epoch.configHash, audited.feeVersionId);

        params = _validPreCheckParams();
        params.firmQuote.feePolicyEpoch = AUDIT_EPOCH;
        params.tradeIntent.feePolicyEpoch = AUDIT_EPOCH;
        params.snapshot.feePolicyEpoch = AUDIT_EPOCH;
        params.firmQuote.feeVersionId = audited.feeVersionId;
        params.tradeIntent.feeVersionId = audited.feeVersionId;
        params.snapshot.feeVersionId = audited.feeVersionId;
        params.firmQuote.matchedScopeHash = audited.matchedScopeHash;
        params.tradeIntent.matchedScopeHash = audited.matchedScopeHash;
        params.snapshot.matchedScopeHash = audited.matchedScopeHash;
        params.firmQuote.feeConstraintHash = audited.feeConstraintHash;
        params.tradeIntent.feeConstraintHash = audited.feeConstraintHash;
        params.snapshot.feeConstraintHash = audited.feeConstraintHash;
        params.snapshot.createdAt = validFrom;
        _applyFeeAmounts(params, ParticipantType.INVESTOR, ParticipantType.MAKER, audited);
        _resign(params);
    }
}
