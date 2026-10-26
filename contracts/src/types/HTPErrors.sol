// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AssetClass,
    FeePolicyEpochStatus,
    MarketRuleStatus,
    NonceStatus,
    NonceType,
    ParticipantStatus,
    ParticipantType,
    PermitCapability,
    ReasonCode,
    ScopeType,
    TokenDeploymentKind
} from "./HTPTypes.sol";

/// @notice Namespace reserved for task-driven structured custom errors.
/// @dev Errors are added only by the behavior task whose public Red requires them.
library HTPErrors {
    error InvalidDvpRegistry(address registry);
    error InvalidDvpValidatorFactory(address factory);
    error InvalidDvpValidator(address validator);
    error InvalidRoleHolder(bytes32 role, address account);
    error LastDefaultAdminCannotBeRemoved(address account);
    error InvalidChainOrContract(uint256 chainId, address dvp);
    error ContractPaused();
    error ContractNotPaused();
    error RetiredContract();
    error InvalidNonceType(NonceType nonceType);
    error NonceUnavailable(address signer, NonceType nonceType, uint256 nonce, NonceStatus status);
    error InvalidSignature(address signer);
    error SignatureExpired(uint64 deadline);
    error InvalidSettlementParams(bytes32 field);
    error QuoteHashMismatch(bytes32 expected, bytes32 actual);
    error SnapshotHashMismatch(bytes32 expected, bytes32 actual);
    error QuoteAlreadyExecuted(bytes32 quoteHash);
    error SnapshotAlreadyExecuted(bytes32 snapshotHash);
    error TradeAlreadyExecuted(bytes32 tradeIdHash);
    error InvalidCalendarDate(uint32 date);
    error PriceDataMalformed(AssetClass assetClass);
    error AssetDecimalsOutOfRange(uint8 assetDecimals);
    error SettlementTokenDecimalsOutOfRange(uint8 settlementTokenDecimals);
    error CashPrincipalZero();
    error BondFullPriceOverflow(uint256 cleanPrice, uint256 accruedInterest);
    error InvalidDeploymentVersion();
    error InvalidFeeScope(ScopeType scopeType);
    error InvalidRestrictionProviderOrder(uint256 index);
    error EvidenceHashRequired();
    error InvalidDependentDvp(address dvp);
    error NoDependentDvpRegistered();
    error DependentDvpAlreadyRegistered(address dvp);
    error DependentDvpLimitReached(uint256 limit);
    error DependentDvpNotRegistered(address dvp);
    error DependentDvpAlreadyRetiredExempt(address dvp);
    error DependentDvpNotRetired(address dvp);
    error DependentDvpNotPaused(address dvp);
    error DependentDvpStatusMalformed(address dvp);
    error InvalidConfigIdentity();
    error ConfigIdMismatch(bytes32 expected, bytes32 actual);
    error ConfigHashMismatch(bytes32 expected, bytes32 actual);
    error ConfigAlreadyExists(bytes32 configId);
    error ConfigNotFound(bytes32 configId);
    error InvalidSchemaVersion(uint32 actual);
    error ConfigChainMismatch(uint256 expected, uint256 actual);
    error ConfigRevisionMismatch(bytes32 subject, uint32 expected, uint32 actual);
    error ConfigReplacesMismatch(bytes32 expected, bytes32 actual);
    error ConfigSubjectMismatch(bytes32 configId, bytes32 expectedSubject, bytes32 actualSubject);
    error ConfigRevisionAlreadyExists(bytes32 subject, uint32 revision, bytes32 configId);
    error ConfigNotLatest(bytes32 configId, bytes32 latestConfigId);
    error UnauthorizedStateTransition(bytes32 configId, uint8 oldStatus, uint8 newStatus);
    error ReasonCodeRequired(ReasonCode reason);
    error InvalidImplementation(address implementation);
    error UpgradeableImplementationForbidden(address implementation);
    error AdapterCodeHashMismatch(bytes32 expected, bytes32 actual);
    error AdapterInterfaceMismatch(bytes32 expected, bytes32 actual);
    error AdapterCapabilitiesInvalid();
    error AdapterCapabilitiesMismatch();
    error AdapterCapabilityHashMismatch(bytes32 expected, bytes32 actual);
    error AdapterProviderHashMismatch(bytes32 expected, bytes32 actual);
    error AdapterReturnMalformed(bytes32 adapterConfigId);
    error AdapterProviderInterfaceMissing(address token, bytes4 probeSelector);
    error InvalidAssetClass(uint8 actual);
    error CalculatorCodeHashMismatch(bytes32 expected, bytes32 actual);
    error CalculatorInterfaceMismatch(bytes32 expected, bytes32 actual);
    error CalculatorAssetClassMismatch(AssetClass expected, AssetClass actual);
    error CalculatorStaticCallFailed(bytes32 calculatorConfigId);
    error CalculatorReturnMalformed(bytes32 calculatorConfigId);
    error AssetDecimalsMismatch(address token, uint8 expected, uint256 actual);
    error SettlementTokenDecimalsMismatch(address token, uint8 expected, uint256 actual);
    error InvalidTokenDeploymentKind(TokenDeploymentKind kind);
    error TokenCodeHashMismatch(address token, bytes32 expected, bytes32 actual);
    error TokenDeploymentKindMismatch(address token, TokenDeploymentKind declared);
    error TokenImplementationBaselineInvalid(
        TokenDeploymentKind kind, address implementation, bytes32 implementationCodeHash
    );
    error InvalidRegistryDependency(address dependency);
    error ConfigReferenceMismatch(bytes32 configId, bytes32 expectedConfigHash);
    error SettlementAdapterCapabilitiesInvalid(bytes32 adapterConfigId);
    error InvalidPermitCapability(PermitCapability capability);
    error AssetVersionIdMismatch(bytes32 expected, bytes32 actual);
    error AssetTokenAlreadyRegistered(address token);
    error AssetAdapterCapabilitiesInvalid(bytes32 adapterConfigId);
    error DvpDeploymentVersionMismatch(address dvp, bytes32 expected, bytes32 actual);
    error DvpDeploymentVersionMalformed(address dvp);
    error AssetVersionImplementationChanged(bytes32 assetVersionId);
    error DvpInterfaceMismatch(address dvp);
    error DvpRetired(address dvp);
    error SettlementTokenImplementationChanged(bytes32 configId);

    // --- Participant ---
    error InvalidParticipantInput();
    error InvalidParticipantType(ParticipantType participantType);
    error InvalidParticipantValidity(uint64 validUntil, uint64 currentTime);
    error ParticipantNotFound(address wallet);
    error ParticipantVersionConflict(address wallet, uint64 expectedVersion, uint64 actualVersion);
    error ParticipantIdentityImmutable(address wallet);
    error ParticipantPermanentlyRevoked(address wallet);
    error ParticipantStateTransitionInvalid(address wallet, ParticipantStatus oldStatus, ParticipantStatus newStatus);
    error InvalidEligibilityInput();
    error EligibilityNotFound(bytes32 eligibilityKey);
    error EligibilityKeyMismatch(bytes32 expected, bytes32 actual);
    error EligibilityAssetVersionMismatch(bytes32 eligibilityKey, bytes32 expected, bytes32 actual);
    error EligibilityNotPassed(bytes32 eligibilityKey);
    error EligibilityExpired(bytes32 eligibilityKey);
    error EligibilityPausedOrRevoked(bytes32 eligibilityKey);
    error EligibilityVersionConflict(bytes32 eligibilityKey, uint64 expectedVersion, uint64 actualVersion);

    // --- Fee Epoch / Fee Version ---
    error FeePolicyEpochNotFound(uint64 feePolicyEpoch);
    error FeePolicyEpochNotSealed(uint64 feePolicyEpoch);
    error FeePolicyEpochNotServiceable(uint64 feePolicyEpoch, FeePolicyEpochStatus status);
    error FeePolicyEpochAlreadyExists(uint64 feePolicyEpoch);
    error FeePolicyEpochSequenceMismatch(uint64 expected, uint64 actual);
    error InvalidFeePolicyEpochValidity(uint64 quoteValidFrom, uint64 quoteValidUntil, uint64 settlementValidUntil);
    error FeePolicyEpochSealed(uint64 feePolicyEpoch);
    error FeePolicyEpochConfigHashMismatch(bytes32 supplied, bytes32 recomputed);
    error FeePolicyEpochOutsideQuoteWindow(uint64 feePolicyEpoch, uint64 currentTime);
    error FeePolicyEpochTransitionTooEarly(uint64 feePolicyEpoch, uint64 earliestTime, uint64 currentTime);
    error FeePolicyEpochExpectedHashMismatch(bytes32 expected, bytes32 stored, bytes32 recomputed);
    error FeePolicyEpochFeeNotReady(uint64 feePolicyEpoch, bytes32 feeVersionId);
    error InvalidFeeConfig();
    error InvalidFeeParticipantType(ParticipantType participantType);
    error InvalidFeeScopeKey(ScopeType scopeType, bytes32 scopeKeyHash);
    error FeeRateOutOfRange(ParticipantType participantType, uint16 rateBps);
    error AggregateFeeRateOutOfRange(uint256 totalBps, uint256 maximumBps);
    error FeeCapNotCanonical(ParticipantType participantType, bool hasCap, uint256 capAmount);
    error FeeValidityOutsideEpoch(uint64 feePolicyEpoch, uint64 validFrom, uint64 validUntil);
    error FeeMatchedScopeHashMismatch(bytes32 supplied, bytes32 recomputed);
    error FeeConstraintHashMismatch(bytes32 supplied, bytes32 recomputed);
    error FeeResolverNoMatch(uint64 feePolicyEpoch, bytes32 assetVersionId);
    error FeeOverflow();
    error SellerFeeExceedsPrincipal(uint256 sellerFee, uint256 cashPrincipal);
    error AggregateFeeExceedsPrincipal(uint256 buyerFee, uint256 sellerFee, uint256 cashPrincipal);
    error CashConservationMismatch();
    error ExternalCallFailed(bytes4 selector);
    error ParticipantInactive(address wallet);
    error ParticipantRelationshipInvalid(ParticipantType requesterType);
    error AssetVersionInactive(bytes32 assetVersionId);
    error SettlementTokenInactive(bytes32 configId);
    error AdapterInactive(bytes32 adapterConfigId);
    error CalculatorInactive(bytes32 calculatorConfigId);
    error InvalidQuantityRange();
    error InvalidQuantityStep();
    error InvalidSettlementTimeWindow();

    // --- Market Rule ---
    error InvalidMarketRule();
    error MarketRuleNotServiceable(bytes32 configId, MarketRuleStatus status);
    error MarketRulePaused(bytes32 configId);
    error MarketRuleNotSealed(bytes32 configId);
    error MarketRuleAlreadySealed(bytes32 configId);
    error MarketRuleOutsideQuoteWindow(bytes32 configId, uint64 currentTime);
    error MarketRuleTransitionTooEarly(bytes32 configId, uint64 earliestTime, uint64 currentTime);
    error MarketRuleSnapshotMismatch(bytes32 configId);
    error MarketRuleQuantityViolation(bytes32 configId);
    error MarketRulePriceTickViolation(bytes32 configId, uint256 quotedPrice, uint256 priceTick);
    error MarketRuleMinimumPrincipalViolation(bytes32 configId, uint256 cashPrincipal, uint256 minimum);
    error FeeSnapshotMismatch(bytes32 feeVersionId);
    error TransferRestricted(bytes32 adapterConfigId, uint256 restrictionCode, bytes32 reasonHash);
    error InsufficientBalance(address token, address owner, uint256 required, uint256 actual);
    error InsufficientAllowance(address token, address owner, uint256 required, uint256 actual);
    error UnsupportedTokenBehavior(address token);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);
    error PermitUnsupported(address token);
    error PermitFieldMismatch(address token, bytes32 field);
    error PermitSimulationRequired(address token, address owner, uint256 required);
}
