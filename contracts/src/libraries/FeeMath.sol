// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {FeeConfig, ParticipantType, RoundingMode} from "../types/HTPTypes.sol";

library FeeMath {
    enum CalculationStatus {
        SUCCESS,
        INVALID_CONFIG,
        INVALID_BUYER_PARTICIPANT_TYPE,
        INVALID_SELLER_PARTICIPANT_TYPE,
        INVESTOR_RATE_OUT_OF_RANGE,
        MAKER_RATE_OUT_OF_RANGE,
        SELLER_FEE_EXCEEDS_PRINCIPAL,
        AGGREGATE_FEE_EXCEEDS_PRINCIPAL,
        OVERFLOW,
        CONSERVATION_MISMATCH
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_AGGREGATE_FEE_BPS = 1_000;

    /// @notice Computes fee splits and reverts with HTPErrors on invalid config or arithmetic failure.
    function calculate(
        uint256 cashPrincipal,
        ParticipantType buyerParticipantType,
        ParticipantType sellerParticipantType,
        FeeConfig memory config
    )
        internal
        pure
        returns (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit)
    {
        CalculationStatus status;
        (status, buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit) =
            tryCalculate(cashPrincipal, buyerParticipantType, sellerParticipantType, config);
        if (status == CalculationStatus.SUCCESS) {
            return (buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit);
        }
        if (status == CalculationStatus.INVALID_CONFIG) revert HTPErrors.InvalidFeeConfig();
        if (status == CalculationStatus.INVALID_BUYER_PARTICIPANT_TYPE) {
            revert HTPErrors.InvalidFeeParticipantType(buyerParticipantType);
        }
        if (status == CalculationStatus.INVALID_SELLER_PARTICIPANT_TYPE) {
            revert HTPErrors.InvalidFeeParticipantType(sellerParticipantType);
        }
        if (status == CalculationStatus.INVESTOR_RATE_OUT_OF_RANGE) {
            revert HTPErrors.FeeRateOutOfRange(ParticipantType.INVESTOR, config.investorRateBps);
        }
        if (status == CalculationStatus.MAKER_RATE_OUT_OF_RANGE) {
            revert HTPErrors.FeeRateOutOfRange(ParticipantType.MAKER, config.makerRateBps);
        }
        if (status == CalculationStatus.SELLER_FEE_EXCEEDS_PRINCIPAL) {
            revert HTPErrors.SellerFeeExceedsPrincipal(sellerFee, cashPrincipal);
        }
        if (status == CalculationStatus.AGGREGATE_FEE_EXCEEDS_PRINCIPAL) {
            revert HTPErrors.AggregateFeeExceedsPrincipal(buyerFee, sellerFee, cashPrincipal);
        }
        if (status == CalculationStatus.OVERFLOW) revert HTPErrors.FeeOverflow();
        revert HTPErrors.CashConservationMismatch();
    }

    // buyerDebit = P + buyerFee
    // sellerCredit = P - sellerFee
    // collectorCredit = buyerFee + sellerFee
    // ⇒ debit == credit + collector
    /// @dev Non-reverting fee calculation; returns status instead of reverting.
    function tryCalculate(
        uint256 cashPrincipal,
        ParticipantType buyerParticipantType,
        ParticipantType sellerParticipantType,
        FeeConfig memory config
    )
        internal
        pure
        returns (
            CalculationStatus status,
            uint256 buyerFee,
            uint256 sellerFee,
            uint256 buyerDebit,
            uint256 sellerCredit,
            uint256 collectorCredit
        )
    {
        if (config.roundingMode != RoundingMode.DOWN) {
            return (CalculationStatus.INVALID_CONFIG, 0, 0, 0, 0, 0);
        }
        if (!_isFeeParticipantType(buyerParticipantType)) {
            return (CalculationStatus.INVALID_BUYER_PARTICIPANT_TYPE, 0, 0, 0, 0, 0);
        }
        if (!_isFeeParticipantType(sellerParticipantType)) {
            return (CalculationStatus.INVALID_SELLER_PARTICIPANT_TYPE, 0, 0, 0, 0, 0);
        }
        if (config.investorRateBps > BPS_DENOMINATOR) {
            return (CalculationStatus.INVESTOR_RATE_OUT_OF_RANGE, 0, 0, 0, 0, 0);
        }
        if (config.makerRateBps > BPS_DENOMINATOR) {
            return (CalculationStatus.MAKER_RATE_OUT_OF_RANGE, 0, 0, 0, 0, 0);
        }

        buyerFee = _feeForParticipant(cashPrincipal, buyerParticipantType, config);
        sellerFee = _feeForParticipant(cashPrincipal, sellerParticipantType, config);

        if (sellerFee > cashPrincipal) {
            return (CalculationStatus.SELLER_FEE_EXCEEDS_PRINCIPAL, buyerFee, sellerFee, 0, 0, 0);
        }

        (bool buyerDebitSafe, uint256 computedBuyerDebit) = Math.tryAdd(cashPrincipal, buyerFee);
        (bool collectorCreditSafe, uint256 computedCollectorCredit) = Math.tryAdd(buyerFee, sellerFee);
        if (!buyerDebitSafe || !collectorCreditSafe) {
            return (CalculationStatus.OVERFLOW, buyerFee, sellerFee, 0, 0, 0);
        }

        if (computedCollectorCredit > cashPrincipal) {
            return (CalculationStatus.AGGREGATE_FEE_EXCEEDS_PRINCIPAL, buyerFee, sellerFee, 0, 0, 0);
        }
        buyerDebit = computedBuyerDebit;
        sellerCredit = cashPrincipal - sellerFee;
        collectorCredit = computedCollectorCredit;

        (bool conservationSafe, uint256 conservedCash) = Math.tryAdd(sellerCredit, collectorCredit);
        if (!conservationSafe) {
            return (CalculationStatus.OVERFLOW, buyerFee, sellerFee, buyerDebit, sellerCredit, collectorCredit);
        }

        if (buyerDebit != conservedCash) {
            return
                (
                    CalculationStatus.CONSERVATION_MISMATCH,
                    buyerFee,
                    sellerFee,
                    buyerDebit,
                    sellerCredit,
                    collectorCredit
                );
        }
        status = CalculationStatus.SUCCESS;
    }

    function _feeForParticipant(uint256 cashPrincipal, ParticipantType participantType, FeeConfig memory config)
        private
        pure
        returns (uint256 fee)
    {
        uint16 rateBps;
        bool hasCap;
        uint256 capAmount;
        if (participantType == ParticipantType.INVESTOR) {
            rateBps = config.investorRateBps;
            hasCap = config.investorHasCap;
            capAmount = config.investorCapAmount;
        } else {
            rateBps = config.makerRateBps;
            hasCap = config.makerHasCap;
            capAmount = config.makerCapAmount;
        }
        fee = Math.mulDiv(cashPrincipal, rateBps, BPS_DENOMINATOR);
        if (hasCap && fee > capAmount) fee = capAmount;
    }

    function _isFeeParticipantType(ParticipantType participantType) private pure returns (bool) {
        return participantType == ParticipantType.INVESTOR || participantType == ParticipantType.MAKER;
    }
}
