// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract QuantityRulesFuzzTest is DvPPreCheckTestBase {
    uint256 private constant EXECUTED = 10 ether;

    function testFuzzValidRelativeStepAndExtremeMaximumPass(
        uint96 stepSeed,
        uint96 stepsBelowSeed,
        uint256 headroomSeed
    ) public view {
        SettlementParams memory params = _validPreCheckParams();
        uint256 step = bound(uint256(stepSeed), 1, 10) * 1 ether;
        uint256 maxStepsBelow = step >= EXECUTED ? 0 : (EXECUTED - 1) / step;
        uint256 stepsBelow = bound(uint256(stepsBelowSeed), 0, maxStepsBelow);
        uint256 minimum = EXECUTED - stepsBelow * step;
        uint256 maximum = EXECUTED + bound(headroomSeed, 0, 1_000_000) * 1 ether;

        params.firmQuote.minExecutableQuantity = minimum;
        params.firmQuote.maxExecutableQuantity = maximum;
        params.firmQuote.stepQuantity = step;
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
    }

    function testFuzzInvalidQuantityTuplesFailClosed(uint8 caseSeed, uint256 valueSeed) public view {
        SettlementParams memory params = _validPreCheckParams();
        bytes4 expectedReason;
        uint256 selected = caseSeed % 7;

        if (selected == 0) {
            params.tradeIntent.executedQuantity = 0;
            params.snapshot.executedQuantity = 0;
            expectedReason = HTPErrors.InvalidQuantityRange.selector;
        } else if (selected == 1) {
            params.firmQuote.minExecutableQuantity = 0;
            expectedReason = HTPErrors.InvalidQuantityRange.selector;
        } else if (selected == 2) {
            uint256 minimum = bound(valueSeed, 2, type(uint256).max);
            params.firmQuote.minExecutableQuantity = minimum;
            params.firmQuote.maxExecutableQuantity = minimum - 1;
            params.tradeIntent.executedQuantity = minimum;
            params.snapshot.executedQuantity = minimum;
            expectedReason = HTPErrors.InvalidQuantityRange.selector;
        } else if (selected == 3) {
            uint256 minimum = bound(valueSeed, 2, type(uint256).max);
            params.firmQuote.minExecutableQuantity = minimum;
            params.firmQuote.maxExecutableQuantity = type(uint256).max;
            params.tradeIntent.executedQuantity = minimum - 1;
            params.snapshot.executedQuantity = minimum - 1;
            expectedReason = HTPErrors.InvalidQuantityRange.selector;
        } else if (selected == 4) {
            uint256 maximum = bound(valueSeed, 1, type(uint256).max - 1);
            params.firmQuote.minExecutableQuantity = 1;
            params.firmQuote.maxExecutableQuantity = maximum;
            params.tradeIntent.executedQuantity = maximum + 1;
            params.snapshot.executedQuantity = maximum + 1;
            expectedReason = HTPErrors.InvalidQuantityRange.selector;
        } else if (selected == 5) {
            params.firmQuote.stepQuantity = 0;
            expectedReason = HTPErrors.InvalidQuantityStep.selector;
        } else {
            params.firmQuote.minExecutableQuantity = 1;
            params.firmQuote.maxExecutableQuantity = type(uint256).max;
            params.firmQuote.stepQuantity = 2;
            params.tradeIntent.executedQuantity = 2;
            params.snapshot.executedQuantity = 2;
            expectedReason = HTPErrors.InvalidQuantityStep.selector;
        }
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, expectedReason);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function testExtremeStepIsValidWhenExecutedEqualsMinimum() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.firmQuote.minExecutableQuantity = EXECUTED;
        uint256 largestGridValue = type(uint256).max / 1 ether * 1 ether;
        params.firmQuote.maxExecutableQuantity = largestGridValue;
        params.firmQuote.stepQuantity = largestGridValue;
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
    }
}
