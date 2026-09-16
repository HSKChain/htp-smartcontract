// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {FeeConfig, ParticipantType, RoundingMode} from "src/types/HTPTypes.sol";

contract FeeMathHarness {
    function calculate(
        uint256 cashPrincipal,
        ParticipantType buyerParticipantType,
        ParticipantType sellerParticipantType,
        FeeConfig calldata config
    )
        external
        pure
        returns (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit)
    {
        return FeeMath.calculate(cashPrincipal, buyerParticipantType, sellerParticipantType, config);
    }

    function tryCalculate(
        uint256 cashPrincipal,
        ParticipantType buyerParticipantType,
        ParticipantType sellerParticipantType,
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
        return FeeMath.tryCalculate(cashPrincipal, buyerParticipantType, sellerParticipantType, config);
    }
}

contract FeeMathTest is Test {
    FeeMathHarness internal harness = new FeeMathHarness();

    function testCalculatesDownRoundedCappedFeesAndConservedCash() public view {
        FeeConfig memory config;
        config.investorRateBps = 25;
        config.investorHasCap = true;
        config.investorCapAmount = 2_000;
        config.makerRateBps = 15;
        config.roundingMode = RoundingMode.DOWN;

        (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            harness.calculate(1_000_000, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        assertEq(buyerFee, 2_000);
        assertEq(sellerFee, 1_500);
        assertEq(buyerDebit, 1_002_000);
        assertEq(sellerCredit, 998_500);
        assertEq(collectorCredit, 3_500);
        assertEq(buyerDebit, sellerCredit + collectorCredit);
    }

    function testSellDirectionUsesMakerForBuyerAndInvestorForSeller() public view {
        FeeConfig memory config;
        config.investorRateBps = 25;
        config.investorHasCap = true;
        config.investorCapAmount = 2_000;
        config.makerRateBps = 15;
        config.roundingMode = RoundingMode.DOWN;

        (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            harness.calculate(1_000_000, ParticipantType.MAKER, ParticipantType.INVESTOR, config);

        assertEq(buyerFee, 1_500);
        assertEq(sellerFee, 2_000);
        assertEq(buyerDebit, 1_001_500);
        assertEq(sellerCredit, 998_000);
        assertEq(collectorCredit, 3_500);
    }

    function testMakerToMakerUsesMakerRateForBothCashLegs() public view {
        FeeConfig memory config;
        config.investorRateBps = 25;
        config.makerRateBps = 15;
        config.roundingMode = RoundingMode.DOWN;

        (uint256 buyerFee, uint256 sellerFee,,,) =
            harness.calculate(1_000_000, ParticipantType.MAKER, ParticipantType.MAKER, config);

        assertEq(buyerFee, 1_500);
        assertEq(sellerFee, 1_500);
    }

    function testExplicitZeroCapProducesZeroFeeAndFloorRoundingIsDeterministic() public view {
        FeeConfig memory config;
        config.investorRateBps = 10_000;
        config.investorHasCap = true;
        config.investorCapAmount = 0;
        config.makerRateBps = 3_333;
        config.roundingMode = RoundingMode.DOWN;

        (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            harness.calculate(3, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        assertEq(buyerFee, 0);
        assertEq(sellerFee, 0);
        assertEq(buyerDebit, 3);
        assertEq(sellerCredit, 3);
        assertEq(collectorCredit, 0);
    }

    function testOverflowFailsWithStructuredErrorInsteadOfArithmeticPanic() public {
        FeeConfig memory config;
        config.investorRateBps = 10_000;
        config.roundingMode = RoundingMode.DOWN;

        vm.expectRevert(HTPErrors.FeeOverflow.selector);
        harness.calculate(type(uint256).max, ParticipantType.INVESTOR, ParticipantType.MAKER, config);
    }

    function testTryCalculateClassifiesFailuresWithoutReverting() public view {
        FeeConfig memory config;
        config.roundingMode = RoundingMode.NONE;
        (FeeMath.CalculationStatus status,,,,,) =
            harness.tryCalculate(1, ParticipantType.INVESTOR, ParticipantType.MAKER, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.INVALID_CONFIG));

        config.roundingMode = RoundingMode.DOWN;
        (status,,,,,) = harness.tryCalculate(1, ParticipantType.NONE, ParticipantType.MAKER, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.INVALID_BUYER_PARTICIPANT_TYPE));

        config.investorRateBps = 10_001;
        (status,,,,,) = harness.tryCalculate(1, ParticipantType.INVESTOR, ParticipantType.MAKER, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.INVESTOR_RATE_OUT_OF_RANGE));

        config.investorRateBps = 10_000;
        (status,,,,,) = harness.tryCalculate(type(uint256).max, ParticipantType.INVESTOR, ParticipantType.MAKER, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.OVERFLOW));
    }

    function testCalculatePreservesTypedFailurePriority() public {
        FeeConfig memory config;
        config.investorRateBps = 10_001;

        vm.expectRevert(HTPErrors.InvalidFeeConfig.selector);
        harness.calculate(1, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        config.roundingMode = RoundingMode.DOWN;
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeRateOutOfRange.selector, ParticipantType.INVESTOR, uint16(10_001))
        );
        harness.calculate(1, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        config.investorRateBps = 0;
        config.makerRateBps = 10_001;
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeRateOutOfRange.selector, ParticipantType.MAKER, uint16(10_001))
        );
        harness.calculate(1, ParticipantType.INVESTOR, ParticipantType.MAKER, config);

        config.makerRateBps = 0;
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidFeeParticipantType.selector, ParticipantType.NONE));
        harness.calculate(1, ParticipantType.NONE, ParticipantType.MAKER, config);
    }
}
