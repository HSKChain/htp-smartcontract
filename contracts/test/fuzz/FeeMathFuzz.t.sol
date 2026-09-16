// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeConfig, ParticipantType, RoundingMode} from "src/types/HTPTypes.sol";

/*
 * 费用黄金向量的链上一侧。
 *
 * 与 packages/calc-reference/test/fee.test.ts 读同一份 JSON：链下报价服务必须
 * 独立重算出与链上一致的五个金额，否则签好的成交在结算时会被现态重算判为不符而
 * 无法落块。任何一侧改了舍入、封顶顺序或判定次序，这里都会立刻红。
 *
 * 对照 PrincipalCalculatorFuzz.t.sol，本文件是费用侧的同构物。
 */
contract FeeMathFuzzTest is Test {
    string private vectorsJson;
    uint256 private fuzzCorpusSize;
    uint256 private invalidCorpusSize;

    function setUp() public {
        vectorsJson = vm.readFile(string.concat(vm.projectRoot(), "/../schema/v1/vectors/fees/amounts-v1.json"));
        fuzzCorpusSize = vm.parseJsonUint(vectorsJson, ".fuzzCorpusSize");
        invalidCorpusSize = vm.parseJsonUint(vectorsJson, ".invalidCorpusSize");
    }

    function testFuzzCorpusMatchesIndependentReference(uint256 seed) public view {
        _assertVector(string.concat(".fuzzCorpus[", vm.toString(bound(seed, 0, fuzzCorpusSize - 1)), "]"));
    }

    // 每条向量要解 13 个 JSON 字段，约 22M gas；整段 240 条会撞上单次调用的 gas 上限，
    // 因此照本金侧的做法分块。CHUNK 覆盖必须完整，由末块的 assertEq 钉住总数。
    uint256 private constant CHUNK = 30;

    function testGeneratedFuzzCorpusChunk0() public view {
        _assertRange(0, CHUNK);
    }

    function testGeneratedFuzzCorpusChunk1() public view {
        _assertRange(CHUNK, 2 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk2() public view {
        _assertRange(2 * CHUNK, 3 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk3() public view {
        _assertRange(3 * CHUNK, 4 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk4() public view {
        _assertRange(4 * CHUNK, 5 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk5() public view {
        _assertRange(5 * CHUNK, 6 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk6() public view {
        _assertRange(6 * CHUNK, 7 * CHUNK);
    }

    function testGeneratedFuzzCorpusChunk7() public view {
        // 语料规模变了就必须回来加块，否则尾部会被静默跳过。
        assertEq(fuzzCorpusSize, 8 * CHUNK);
        _assertRange(7 * CHUNK, fuzzCorpusSize);
    }

    function _assertRange(uint256 start, uint256 endExclusive) private view {
        for (uint256 i = start; i < endExclusive; ++i) {
            _assertVector(string.concat(".fuzzCorpus[", vm.toString(i), "]"));
        }
    }

    function testEveryInvalidVectorMatchesIndependentReference() public view {
        assertGt(invalidCorpusSize, 0);
        for (uint256 i = 0; i < invalidCorpusSize; ++i) {
            _assertVector(string.concat(".invalidCorpus[", vm.toString(i), "]"));
        }
    }

    // 命名向量按名字逐条断言：出问题时报的是业务场景名而不是数组下标。
    function testNamedVectorsMatchIndependentReference() public view {
        string[8] memory names = [
            "investorBuysFromMakerWithBuyerCap",
            "investorOnBothLegsPaysSymmetricFees",
            "zeroRatesLeaveTheCollectorEmpty",
            "subUnitFeesRoundDownToZero",
            "capEqualToUncappedFeeDoesNotTruncate",
            "zeroCapMeansNoFee",
            "aggregateExactlyAtRegistrableBound",
            "sellerFeeEqualToPrincipalZeroesTheCredit"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            _assertVector(string.concat(".valid.", names[i]));
        }
    }

    // 常量必须与参考实现同源，否则向量再多也只是各算各的。
    function testProtocolConstantsAgreeWithTheReferenceModel() public view {
        assertEq(vm.parseUint(vm.parseJsonString(vectorsJson, ".constants.bpsDenominator")), FeeMath.BPS_DENOMINATOR);
        assertEq(
            vm.parseUint(vm.parseJsonString(vectorsJson, ".constants.maxAggregateFeeBps")),
            FeeMath.MAX_AGGREGATE_FEE_BPS
        );
        assertEq(vm.parseJsonString(vectorsJson, ".onChainModel"), "contracts/src/libraries/FeeMath.sol");
    }

    // FeeMath.tryCalculate 返回六元组，直接摊在栈上会超深，故用 struct 承载。
    struct Outcome {
        FeeMath.CalculationStatus status;
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 buyerDebit;
        uint256 sellerCredit;
        uint256 collectorCredit;
    }

    function _assertVector(string memory base) private view {
        Outcome memory outcome = _evaluate(base);
        string memory name = vm.parseJsonString(vectorsJson, string.concat(base, ".name"));

        assertEq(_statusName(outcome.status), vm.parseJsonString(vectorsJson, string.concat(base, ".status")), name);
        _assertAmount(base, ".output.buyerFee", outcome.buyerFee, name);
        _assertAmount(base, ".output.sellerFee", outcome.sellerFee, name);
        _assertAmount(base, ".output.buyerDebit", outcome.buyerDebit, name);
        _assertAmount(base, ".output.sellerCredit", outcome.sellerCredit, name);
        _assertAmount(base, ".output.collectorCredit", outcome.collectorCredit, name);

        if (outcome.status == FeeMath.CalculationStatus.SUCCESS) {
            assertEq(outcome.buyerDebit, outcome.sellerCredit + outcome.collectorCredit, name);
        }
    }

    function _evaluate(string memory base) private view returns (Outcome memory outcome) {
        (
            outcome.status,
            outcome.buyerFee,
            outcome.sellerFee,
            outcome.buyerDebit,
            outcome.sellerCredit,
            outcome.collectorCredit
        ) =
            FeeMath.tryCalculate(
                vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".input.cashPrincipal"))),
                ParticipantType(vm.parseJsonUint(vectorsJson, string.concat(base, ".input.buyerParticipantTypeId"))),
                ParticipantType(vm.parseJsonUint(vectorsJson, string.concat(base, ".input.sellerParticipantTypeId"))),
                _config(base)
            );
    }

    function _config(string memory base) private view returns (FeeConfig memory config) {
        config.investorRateBps = uint16(vm.parseJsonUint(vectorsJson, string.concat(base, ".input.investorRateBps")));
        config.investorHasCap = vm.parseJsonBool(vectorsJson, string.concat(base, ".input.investorHasCap"));
        config.investorCapAmount =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".input.investorCapAmount")));
        config.makerRateBps = uint16(vm.parseJsonUint(vectorsJson, string.concat(base, ".input.makerRateBps")));
        config.makerHasCap = vm.parseJsonBool(vectorsJson, string.concat(base, ".input.makerHasCap"));
        config.makerCapAmount =
            vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, ".input.makerCapAmount")));
        config.roundingMode = RoundingMode(vm.parseJsonUint(vectorsJson, string.concat(base, ".input.roundingModeId")));
    }

    function _assertAmount(string memory base, string memory field, uint256 actual, string memory name) private view {
        uint256 expected = vm.parseUint(vm.parseJsonString(vectorsJson, string.concat(base, field)));
        assertEq(actual, expected, string.concat(name, field));
    }

    // 枚举名而非序号进向量：序号一改动，向量会静默指向另一个状态。
    function _statusName(FeeMath.CalculationStatus status) private pure returns (string memory) {
        if (status == FeeMath.CalculationStatus.SUCCESS) return "SUCCESS";
        if (status == FeeMath.CalculationStatus.INVALID_CONFIG) return "INVALID_CONFIG";
        if (status == FeeMath.CalculationStatus.INVALID_BUYER_PARTICIPANT_TYPE) {
            return "INVALID_BUYER_PARTICIPANT_TYPE";
        }
        if (status == FeeMath.CalculationStatus.INVALID_SELLER_PARTICIPANT_TYPE) {
            return "INVALID_SELLER_PARTICIPANT_TYPE";
        }
        if (status == FeeMath.CalculationStatus.INVESTOR_RATE_OUT_OF_RANGE) return "INVESTOR_RATE_OUT_OF_RANGE";
        if (status == FeeMath.CalculationStatus.MAKER_RATE_OUT_OF_RANGE) return "MAKER_RATE_OUT_OF_RANGE";
        if (status == FeeMath.CalculationStatus.SELLER_FEE_EXCEEDS_PRINCIPAL) return "SELLER_FEE_EXCEEDS_PRINCIPAL";
        if (status == FeeMath.CalculationStatus.AGGREGATE_FEE_EXCEEDS_PRINCIPAL) {
            return "AGGREGATE_FEE_EXCEEDS_PRINCIPAL";
        }
        if (status == FeeMath.CalculationStatus.OVERFLOW) return "OVERFLOW";
        return "CONSERVATION_MISMATCH";
    }
}
