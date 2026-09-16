// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPSettlement} from "../interfaces/IDvPSettlement.sol";
import {IDvPCurrentStateValidator} from "../interfaces/IDvPCurrentStateValidator.sol";
import {IPrincipalCalculator} from "../interfaces/IPrincipalCalculator.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {ProtocolSecurityLimits} from "../libraries/ProtocolSecurityLimits.sol";
import {SettlementCoherenceResult, SettlementParamsValidation} from "../libraries/SettlementParamsValidation.sol";
import {TokenMetadataValidation} from "../libraries/TokenMetadataValidation.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterRecord,
    AssetVersionRecord,
    Decision,
    FeeVersionRecord,
    NonceStatus,
    NonceType,
    ParticipantType,
    PermitCapability,
    PermitData,
    PrincipalCalculatorRecord,
    RequesterSide,
    SettlementParams,
    SettlementTokenRecord
} from "../types/HTPTypes.sol";
import {
    AdapterReferences,
    AssetReference,
    CalculatorReference,
    ConfigurationReferenceIntegrity,
    FeeReferences,
    MarketRuleQuantities,
    MarketRuleReferences,
    SettlementTokenReference
} from "./ConfigurationReferenceIntegrity.sol";
import {SettlementFailureContext, StrictSettlementFailureMapper} from "./StrictSettlementFailureMapper.sol";

/// @notice Validates live registry state, economics, and balances for settlement.
contract DvPCurrentStateValidator is IDvPCurrentStateValidator {
    uint256 private constant CALCULATOR_GAS_LIMIT = 100_000;
    uint256 private constant TOKEN_GAS_LIMIT = 30_000;
    // IERC20.allowance(owner, spender)
    bytes4 private constant ALLOWANCE_SELECTOR = 0xdd62ed3e;

    address private immutable DVP;
    ConfigurationReferenceIntegrity private immutable REFERENCE_INTEGRITY;
    StrictSettlementFailureMapper private immutable STRICT_FAILURE_MAPPER;

    struct ValidationContext {
        address buyer;
        address seller;
        AssetVersionRecord assetVersion;
        SettlementTokenRecord settlementToken;
        AdapterRecord assetAdapter;
        AdapterRecord settlementAdapter;
        PrincipalCalculatorRecord calculator;
        FeeVersionRecord feeVersion;
        uint256 marketRulePriceTick;
        uint256 marketRuleMinCashPrincipal;
    }

    constructor(
        address dvp,
        ConfigurationReferenceIntegrity referenceIntegrity,
        StrictSettlementFailureMapper strictFailureMapper
    ) {
        DVP = dvp;
        REFERENCE_INTEGRITY = referenceIntegrity;
        STRICT_FAILURE_MAPPER = strictFailureMapper;
    }

    /// @notice Non-reverting current-state check (participants, config, economics).
    function preCheck(SettlementParams calldata params)
        external
        view
        override
        returns (Decision decision, bytes4 reason, address assetAdapter, address settlementAdapter)
    {
        if (msg.sender != DVP) revert HTPErrors.InvalidChainOrContract(block.chainid, msg.sender);
        return _validate(params, true);
    }

    /// @notice Strict path used by DvP immediately before adapter transfers.
    function validateForSettlement(SettlementParams calldata params)
        external
        view
        override
        returns (address assetAdapter, address settlementAdapter, bytes32 settlementAdapterConfigId)
    {
        if (msg.sender != DVP) revert HTPErrors.InvalidChainOrContract(block.chainid, msg.sender);
        return _validateForSettlementStrict(params);
    }

    function _validate(SettlementParams calldata params, bool includeDiagnosticChecks)
        private
        view
        returns (Decision decision, bytes4 reason, address assetAdapter, address settlementAdapter)
    {
        ValidationContext memory context;
        (decision, reason) = _validateInputs(params, context);
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        (decision, reason) = _validateNonces(params);
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        (decision, reason) = STRICT_FAILURE_MAPPER.validateParticipants(
            DVP, params.firmQuote.quotingMaker, params.firmQuote.requester, params.firmQuote.requesterType
        );
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        (decision, reason) = _loadAndValidateConfiguration(params, context);
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        (decision, reason) = _validateTokenMetadata(params, context, true);
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        (decision, reason) = _validatePrincipalAndFees(params, context);
        if (decision != Decision.PASS) return (decision, reason, address(0), address(0));

        if (includeDiagnosticChecks) {
            (decision, reason) = _validateEligibilityAndAllowance(params, context);
            if (decision != Decision.PASS) return (decision, reason, address(0), address(0));
        }

        return (Decision.PASS, bytes4(0), context.assetAdapter.config.adapter, context.settlementAdapter.config.adapter);
    }

    function _validateForSettlementStrict(SettlementParams calldata params)
        private
        view
        returns (address assetAdapter, address settlementAdapter, bytes32 settlementAdapterConfigId)
    {
        ValidationContext memory context;
        (Decision decision, bytes4 reason) = _validateInputs(params, context);
        if (decision != Decision.PASS) _revertFailure(reason, bytes4(0), params);
        STRICT_FAILURE_MAPPER.requireNonces(
            DVP,
            params.firmQuote.quotingMaker,
            params.firmQuote.quoteNonce,
            params.tradeIntent.requester,
            params.tradeIntent.tradeNonce
        );
        STRICT_FAILURE_MAPPER.requireParticipants(
            DVP, params.firmQuote.quotingMaker, params.firmQuote.requester, params.firmQuote.requesterType
        );
        (decision, reason) = _loadAndValidateConfiguration(params, context);
        if (decision != Decision.PASS) {
            _revertFailure(reason, IDvPCurrentStateValidator.validateForSettlement.selector, params);
        }
        (decision, reason) = _validateTokenMetadata(params, context, false);
        if (decision != Decision.PASS) {
            STRICT_FAILURE_MAPPER.revertTokenMetadataFailure(
                reason,
                params.snapshot.assetToken,
                context.assetVersion.config.tokenCodeHash,
                params.snapshot.settlementToken,
                context.settlementToken.config.tokenCodeHash
            );
            revert HTPErrors.InvalidDvpValidator(address(STRICT_FAILURE_MAPPER));
        }
        (decision, reason) = _validatePrincipalAndFees(params, context);
        if (decision != Decision.PASS) {
            if (reason == HTPErrors.FeeConstraintHashMismatch.selector) {
                revert HTPErrors.FeeConstraintHashMismatch(
                    params.snapshot.feeConstraintHash, HTPHashing.hashFeeConstraint(context.feeVersion.config)
                );
            }
            _revertFailure(reason, IPrincipalCalculator.calculate.selector, params);
        }

        STRICT_FAILURE_MAPPER.requireEligibility(DVP, context.seller, context.buyer, params.snapshot.assetVersionId);

        _requireSettlementPermitFields(params, context);
        return (
            context.assetAdapter.config.adapter,
            context.settlementAdapter.config.adapter,
            context.settlementToken.config.adapterConfigId
        );
    }

    function _requireSettlementPermitFields(SettlementParams calldata params, ValidationContext memory context)
        private
        view
    {
        STRICT_FAILURE_MAPPER.requirePermit(
            params.assetPermit,
            context.assetVersion.config.assetPermitCapability,
            params.snapshot.assetToken,
            params.snapshot.seller,
            params.snapshot.executedQuantity,
            params.snapshot.tradeDeadline
        );
        STRICT_FAILURE_MAPPER.requirePermit(
            params.settlementPermit,
            context.settlementToken.config.permitCapability,
            params.snapshot.settlementToken,
            params.snapshot.buyer,
            params.snapshot.buyerDebit,
            params.snapshot.tradeDeadline
        );
    }

    function _validateInputs(SettlementParams calldata params, ValidationContext memory context)
        private
        view
        returns (Decision, bytes4)
    {
        if (!SettlementParamsValidation.hasRequiredStructure(params)) {
            return _block(HTPErrors.InvalidSettlementParams.selector);
        }
        if (params.snapshot.chainId != block.chainid || params.snapshot.dvpContract != DVP) {
            return _block(HTPErrors.InvalidChainOrContract.selector);
        }

        // Field equality stays in inspect(); inlining it here blew Factory past EIP-170.
        SettlementCoherenceResult memory coherence = SettlementParamsValidation.deriveParties(params);
        if (coherence.invalidField != bytes32(0)) {
            return _block(HTPErrors.InvalidSettlementParams.selector);
        }
        context.buyer = coherence.buyer;
        context.seller = coherence.seller;
        if (!_addressesAreDisjoint(params, context)) {
            return _block(HTPErrors.InvalidSettlementParams.selector);
        }

        bytes4 quantityFailure = _quantityFailureReason(params);
        if (quantityFailure != bytes4(0)) return _block(quantityFailure);
        if (
            params.snapshot.createdAt == 0 || params.snapshot.createdAt > block.timestamp
                || block.timestamp > params.snapshot.tradeDeadline
                || params.snapshot.tradeDeadline > params.snapshot.quoteExpiresAt
                || uint256(params.snapshot.tradeDeadline)
                    > uint256(params.snapshot.createdAt) + ProtocolSecurityLimits.MAX_QUOTE_LIFETIME
        ) return _block(HTPErrors.InvalidSettlementTimeWindow.selector);
        if (!_unusedPermitIsCanonical(params.assetPermit) || !_unusedPermitIsCanonical(params.settlementPermit)) {
            return _block(HTPErrors.InvalidSettlementParams.selector);
        }
        return _pass();
    }

    function _validateNonces(SettlementParams calldata params) private view returns (Decision, bytes4) {
        if (
            IDvPSettlement(DVP)
                        .getNonceStatus(
                            params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce
                        ) != NonceStatus.UNUSED
                || IDvPSettlement(DVP)
                        .getNonceStatus(
                            params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                        ) != NonceStatus.UNUSED
        ) return _block(HTPErrors.NonceUnavailable.selector);
        return _pass();
    }

    function _loadAndValidateConfiguration(SettlementParams calldata params, ValidationContext memory context)
        private
        view
        returns (Decision, bytes4)
    {
        AssetReference memory assetReference = AssetReference({
            assetVersionId: params.snapshot.assetVersionId,
            assetToken: params.snapshot.assetToken,
            assetDecimals: params.snapshot.assetDecimals,
            assetClass: params.snapshot.assetClass,
            principalCalculatorConfigId: params.snapshot.principalCalculatorConfigId,
            principalCalculatorConfigHash: params.snapshot.principalCalculatorConfigHash,
            adapterConfigId: params.snapshot.adapterConfigId,
            adapterConfigHash: params.snapshot.adapterConfigHash,
            settlementToken: params.snapshot.settlementToken,
            settlementTokenConfigId: params.snapshot.settlementTokenConfigId,
            settlementTokenConfigHash: params.snapshot.settlementTokenConfigHash,
            deploymentVersionHash: IDvPSettlement(DVP).deploymentVersionHash()
        });
        try REFERENCE_INTEGRITY.loadAssetVersion(DVP, assetReference) returns (
            AssetVersionRecord memory value, bool matches
        ) {
            if (!matches) return _block(HTPErrors.AssetVersionInactive.selector);
            context.assetVersion = value;
        } catch {
            return _externalUnknown();
        }

        SettlementTokenReference memory settlementTokenReference = SettlementTokenReference({
            configId: params.snapshot.settlementTokenConfigId,
            configHash: params.snapshot.settlementTokenConfigHash,
            token: params.snapshot.settlementToken,
            decimals: params.snapshot.settlementTokenDecimals
        });
        try REFERENCE_INTEGRITY.loadSettlementToken(DVP, settlementTokenReference) returns (
            SettlementTokenRecord memory value, bool matches
        ) {
            if (!matches) return _block(HTPErrors.SettlementTokenInactive.selector);
            context.settlementToken = value;
        } catch {
            return _externalUnknown();
        }

        AdapterReferences memory adapterReferences = AdapterReferences({
            assetConfigId: params.snapshot.adapterConfigId,
            assetConfigHash: params.snapshot.adapterConfigHash,
            settlementConfigId: context.settlementToken.config.adapterConfigId,
            settlementConfigHash: context.settlementToken.config.adapterConfigHash
        });
        try REFERENCE_INTEGRITY.loadAdapters(DVP, adapterReferences) returns (
            AdapterRecord memory assetAdapter, AdapterRecord memory settlementAdapter, bool serviceable
        ) {
            if (!serviceable) return _block(HTPErrors.AdapterInactive.selector);
            context.assetAdapter = assetAdapter;
            context.settlementAdapter = settlementAdapter;
        } catch {
            return _externalUnknown();
        }

        CalculatorReference memory calculatorReference = CalculatorReference({
            configId: params.snapshot.principalCalculatorConfigId,
            configHash: params.snapshot.principalCalculatorConfigHash,
            assetClass: params.snapshot.assetClass
        });
        try REFERENCE_INTEGRITY.loadCalculator(DVP, calculatorReference) returns (
            PrincipalCalculatorRecord memory value, bool serviceable
        ) {
            if (!serviceable) return _block(HTPErrors.CalculatorInactive.selector);
            context.calculator = value;
        } catch {
            return _externalUnknown();
        }

        MarketRuleReferences memory marketRuleReferences = MarketRuleReferences({
            configId: params.snapshot.marketRuleConfigId,
            configHash: params.snapshot.marketRuleConfigHash,
            assetVersionId: params.snapshot.assetVersionId,
            settlementToken: params.snapshot.settlementToken,
            settlementTokenConfigId: params.snapshot.settlementTokenConfigId,
            settlementTokenConfigHash: params.snapshot.settlementTokenConfigHash,
            createdAt: params.snapshot.createdAt,
            quoteExpiresAt: params.snapshot.quoteExpiresAt,
            tradeDeadline: params.snapshot.tradeDeadline
        });
        MarketRuleQuantities memory marketRuleQuantities = MarketRuleQuantities({
            minimum: params.firmQuote.minExecutableQuantity,
            maximum: params.firmQuote.maxExecutableQuantity,
            step: params.firmQuote.stepQuantity,
            executed: params.snapshot.executedQuantity
        });
        try REFERENCE_INTEGRITY.validateMarketRule(DVP, marketRuleReferences, marketRuleQuantities) returns (
            bytes4 failureReason, uint256 priceTick, uint256 minCashPrincipal
        ) {
            if (failureReason != bytes4(0)) return _block(failureReason);
            context.marketRulePriceTick = priceTick;
            context.marketRuleMinCashPrincipal = minCashPrincipal;
        } catch {
            return _externalUnknown();
        }

        FeeReferences memory feeReferences = FeeReferences({
            policyEpoch: params.snapshot.feePolicyEpoch,
            versionId: params.snapshot.feeVersionId,
            matchedScopeHash: params.snapshot.matchedScopeHash,
            constraintHash: params.snapshot.feeConstraintHash,
            settlementToken: params.snapshot.settlementToken,
            settlementTokenConfigId: params.snapshot.settlementTokenConfigId,
            settlementTokenConfigHash: params.snapshot.settlementTokenConfigHash,
            collector: params.snapshot.collector,
            roundingMode: params.snapshot.roundingMode,
            createdAt: params.snapshot.createdAt,
            tradeDeadline: params.snapshot.tradeDeadline,
            quoteExpiresAt: params.snapshot.quoteExpiresAt
        });
        try REFERENCE_INTEGRITY.loadFee(DVP, params.snapshot.assetVersionId, feeReferences) returns (
            FeeVersionRecord memory value, bytes4 failureReason
        ) {
            if (failureReason != bytes4(0)) return _block(failureReason);
            context.feeVersion = value;
        } catch {
            return _externalUnknown();
        }
        return _pass();
    }

    function _validateTokenMetadata(SettlementParams calldata params, ValidationContext memory context, bool isPreCheck)
        private
        view
        returns (Decision, bytes4)
    {
        if (!TokenMetadataValidation.deploymentBaselineMatches(
                params.snapshot.assetToken,
                context.assetVersion.config.tokenDeploymentKind,
                context.assetVersion.config.tokenCodeHash,
                context.assetVersion.config.implementation,
                context.assetVersion.config.implementationCodeHash
            )) return _block(HTPErrors.TokenCodeHashMismatch.selector);
        if (!TokenMetadataValidation.deploymentBaselineMatches(
                params.snapshot.settlementToken,
                context.settlementToken.config.tokenDeploymentKind,
                context.settlementToken.config.tokenCodeHash,
                context.settlementToken.config.implementation,
                context.settlementToken.config.implementationCodeHash
            )) return _block(HTPErrors.TokenCodeHashMismatch.selector);

        (bool assetDecimalsValid, uint256 assetDecimals) =
            TokenMetadataValidation.readDecimals(params.snapshot.assetToken);
        if (!assetDecimalsValid) {
            if (isPreCheck) return _externalUnknown();
            revert HTPErrors.AssetDecimalsMismatch(
                params.snapshot.assetToken, context.assetVersion.config.assetDecimals, assetDecimals
            );
        }
        if (
            assetDecimals != params.snapshot.assetDecimals || assetDecimals != context.assetVersion.config.assetDecimals
                || assetDecimals > 36
        ) {
            if (isPreCheck) return _block(HTPErrors.AssetDecimalsMismatch.selector);
            revert HTPErrors.AssetDecimalsMismatch(
                params.snapshot.assetToken, context.assetVersion.config.assetDecimals, assetDecimals
            );
        }

        (bool settlementDecimalsValid, uint256 settlementDecimals) =
            TokenMetadataValidation.readDecimals(params.snapshot.settlementToken);
        if (!settlementDecimalsValid) {
            if (isPreCheck) return _externalUnknown();
            revert HTPErrors.SettlementTokenDecimalsMismatch(
                params.snapshot.settlementToken,
                context.settlementToken.config.settlementTokenDecimals,
                settlementDecimals
            );
        }
        if (
            settlementDecimals != params.snapshot.settlementTokenDecimals
                || settlementDecimals != context.settlementToken.config.settlementTokenDecimals
        ) {
            if (isPreCheck) return _block(HTPErrors.SettlementTokenDecimalsMismatch.selector);
            revert HTPErrors.SettlementTokenDecimalsMismatch(
                params.snapshot.settlementToken,
                context.settlementToken.config.settlementTokenDecimals,
                settlementDecimals
            );
        }
        return _pass();
    }

    function _validatePrincipalAndFees(SettlementParams calldata params, ValidationContext memory context)
        private
        view
        returns (Decision, bytes4)
    {
        (
            bool calculatorCallSucceeded,
            bool calculatorReturnWellFormed,
            bytes32 calculatedPriceTermsHash,
            bytes32 quotedPriceWord,
            bytes32 unitCashPriceWord,
            bytes32 cashPrincipalWord
        ) = BoundedStaticCall.staticCallFourWordsStatus(
            context.calculator.config.calculator,
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            CALCULATOR_GAS_LIMIT
        );
        if (!calculatorCallSucceeded || !calculatorReturnWellFormed) {
            return _externalUnknown();
        }
        if (
            calculatedPriceTermsHash != params.snapshot.priceTermsHash || uint256(quotedPriceWord) == 0
                || uint256(unitCashPriceWord) == 0 || uint256(cashPrincipalWord) == 0
                || uint256(cashPrincipalWord) != params.snapshot.cashPrincipal
        ) return _block(HTPErrors.CashPrincipalZero.selector);
        if (uint256(quotedPriceWord) % context.marketRulePriceTick != 0) {
            return _block(HTPErrors.MarketRulePriceTickViolation.selector);
        }
        if (uint256(cashPrincipalWord) < context.marketRuleMinCashPrincipal) {
            return _block(HTPErrors.MarketRuleMinimumPrincipalViolation.selector);
        }

        if (
            context.feeVersion.config.feeConstraintHash != params.snapshot.feeConstraintHash
                || HTPHashing.hashFeeConstraint(context.feeVersion.config) != params.snapshot.feeConstraintHash
        ) return _block(HTPErrors.FeeConstraintHashMismatch.selector);

        if (!_feeAmountsMatch(params, context.feeVersion)) {
            return _block(HTPErrors.FeeSnapshotMismatch.selector);
        }
        return _pass();
    }

    function _validateEligibilityAndAllowance(SettlementParams calldata params, ValidationContext memory context)
        private
        view
        returns (Decision, bytes4)
    {
        (Decision eligibilityDecision, bytes4 eligibilityReason) = STRICT_FAILURE_MAPPER.validateEligibility(
            DVP, context.seller, context.buyer, params.snapshot.assetVersionId
        );
        if (eligibilityDecision != Decision.PASS) return (eligibilityDecision, eligibilityReason);

        (Decision assetDecision, bytes4 assetReason) = _validateAllowance(
            params.snapshot.assetToken,
            context.seller,
            params.snapshot.executedQuantity,
            params.assetPermit,
            context.assetVersion.config.assetPermitCapability,
            params.snapshot.tradeDeadline
        );
        if (assetDecision != Decision.PASS) return (assetDecision, assetReason);
        return _validateAllowance(
            params.snapshot.settlementToken,
            context.buyer,
            params.snapshot.buyerDebit,
            params.settlementPermit,
            context.settlementToken.config.permitCapability,
            params.snapshot.tradeDeadline
        );
    }

    function _validateAllowance(
        address token,
        address owner,
        uint256 required,
        PermitData calldata permit,
        PermitCapability capability,
        uint64 tradeDeadline
    ) private view returns (Decision, bytes4) {
        if (
            STRICT_FAILURE_MAPPER.permitFailure(permit, capability, token, owner, required, tradeDeadline) != bytes32(0)
        ) {
            return _block(HTPErrors.InvalidSettlementParams.selector);
        }
        (bool allowanceValid, uint256 allowanceValue) =
            _readWord(token, abi.encodeWithSelector(ALLOWANCE_SELECTOR, owner, DVP), TOKEN_GAS_LIMIT);
        if (!allowanceValid) return _externalUnknown();
        if (allowanceValue >= required) return _pass();
        if (!permit.usePermit) return _block(HTPErrors.InsufficientAllowance.selector);
        return (Decision.UNKNOWN, HTPErrors.PermitSimulationRequired.selector);
    }

    function _revertFailure(bytes4 reason, bytes4 externalSelector, SettlementParams calldata params) private view {
        STRICT_FAILURE_MAPPER.revertFailure(
            reason,
            externalSelector,
            SettlementFailureContext({
                chainId: params.snapshot.chainId,
                dvpContract: params.snapshot.dvpContract,
                feePolicyEpoch: params.snapshot.feePolicyEpoch,
                assetVersionId: params.snapshot.assetVersionId,
                settlementTokenConfigId: params.snapshot.settlementTokenConfigId,
                adapterConfigId: params.snapshot.adapterConfigId,
                principalCalculatorConfigId: params.snapshot.principalCalculatorConfigId,
                feeVersionId: params.snapshot.feeVersionId,
                marketRuleConfigId: params.snapshot.marketRuleConfigId
            })
        );
        revert HTPErrors.InvalidDvpValidator(address(STRICT_FAILURE_MAPPER));
    }

    function _addressesAreDisjoint(SettlementParams calldata params, ValidationContext memory context)
        private
        view
        returns (bool)
    {
        address collector = params.snapshot.collector;
        address assetToken = params.snapshot.assetToken;
        address settlementToken = params.snapshot.settlementToken;
        if (
            context.buyer == context.seller || context.buyer == collector || context.seller == collector
                || assetToken == settlementToken
        ) return false;
        return context.buyer != DVP && context.seller != DVP && collector != DVP && assetToken != DVP
            && settlementToken != DVP && context.buyer != assetToken && context.buyer != settlementToken
            && context.seller != assetToken && context.seller != settlementToken && collector != assetToken
            && collector != settlementToken;
    }

    function _quantityFailureReason(SettlementParams calldata params) private pure returns (bytes4) {
        uint256 executed = params.snapshot.executedQuantity;
        uint256 minimum = params.firmQuote.minExecutableQuantity;
        uint256 maximum = params.firmQuote.maxExecutableQuantity;
        uint256 step = params.firmQuote.stepQuantity;
        if (executed == 0 || minimum == 0 || maximum < minimum || executed < minimum || executed > maximum) {
            return HTPErrors.InvalidQuantityRange.selector;
        }
        if (step == 0 || (executed - minimum) % step != 0) {
            return HTPErrors.InvalidQuantityStep.selector;
        }
        return bytes4(0);
    }

    function _feeAmountsMatch(SettlementParams calldata params, FeeVersionRecord memory fee)
        private
        pure
        returns (bool)
    {
        ParticipantType buyerParticipantType;
        ParticipantType sellerParticipantType;
        if (params.firmQuote.requesterSide == RequesterSide.BUY) {
            buyerParticipantType = params.firmQuote.requesterType;
            sellerParticipantType = ParticipantType.MAKER;
        } else if (params.firmQuote.requesterSide == RequesterSide.SELL) {
            buyerParticipantType = ParticipantType.MAKER;
            sellerParticipantType = params.firmQuote.requesterType;
        } else {
            return false;
        }
        (
            FeeMath.CalculationStatus status,
            uint256 buyerFee,
            uint256 sellerFee,
            uint256 buyerDebit,
            uint256 sellerCredit,
            uint256 collectorCredit
        ) = FeeMath.tryCalculate(params.snapshot.cashPrincipal, buyerParticipantType, sellerParticipantType, fee.config);
        return status == FeeMath.CalculationStatus.SUCCESS && buyerFee == params.snapshot.buyerFee
            && sellerFee == params.snapshot.sellerFee && buyerDebit == params.snapshot.buyerDebit
            && sellerCredit == params.snapshot.sellerCredit && collectorCredit == params.snapshot.collectorCredit;
    }

    function _readWord(address target, bytes memory callData, uint256 gasLimit)
        private
        view
        returns (bool valid, uint256 value)
    {
        (bool callSucceeded, bool returnWellFormed, bytes32 result) =
            BoundedStaticCall.staticCallWordStatus(target, callData, gasLimit);
        valid = callSucceeded && returnWellFormed;
        value = uint256(result);
    }

    function _unusedPermitIsCanonical(PermitData calldata permit) private pure returns (bool) {
        if (permit.usePermit) return true;
        return permit.owner == address(0) && permit.token == address(0) && permit.value == 0 && permit.deadline == 0
            && permit.v == 0 && permit.r == bytes32(0) && permit.s == bytes32(0);
    }

    function _pass() private pure returns (Decision, bytes4) {
        return (Decision.PASS, bytes4(0));
    }

    function _block(bytes4 reason) private pure returns (Decision, bytes4) {
        return (Decision.BLOCK, reason);
    }

    function _externalUnknown() private pure returns (Decision, bytes4) {
        return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
    }
}
