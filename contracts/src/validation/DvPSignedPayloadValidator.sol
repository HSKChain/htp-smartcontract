// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IDvPSettlement} from "../interfaces/IDvPSettlement.sol";
import {IDvPSignedPayloadValidator} from "../interfaces/IDvPSignedPayloadValidator.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {ProtocolSecurityLimits} from "../libraries/ProtocolSecurityLimits.sol";
import {SettlementCoherenceResult, SettlementParamsValidation} from "../libraries/SettlementParamsValidation.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {Decision, NonceCancellation, SettlementParams} from "../types/HTPTypes.sol";

/// @notice Validates EIP-712 signatures and hash coherence for settlement params.
contract DvPSignedPayloadValidator is IDvPSignedPayloadValidator {
    address private immutable DVP;

    struct ValidationFailure {
        bytes4 reason;
        bytes32 expected;
        bytes32 actual;
        bytes32 field;
        address signer;
        uint256 chainId;
        address dvp;
    }

    constructor(address dvp) {
        DVP = dvp;
    }

    /// @notice Non-reverting signed-payload check for diagnostics.
    function preCheck(SettlementParams calldata params)
        external
        view
        override
        onlyDvp
        returns (Decision decision, bytes4 reason)
    {
        ValidationFailure memory failure = _check(params, true);
        if (failure.reason == bytes4(0)) return (Decision.PASS, bytes4(0));
        decision = failure.reason == HTPErrors.ExternalCallFailed.selector ? Decision.UNKNOWN : Decision.BLOCK;
        return (decision, failure.reason);
    }

    /// @notice Strict validation before settlement transfers.
    function validateForSettlement(SettlementParams calldata params) external view override onlyDvp {
        ValidationFailure memory failure = _check(params, false);
        if (failure.reason != bytes4(0)) _revertFailure(failure);
    }

    function validateNonceCancellation(NonceCancellation calldata cancellation, bytes calldata signature)
        external
        view
        override
        onlyDvp
    {
        bytes32 digest = HTPHashing.hashNonceCancellationDigest(IDvPSettlement(DVP).domainSeparatorV4(), cancellation);
        ValidationFailure memory failure = _checkSignature(cancellation.signer, digest, signature, false);
        if (failure.reason != bytes4(0)) _revertFailure(failure);
    }

    modifier onlyDvp() {
        if (msg.sender != DVP) revert HTPErrors.InvalidChainOrContract(block.chainid, msg.sender);
        _;
    }

    function _check(SettlementParams calldata params, bool reportExternalUncertainty)
        private
        view
        returns (ValidationFailure memory failure)
    {
        SettlementCoherenceResult memory coherence = SettlementParamsValidation.inspect(params);
        if (coherence.invalidField != bytes32(0)) return _invalidField(coherence.invalidField);
        if (block.chainid != params.snapshot.chainId || params.snapshot.dvpContract != DVP) {
            failure.reason = HTPErrors.InvalidChainOrContract.selector;
            failure.chainId = params.snapshot.chainId;
            failure.dvp = params.snapshot.dvpContract;
            return failure;
        }

        bytes32 domainSeparator = IDvPSettlement(DVP).domainSeparatorV4();
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(domainSeparator, params.firmQuote);

        if (params.tradeIntent.quoteHash != quoteDigest) {
            return _hashFailure(HTPErrors.QuoteHashMismatch.selector, quoteDigest, params.tradeIntent.quoteHash);
        }

        if (params.snapshot.quoteHash != quoteDigest) {
            return _hashFailure(HTPErrors.QuoteHashMismatch.selector, quoteDigest, params.snapshot.quoteHash);
        }

        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);

        if (params.tradeIntent.snapshotHash != snapshotHash) {
            return _hashFailure(HTPErrors.SnapshotHashMismatch.selector, snapshotHash, params.tradeIntent.snapshotHash);
        }

        failure = _checkSignature(
            params.firmQuote.quotingMaker, quoteDigest, params.quotingMakerSignature, reportExternalUncertainty
        );
        if (failure.reason != bytes4(0)) return failure;
        failure = _checkSignature(
            params.tradeIntent.requester,
            HTPHashing.hashTradeIntentDigest(domainSeparator, params.tradeIntent),
            params.requesterSignature,
            reportExternalUncertainty
        );
    }

    function _checkSignature(address signer, bytes32 digest, bytes calldata signature, bool reportExternalUncertainty)
        private
        view
        returns (ValidationFailure memory failure)
    {
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(digest, signature);
            if (recoverError != ECDSA.RecoverError.NoError || recovered != signer) {
                failure.reason = HTPErrors.InvalidSignature.selector;
                failure.signer = signer;
            }
            return failure;
        }

        (bool callSucceeded, bool returnWellFormed, bytes32 result) = BoundedStaticCall.staticCallWordStatus(
            signer,
            abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature),
            ProtocolSecurityLimits.ERC1271_CALL_GAS
        );
        if (!callSucceeded || !returnWellFormed) {
            failure.reason =
                reportExternalUncertainty ? HTPErrors.ExternalCallFailed.selector : HTPErrors.InvalidSignature.selector;
            failure.signer = signer;
            failure.expected = bytes32(IERC1271.isValidSignature.selector);
            return failure;
        }
        if (bytes4(result) != IERC1271.isValidSignature.selector) {
            failure.reason = HTPErrors.InvalidSignature.selector;
            failure.signer = signer;
        }
    }

    function _revertFailure(ValidationFailure memory failure) private pure {
        if (failure.reason == HTPErrors.InvalidChainOrContract.selector) {
            revert HTPErrors.InvalidChainOrContract(failure.chainId, failure.dvp);
        }
        if (failure.reason == HTPErrors.QuoteHashMismatch.selector) {
            revert HTPErrors.QuoteHashMismatch(failure.expected, failure.actual);
        }
        if (failure.reason == HTPErrors.SnapshotHashMismatch.selector) {
            revert HTPErrors.SnapshotHashMismatch(failure.expected, failure.actual);
        }
        if (failure.reason == HTPErrors.InvalidSettlementParams.selector) {
            revert HTPErrors.InvalidSettlementParams(failure.field);
        }
        if (failure.reason == HTPErrors.InvalidSignature.selector) {
            revert HTPErrors.InvalidSignature(failure.signer);
        }
        if (failure.reason == HTPErrors.ExternalCallFailed.selector) {
            revert HTPErrors.ExternalCallFailed(bytes4(failure.expected));
        }
        revert HTPErrors.InvalidSettlementParams(bytes32("signedPayload"));
    }

    function _hashFailure(bytes4 reason, bytes32 expected, bytes32 actual)
        private
        pure
        returns (ValidationFailure memory failure)
    {
        failure.reason = reason;
        failure.expected = expected;
        failure.actual = actual;
    }

    function _invalidField(bytes32 field) private pure returns (ValidationFailure memory failure) {
        failure.reason = HTPErrors.InvalidSettlementParams.selector;
        failure.field = field;
    }
}
