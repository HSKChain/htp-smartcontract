// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPSettlement} from "../interfaces/IDvPSettlement.sol";
import {IDvPCurrentStateValidator} from "../interfaces/IDvPCurrentStateValidator.sol";
import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {IParticipantRegistry} from "../interfaces/IParticipantRegistry.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    Decision,
    NonceStatus,
    NonceType,
    ParticipantRecord,
    ParticipantStatus,
    ParticipantType,
    PermitCapability,
    PermitData
} from "../types/HTPTypes.sol";

struct SettlementFailureContext {
    uint256 chainId;
    address dvpContract;
    uint64 feePolicyEpoch;
    bytes32 assetVersionId;
    bytes32 settlementTokenConfigId;
    bytes32 adapterConfigId;
    bytes32 principalCalculatorConfigId;
    bytes32 feeVersionId;
    bytes32 marketRuleConfigId;
    // N11: Values required to preserve deterministic market-rule reverts.
    uint256 marketRuleQuotedPrice;
    uint256 marketRulePriceTick;
    uint256 cashPrincipal;
    uint256 marketRuleMinCashPrincipal;
}

/// @notice Maps validator failures to structured reverts and enforces participant/nonce gates.
contract StrictSettlementFailureMapper {
    uint256 private constant REGISTRY_GAS_LIMIT = 300_000;

    bytes4 private constant DECIMALS_SELECTOR = 0x313ce567;

    /// @notice Reverts with HTPErrors matching a validation reason and context.
    function revertFailure(bytes4 reason, bytes4 externalSelector, SettlementFailureContext calldata context)
        external
        pure
    {
        if (reason == HTPErrors.InvalidSettlementParams.selector) {
            revert HTPErrors.InvalidSettlementParams(bytes32("currentState"));
        }
        if (reason == HTPErrors.InvalidChainOrContract.selector) {
            revert HTPErrors.InvalidChainOrContract(context.chainId, context.dvpContract);
        }
        if (reason == HTPErrors.InvalidQuantityRange.selector) revert HTPErrors.InvalidQuantityRange();
        if (reason == HTPErrors.InvalidQuantityStep.selector) revert HTPErrors.InvalidQuantityStep();
        if (reason == HTPErrors.InvalidSettlementTimeWindow.selector) {
            revert HTPErrors.InvalidSettlementTimeWindow();
        }
        if (reason == HTPErrors.AssetVersionInactive.selector) {
            revert HTPErrors.AssetVersionInactive(context.assetVersionId);
        }
        if (reason == HTPErrors.SettlementTokenInactive.selector) {
            revert HTPErrors.SettlementTokenInactive(context.settlementTokenConfigId);
        }
        if (reason == HTPErrors.AdapterInactive.selector) {
            revert HTPErrors.AdapterInactive(context.adapterConfigId);
        }
        if (reason == HTPErrors.CalculatorInactive.selector) {
            revert HTPErrors.CalculatorInactive(context.principalCalculatorConfigId);
        }
        if (reason == HTPErrors.FeeSnapshotMismatch.selector) {
            revert HTPErrors.FeeSnapshotMismatch(context.feeVersionId);
        }
        if (reason == HTPErrors.MarketRuleSnapshotMismatch.selector) {
            revert HTPErrors.MarketRuleSnapshotMismatch(context.marketRuleConfigId);
        }
        if (reason == HTPErrors.MarketRuleQuantityViolation.selector) {
            revert HTPErrors.MarketRuleQuantityViolation(context.marketRuleConfigId);
        }
        // N11: Do not misreport deterministic market-rule violations as calculator failures.
        if (reason == HTPErrors.MarketRulePriceTickViolation.selector) {
            revert HTPErrors.MarketRulePriceTickViolation(
                context.marketRuleConfigId, context.marketRuleQuotedPrice, context.marketRulePriceTick
            );
        }
        if (reason == HTPErrors.MarketRuleMinimumPrincipalViolation.selector) {
            revert HTPErrors.MarketRuleMinimumPrincipalViolation(
                context.marketRuleConfigId, context.cashPrincipal, context.marketRuleMinCashPrincipal
            );
        }
        if (reason == HTPErrors.FeeResolverNoMatch.selector) {
            revert HTPErrors.FeeResolverNoMatch(context.feePolicyEpoch, context.assetVersionId);
        }
        if (reason == HTPErrors.CashPrincipalZero.selector) revert HTPErrors.CashPrincipalZero();

        revert HTPErrors.ExternalCallFailed(externalSelector == bytes4(0)
                ? IDvPCurrentStateValidator.validateForSettlement.selector
                : externalSelector);
    }

    /// @notice Ensures maker quote and requester trade nonces are still unused.
    function requireNonces(address dvp, address quotingMaker, uint256 quoteNonce, address requester, uint256 tradeNonce)
        external
        view
    {
        NonceStatus makerStatus = IDvPSettlement(dvp).getNonceStatus(quotingMaker, NonceType.MAKER_QUOTE, quoteNonce);
        if (makerStatus != NonceStatus.UNUSED) {
            revert HTPErrors.NonceUnavailable(quotingMaker, NonceType.MAKER_QUOTE, quoteNonce, makerStatus);
        }
        NonceStatus requesterStatus =
            IDvPSettlement(dvp).getNonceStatus(requester, NonceType.REQUESTER_TRADE, tradeNonce);
        if (requesterStatus != NonceStatus.UNUSED) {
            revert HTPErrors.NonceUnavailable(requester, NonceType.REQUESTER_TRADE, tradeNonce, requesterStatus);
        }
    }

    function validateParticipants(address dvp, address quotingMaker, address requester, ParticipantType requesterType)
        external
        view
        returns (Decision decision, bytes4 reason)
    {
        (decision, reason,) = _participantValidation(dvp, quotingMaker, requester, requesterType);
    }

    function requireParticipants(address dvp, address quotingMaker, address requester, ParticipantType requesterType)
        external
        view
    {
        (Decision decision, bytes4 reason, address inactiveWallet) =
            _participantValidation(dvp, quotingMaker, requester, requesterType);
        if (decision == Decision.PASS) return;
        if (decision == Decision.UNKNOWN) {
            revert HTPErrors.ExternalCallFailed(IParticipantRegistry.getParticipant.selector);
        }
        if (reason == HTPErrors.ParticipantInactive.selector) {
            revert HTPErrors.ParticipantInactive(inactiveWallet);
        }
        revert HTPErrors.ParticipantRelationshipInvalid(requesterType);
    }

    function validateEligibility(address dvp, address seller, address buyer, bytes32 assetVersionId)
        external
        view
        returns (Decision decision, bytes4 reason)
    {
        (decision, reason,) = _eligibilityValidation(dvp, seller, buyer, assetVersionId);
    }

    function requireEligibility(address dvp, address seller, address buyer, bytes32 assetVersionId) external view {
        (Decision decision, bytes4 reason, address wallet) = _eligibilityValidation(dvp, seller, buyer, assetVersionId);
        if (decision == Decision.PASS) return;
        if (decision == Decision.UNKNOWN) {
            revert HTPErrors.ExternalCallFailed(IEligibilityRegistry.isEligible.selector);
        }
        _revertEligibilityFailure(reason, wallet, assetVersionId);
    }

    function permitFailure(
        PermitData calldata permit,
        PermitCapability capability,
        address token,
        address owner,
        uint256 required,
        uint64 tradeDeadline
    ) external pure returns (bytes32) {
        return _permitFailure(permit, capability, token, owner, required, tradeDeadline);
    }

    function requirePermit(
        PermitData calldata permit,
        PermitCapability capability,
        address token,
        address owner,
        uint256 required,
        uint64 tradeDeadline
    ) external pure {
        bytes32 field = _permitFailure(permit, capability, token, owner, required, tradeDeadline);
        if (field == bytes32(0)) return;
        if (field == bytes32("capability")) revert HTPErrors.PermitUnsupported(token);
        revert HTPErrors.PermitFieldMismatch(token, field);
    }

    function revertTokenMetadataFailure(
        bytes4 reason,
        address assetToken,
        bytes32 expectedAssetCodeHash,
        address settlementToken,
        bytes32 expectedSettlementCodeHash
    ) external view {
        if (reason == HTPErrors.TokenCodeHashMismatch.selector) {
            if (assetToken.codehash != expectedAssetCodeHash) {
                revert HTPErrors.TokenCodeHashMismatch(assetToken, expectedAssetCodeHash, assetToken.codehash);
            }
            revert HTPErrors.TokenCodeHashMismatch(
                settlementToken, expectedSettlementCodeHash, settlementToken.codehash
            );
        }
        revert HTPErrors.ExternalCallFailed(DECIMALS_SELECTOR);
    }

    function _participantValidation(address dvp, address quotingMaker, address requester, ParticipantType requesterType)
        private
        view
        returns (Decision, bytes4, address inactiveWallet)
    {
        // N12: Reject an invalid relationship type before registry state can mask it as inactivity.
        if (requesterType != ParticipantType.INVESTOR && requesterType != ParticipantType.MAKER) {
            return (Decision.BLOCK, HTPErrors.ParticipantRelationshipInvalid.selector, address(0));
        }
        IParticipantRegistry registry = IDvPSettlement(dvp).participantRegistry();
        ParticipantRecord memory maker;
        ParticipantRecord memory requesterRecord;
        try registry.getParticipant{gas: REGISTRY_GAS_LIMIT}(quotingMaker) returns (ParticipantRecord memory value) {
            maker = value;
        } catch {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector, address(0));
        }
        try registry.getParticipant{gas: REGISTRY_GAS_LIMIT}(requester) returns (ParticipantRecord memory value) {
            requesterRecord = value;
        } catch {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector, address(0));
        }
        if (!_participantActive(maker, quotingMaker, ParticipantType.MAKER)) {
            return (Decision.BLOCK, HTPErrors.ParticipantInactive.selector, quotingMaker);
        }
        if (!_participantActive(requesterRecord, requester, requesterType)) {
            return (Decision.BLOCK, HTPErrors.ParticipantInactive.selector, requester);
        }
        return (Decision.PASS, bytes4(0), address(0));
    }

    function _eligibilityValidation(address dvp, address seller, address buyer, bytes32 assetVersionId)
        private
        view
        returns (Decision, bytes4, address wallet)
    {
        IEligibilityRegistry eligibility = IDvPSettlement(dvp).eligibilityRegistry();
        try eligibility.isEligible{gas: REGISTRY_GAS_LIMIT}(seller, assetVersionId) returns (
            bool allowed, bytes4 reason
        ) {
            if (!allowed) {
                return (Decision.BLOCK, reason == bytes4(0) ? HTPErrors.EligibilityNotPassed.selector : reason, seller);
            }
        } catch {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector, address(0));
        }
        try eligibility.isEligible{gas: REGISTRY_GAS_LIMIT}(buyer, assetVersionId) returns (
            bool allowed, bytes4 reason
        ) {
            if (!allowed) {
                return (Decision.BLOCK, reason == bytes4(0) ? HTPErrors.EligibilityNotPassed.selector : reason, buyer);
            }
        } catch {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector, address(0));
        }
        return (Decision.PASS, bytes4(0), address(0));
    }

    function _revertEligibilityFailure(bytes4 reason, address wallet, bytes32 assetVersionId) private view {
        bytes32 eligibilityKey = keccak256(abi.encode(block.chainid, wallet, assetVersionId));
        if (reason == HTPErrors.InvalidEligibilityInput.selector) revert HTPErrors.InvalidEligibilityInput();
        if (reason == HTPErrors.EligibilityNotFound.selector) {
            revert HTPErrors.EligibilityNotFound(eligibilityKey);
        }
        if (reason == HTPErrors.EligibilityPausedOrRevoked.selector) {
            revert HTPErrors.EligibilityPausedOrRevoked(eligibilityKey);
        }
        if (reason == HTPErrors.EligibilityExpired.selector) {
            revert HTPErrors.EligibilityExpired(eligibilityKey);
        }
        revert HTPErrors.EligibilityNotPassed(eligibilityKey);
    }

    function _permitFailure(
        PermitData calldata permit,
        PermitCapability capability,
        address token,
        address owner,
        uint256 required,
        uint64 tradeDeadline
    ) private pure returns (bytes32) {
        if (!permit.usePermit) return bytes32(0);
        if (capability != PermitCapability.EIP2612) return bytes32("capability");
        if (permit.owner != owner) return bytes32("owner");
        if (permit.token != token) return bytes32("token");
        if (permit.value != required) return bytes32("value");
        if (permit.deadline != tradeDeadline) return bytes32("deadline");
        if ((permit.v != 27 && permit.v != 28) || permit.r == bytes32(0) || permit.s == bytes32(0)) {
            return bytes32("signature");
        }
        return bytes32(0);
    }

    function _participantActive(ParticipantRecord memory record, address wallet, ParticipantType expectedType)
        private
        view
        returns (bool)
    {
        return record.wallet == wallet && record.version != 0 && record.participantType == expectedType
            && record.status == ParticipantStatus.ACTIVE && record.validUntil > block.timestamp;
    }
}
