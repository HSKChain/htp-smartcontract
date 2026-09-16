// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPTypes, RequesterSide, SettlementParams} from "../types/HTPTypes.sol";

struct SettlementCoherenceResult {
    bytes32 invalidField;
    address buyer;
    address seller;
}

library SettlementParamsValidation {
    /// @notice Returns true when settlement params contain required non-zero fields and schema version.
    function hasRequiredStructure(SettlementParams calldata params) internal pure returns (bool) {
        return params.firmQuote.schemaVersion == HTPTypes.SCHEMA_VERSION
            && params.tradeIntent.schemaVersion == HTPTypes.SCHEMA_VERSION
            && params.snapshot.schemaVersion == HTPTypes.SCHEMA_VERSION && params.firmQuote.quotingMaker != address(0)
            && params.firmQuote.requester != address(0) && params.firmQuote.assetToken != address(0)
            && params.firmQuote.settlementToken != address(0) && params.firmQuote.assetVersionId != bytes32(0)
            && params.tradeIntent.tradeIdHash != bytes32(0) && params.tradeIntent.buyer != address(0)
            && params.tradeIntent.seller != address(0) && params.tradeIntent.collector != address(0)
            && params.snapshot.principalCalculatorConfigId != bytes32(0)
            && params.snapshot.principalCalculatorConfigHash != bytes32(0)
            && params.snapshot.adapterConfigId != bytes32(0) && params.snapshot.adapterConfigHash != bytes32(0)
            && params.snapshot.settlementTokenConfigId != bytes32(0)
            && params.snapshot.settlementTokenConfigHash != bytes32(0)
            && params.snapshot.marketRuleConfigId != bytes32(0) && params.snapshot.marketRuleConfigHash != bytes32(0)
            && params.snapshot.feeVersionId != bytes32(0) && params.snapshot.matchedScopeHash != bytes32(0)
            && params.snapshot.feeConstraintHash != bytes32(0);
    }

    /// @notice Checks cross-layer field coherence and derives buyer/seller when valid.
    function inspect(SettlementParams calldata params) internal pure returns (SettlementCoherenceResult memory result) {
        if (!hasRequiredStructure(params)) {
            result.invalidField = bytes32("required");
            return result;
        }

        if (params.firmQuote.expiresAt != params.snapshot.quoteExpiresAt) {
            result.invalidField = bytes32("quoteExpiresAt");
            return result;
        }

        if (params.tradeIntent.deadline != params.snapshot.tradeDeadline) {
            result.invalidField = bytes32("tradeDeadline");
            return result;
        }

        result.invalidField = _repeatedFieldFailure(params);
        if (result.invalidField != bytes32(0)) return result;
        return deriveParties(params);
    }

    function deriveParties(SettlementParams calldata params)
        internal
        pure
        returns (SettlementCoherenceResult memory result)
    {
        if (params.firmQuote.requesterSide == RequesterSide.BUY) {
            result.buyer = params.firmQuote.requester;
            result.seller = params.firmQuote.quotingMaker;
        } else if (params.firmQuote.requesterSide == RequesterSide.SELL) {
            result.buyer = params.firmQuote.quotingMaker;
            result.seller = params.firmQuote.requester;
        } else {
            result.invalidField = bytes32("requesterSide");
            return result;
        }
        if (params.tradeIntent.buyer != result.buyer || params.snapshot.buyer != result.buyer) {
            result.invalidField = bytes32("buyer");
            return result;
        }
        if (params.tradeIntent.seller != result.seller || params.snapshot.seller != result.seller) {
            result.invalidField = bytes32("seller");
            return result;
        }
    }

    function _repeatedFieldFailure(SettlementParams calldata params) private pure returns (bytes32) {
        if (
            params.firmQuote.schemaVersion != params.tradeIntent.schemaVersion
                || params.tradeIntent.schemaVersion != params.snapshot.schemaVersion
        ) return bytes32("schemaVersion");
        if (params.tradeIntent.tradeIdHash != params.snapshot.tradeIdHash) return bytes32("tradeIdHash");
        if (
            params.firmQuote.requester != params.tradeIntent.requester
                || params.tradeIntent.requester != params.snapshot.requester
        ) return bytes32("requester");
        if (
            params.firmQuote.requesterType != params.tradeIntent.requesterType
                || params.tradeIntent.requesterType != params.snapshot.requesterType
        ) return bytes32("requesterType");
        if (
            params.firmQuote.quotingMaker != params.tradeIntent.quotingMaker
                || params.tradeIntent.quotingMaker != params.snapshot.quotingMaker
        ) return bytes32("quotingMaker");
        if (
            params.firmQuote.requesterSide != params.tradeIntent.requesterSide
                || params.tradeIntent.requesterSide != params.snapshot.requesterSide
        ) return bytes32("requesterSide");
        if (params.tradeIntent.buyer != params.snapshot.buyer) return bytes32("buyer");
        if (params.tradeIntent.seller != params.snapshot.seller) return bytes32("seller");
        if (
            params.firmQuote.assetVersionId != params.tradeIntent.assetVersionId
                || params.tradeIntent.assetVersionId != params.snapshot.assetVersionId
        ) return bytes32("assetVersionId");
        if (
            params.firmQuote.assetToken != params.tradeIntent.assetToken
                || params.tradeIntent.assetToken != params.snapshot.assetToken
        ) return bytes32("assetToken");
        if (
            params.firmQuote.settlementToken != params.tradeIntent.settlementToken
                || params.tradeIntent.settlementToken != params.snapshot.settlementToken
        ) return bytes32("settlementToken");
        if (params.tradeIntent.executedQuantity != params.snapshot.executedQuantity) {
            return bytes32("executedQuantity");
        }
        if (
            params.firmQuote.assetClass != params.tradeIntent.assetClass
                || params.tradeIntent.assetClass != params.snapshot.assetClass
        ) return bytes32("assetClass");
        if (
            params.firmQuote.priceTermsHash != params.tradeIntent.priceTermsHash
                || params.tradeIntent.priceTermsHash != params.snapshot.priceTermsHash
        ) return bytes32("priceTermsHash");

        if (
            keccak256(params.firmQuote.priceData) != keccak256(params.tradeIntent.priceData)
                || keccak256(params.tradeIntent.priceData) != keccak256(params.snapshot.priceData)
        ) return bytes32("priceData");
        if (
            params.firmQuote.principalCalculatorConfigId != params.tradeIntent.principalCalculatorConfigId
                || params.tradeIntent.principalCalculatorConfigId != params.snapshot.principalCalculatorConfigId
        ) return bytes32("principalCalculatorConfigId");
        if (
            params.firmQuote.principalCalculatorConfigHash != params.tradeIntent.principalCalculatorConfigHash
                || params.tradeIntent.principalCalculatorConfigHash != params.snapshot.principalCalculatorConfigHash
        ) return bytes32("principalCalculatorConfigHash");
        if (
            params.firmQuote.adapterConfigId != params.tradeIntent.adapterConfigId
                || params.tradeIntent.adapterConfigId != params.snapshot.adapterConfigId
        ) return bytes32("adapterConfigId");
        if (
            params.firmQuote.adapterConfigHash != params.tradeIntent.adapterConfigHash
                || params.tradeIntent.adapterConfigHash != params.snapshot.adapterConfigHash
        ) return bytes32("adapterConfigHash");
        if (
            params.firmQuote.settlementTokenConfigId != params.tradeIntent.settlementTokenConfigId
                || params.tradeIntent.settlementTokenConfigId != params.snapshot.settlementTokenConfigId
        ) return bytes32("settlementTokenConfigId");
        if (
            params.firmQuote.settlementTokenConfigHash != params.tradeIntent.settlementTokenConfigHash
                || params.tradeIntent.settlementTokenConfigHash != params.snapshot.settlementTokenConfigHash
        ) return bytes32("settlementTokenConfigHash");
        if (
            params.firmQuote.marketRuleConfigId != params.tradeIntent.marketRuleConfigId
                || params.tradeIntent.marketRuleConfigId != params.snapshot.marketRuleConfigId
        ) return bytes32("marketRuleConfigId");
        if (
            params.firmQuote.marketRuleConfigHash != params.tradeIntent.marketRuleConfigHash
                || params.tradeIntent.marketRuleConfigHash != params.snapshot.marketRuleConfigHash
        ) return bytes32("marketRuleConfigHash");
        if (params.tradeIntent.cashPrincipal != params.snapshot.cashPrincipal) return bytes32("cashPrincipal");
        if (params.tradeIntent.buyerFee != params.snapshot.buyerFee) return bytes32("buyerFee");
        if (params.tradeIntent.sellerFee != params.snapshot.sellerFee) return bytes32("sellerFee");
        if (params.tradeIntent.buyerDebit != params.snapshot.buyerDebit) return bytes32("buyerDebit");
        if (params.tradeIntent.sellerCredit != params.snapshot.sellerCredit) return bytes32("sellerCredit");
        if (params.tradeIntent.collectorCredit != params.snapshot.collectorCredit) return bytes32("collectorCredit");
        if (params.tradeIntent.collector != params.snapshot.collector) return bytes32("collector");
        if (
            params.firmQuote.feePolicyEpoch != params.tradeIntent.feePolicyEpoch
                || params.tradeIntent.feePolicyEpoch != params.snapshot.feePolicyEpoch
        ) return bytes32("feePolicyEpoch");
        if (
            params.firmQuote.feeVersionId != params.tradeIntent.feeVersionId
                || params.tradeIntent.feeVersionId != params.snapshot.feeVersionId
        ) return bytes32("feeVersionId");
        if (
            params.firmQuote.matchedScopeHash != params.tradeIntent.matchedScopeHash
                || params.tradeIntent.matchedScopeHash != params.snapshot.matchedScopeHash
        ) return bytes32("matchedScopeHash");
        if (
            params.firmQuote.feeConstraintHash != params.tradeIntent.feeConstraintHash
                || params.tradeIntent.feeConstraintHash != params.snapshot.feeConstraintHash
        ) return bytes32("feeConstraintHash");
        if (params.tradeIntent.roundingMode != params.snapshot.roundingMode) return bytes32("roundingMode");

        if (params.firmQuote.quoteNonce != params.snapshot.makerQuoteNonce) return bytes32("quoteNonce");
        if (params.tradeIntent.tradeNonce != params.snapshot.requesterTradeNonce) return bytes32("tradeNonce");
        return bytes32(0);
    }
}
