// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Asset class selecting principal calculator.
enum AssetClass {
    NONE,
    STOCK,
    FUND,
    BOND
}

enum TokenStandard {
    NONE,
    ERC20,
    ERC1404
}

enum TokenDeploymentKind {
    NONE,
    DIRECT,
    ERC1967_PROXY
}

enum ParticipantType {
    NONE,
    INVESTOR,
    MAKER
}

/// @notice BUY: requester is buyer; SELL: requester is seller.
enum RequesterSide {
    NONE,
    BUY,
    SELL
}

enum RestrictionMode {
    NONE,
    UNRESTRICTED,
    PLATFORM,
    ISSUER_EXTERNAL,
    TOKEN_ENFORCED
}

enum PrecheckMethod {
    NONE,
    NO_PRECHECK,
    ERC1404_CHECK,
    TOKEN_SPECIFIC_CHECK
}

enum TransferLeg {
    NONE,
    ASSET,
    SETTLEMENT_TO_SELLER,
    SETTLEMENT_TO_COLLECTOR
}

enum Decision {
    NONE,
    PASS,
    BLOCK,
    UNKNOWN
}

enum NonceType {
    NONE,
    MAKER_QUOTE,
    REQUESTER_TRADE
}

enum NonceStatus {
    NONE,
    UNUSED,
    USED,
    CANCELLED
}

enum PermitCapability {
    NONE,
    UNSUPPORTED,
    EIP2612
}

enum RoundingMode {
    NONE,
    DOWN
}

enum ParticipantStatus {
    NONE,
    ACTIVE,
    PAUSED,
    REVOKED
}

enum AssetVersionStatus {
    NONE,
    REGISTERED,
    ACTIVE,
    PAUSED,
    DEPRECATED
}

enum FeeVersionStatus {
    NONE,
    REGISTERED,
    ACTIVE,
    PAUSED,
    DEPRECATED,
    // N2: Emergency stop that preserves the deprecated lifecycle provenance.
    DEPRECATED_PAUSED
}

enum SettlementTokenStatus {
    NONE,
    REGISTERED,
    ACTIVE,
    PAUSED,
    DEPRECATED
}

enum AdapterStatus {
    NONE,
    REGISTERED,
    ACTIVE,
    PAUSED,
    DEPRECATED
}

enum CalculatorStatus {
    NONE,
    REGISTERED,
    ACTIVE,
    PAUSED,
    DEPRECATED
}

enum FeePolicyEpochStatus {
    NONE,
    DRAFT,
    ACTIVE,
    LEGACY_SERVING,
    CLOSED
}

enum MarketRuleStatus {
    NONE,
    DRAFT,
    ACTIVE,
    LEGACY_SERVING,
    CLOSED
}

/// @notice Fee scope precedence (most specific first).
enum ScopeType {
    NONE,
    GLOBAL,
    CHAIN,
    ASSET_CLASS,
    INSTRUMENT,
    ASSET_VERSION
}

enum ReasonCode {
    NONE,
    SECURITY_INCIDENT,
    CONFIG_MISMATCH,
    TOKEN_BEHAVIOR_CHANGED,
    IMPLEMENTATION_CHANGED,
    ELIGIBILITY_INCIDENT,
    RECONCILIATION_EXCEPTION,
    RPC_OR_FINALITY_INCIDENT,
    PLANNED_MIGRATION,
    GOVERNANCE_ACTION
}

struct StockPriceTerms {
    uint256 unitPrice;
    uint64 priceAsOf;
    bytes32 referenceMarketHash;
    bytes32 priceSourceHash;
}

struct FundPriceTerms {
    uint256 navPerUnit;
    uint32 navDate;
    bytes32 navSourceHash;
}

struct BondPriceTerms {
    uint256 cleanPricePerUnit;
    uint256 accruedInterestPerUnit;
    uint32 settlementDate;
    bytes32 sourceHash;
}

/// @notice Maker-signed RFQ quote bound to config snapshots.
struct FirmQuote {
    uint32 schemaVersion;
    bytes32 rfqIdHash;
    bytes32 quoteIdHash;
    // N10: Bind the canonical trade ID to the maker-signed quote.
    bytes32 tradeIdHash;
    // N16: Revision identifier only; does not invalidate or supersede prior quote versions.
    uint32 quoteVersion;
    address quotingMaker;
    address requester;
    ParticipantType requesterType;
    bytes32 assetVersionId;
    RequesterSide requesterSide;
    address assetToken;
    address settlementToken;
    AssetClass assetClass;
    bytes32 priceTermsHash;
    bytes priceData;
    bytes32 principalCalculatorConfigId;
    bytes32 principalCalculatorConfigHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    bytes32 marketRuleConfigId;
    bytes32 marketRuleConfigHash;
    uint256 minExecutableQuantity;
    uint256 maxExecutableQuantity;
    uint256 stepQuantity;
    uint64 feePolicyEpoch;
    bytes32 feeVersionId;
    bytes32 matchedScopeHash;
    bytes32 feeConstraintHash;
    uint256 quoteNonce;
    uint64 expiresAt;
}

/// @notice Requester-signed trade against a firm quote and frozen snapshot.
struct TradeIntent {
    uint32 schemaVersion;
    bytes32 tradeIdHash;
    bytes32 quoteHash;
    bytes32 snapshotHash;
    address requester;
    ParticipantType requesterType;
    address quotingMaker;
    bytes32 assetVersionId;
    RequesterSide requesterSide;
    address buyer;
    address seller;
    address assetToken;
    address settlementToken;
    uint256 executedQuantity;
    AssetClass assetClass;
    bytes32 priceTermsHash;
    bytes priceData;
    bytes32 principalCalculatorConfigId;
    bytes32 principalCalculatorConfigHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    bytes32 marketRuleConfigId;
    bytes32 marketRuleConfigHash;
    uint256 cashPrincipal;
    uint256 buyerFee;
    uint256 sellerFee;
    uint256 buyerDebit;
    uint256 sellerCredit;
    uint256 collectorCredit;
    address collector;
    uint64 feePolicyEpoch;
    bytes32 feeVersionId;
    bytes32 matchedScopeHash;
    bytes32 feeConstraintHash;
    RoundingMode roundingMode;
    uint256 tradeNonce;
    uint64 deadline;
}

/// @notice Immutable terms copied at trade creation for settlement checks.
struct TradeTermsSnapshot {
    uint32 schemaVersion;
    bytes32 tradeIdHash;
    bytes32 quoteHash;
    uint256 chainId;
    address dvpContract;
    address requester;
    ParticipantType requesterType;
    address quotingMaker;
    RequesterSide requesterSide;
    address buyer;
    address seller;
    bytes32 assetVersionId;
    address assetToken;
    address settlementToken;
    uint8 assetDecimals;
    uint8 settlementTokenDecimals;
    uint256 executedQuantity;
    AssetClass assetClass;
    bytes32 priceTermsHash;
    bytes priceData;
    bytes32 principalCalculatorConfigId;
    bytes32 principalCalculatorConfigHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    bytes32 marketRuleConfigId;
    bytes32 marketRuleConfigHash;
    uint256 cashPrincipal;
    uint256 buyerFee;
    uint256 sellerFee;
    uint256 buyerDebit;
    uint256 sellerCredit;
    uint256 collectorCredit;
    address collector;
    uint64 feePolicyEpoch;
    bytes32 feeVersionId;
    bytes32 matchedScopeHash;
    bytes32 feeConstraintHash;
    RoundingMode roundingMode;
    uint256 makerQuoteNonce;
    uint256 requesterTradeNonce;
    uint64 quoteExpiresAt;
    uint64 tradeDeadline;
    uint64 createdAt;
}

struct NonceCancellation {
    address signer;
    NonceType nonceType;
    uint256 nonce;
    uint64 deadline;
}

struct PermitData {
    bool usePermit;
    address owner;
    address token;
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @notice Signed payloads and optional EIP-2612 permits for one settlement.
struct SettlementParams {
    FirmQuote firmQuote;
    TradeIntent tradeIntent;
    TradeTermsSnapshot snapshot;
    bytes quotingMakerSignature;
    bytes requesterSignature;
    PermitData assetPermit;
    PermitData settlementPermit;
}

struct AssetVersionConfig {
    uint32 schemaVersion;
    bytes32 economicAssetIdHash;
    bytes32 assetVersionId;
    uint256 chainId;
    uint32 versionNo;
    address assetToken;
    TokenStandard tokenStandard;
    TokenDeploymentKind tokenDeploymentKind;
    uint8 assetDecimals;
    bytes32 tokenCodeHash;
    address implementation;
    bytes32 implementationCodeHash;
    PermitCapability assetPermitCapability;
    AssetClass assetClass;
    bytes32 principalCalculatorConfigId;
    bytes32 principalCalculatorConfigHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    RestrictionMode restrictionMode;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    address dvpContract;
    bytes32 deploymentVersionHash;
    bytes32 replacesAssetVersionId;
    bytes32 configHash;
}

struct AssetVersionRecord {
    AssetVersionConfig config;
    AssetVersionStatus status;
    bool exists;
}

struct SettlementTokenConfig {
    uint32 schemaVersion;
    bytes32 configId;
    uint32 revision;
    uint256 chainId;
    address settlementToken;
    TokenDeploymentKind tokenDeploymentKind;
    uint8 settlementTokenDecimals;
    bytes32 tokenCodeHash;
    address implementation;
    bytes32 implementationCodeHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    PermitCapability permitCapability;
    bytes32 replacesConfigId;
    bytes32 configHash;
}

struct SettlementTokenRecord {
    SettlementTokenConfig config;
    SettlementTokenStatus status;
    bool exists;
}

struct MarketRuleConfig {
    uint32 schemaVersion;
    bytes32 marketRuleConfigId;
    uint32 revision;
    uint256 chainId;
    bytes32 assetVersionId;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    uint256 minCashPrincipal;
    uint256 minExecutableQuantity;
    uint256 quantityStep;
    uint256 priceTick;
    uint8 priceDecimals;
    uint8 quantityDecimals;
    uint64 quoteValidFrom;
    uint64 quoteValidUntil;
    uint64 settlementValidUntil;
    bytes32 replacesConfigId;
    bytes32 configHash;
}

struct MarketRuleRecord {
    MarketRuleConfig config;
    MarketRuleStatus status;
    bool isSealed;
    bool paused;
    bool exists;
}

struct AdapterCapabilities {
    TokenStandard tokenStandard;
    RestrictionMode restrictionMode;
    PrecheckMethod precheckMethod;
    uint256 transferLegMask;
}

struct RestrictionProvider {
    address provider;
    bytes4 selector;
    bytes32 codeHash;
}

struct RestrictionProviderSet {
    RestrictionProvider[] providers;
}

struct AdapterConfig {
    uint32 schemaVersion;
    bytes32 adapterConfigId;
    uint32 revision;
    uint256 chainId;
    address adapter;
    bytes32 interfaceVersion;
    bytes32 codeHash;
    AdapterCapabilities capabilities;
    bytes32 capabilityHash;
    bytes32 providerHash;
    bytes32 replacesId;
    bytes32 configHash;
}

struct AdapterRecord {
    AdapterConfig config;
    AdapterStatus status;
    bool exists;
}

struct PrincipalCalculatorConfig {
    uint32 schemaVersion;
    bytes32 calculatorConfigId;
    uint32 revision;
    uint256 chainId;
    AssetClass assetClass;
    address calculator;
    bytes32 interfaceVersion;
    bytes32 codeHash;
    bytes32 replacesId;
    bytes32 configHash;
}

struct PrincipalCalculatorRecord {
    PrincipalCalculatorConfig config;
    CalculatorStatus status;
    bool exists;
}

struct ParticipantInput {
    address wallet;
    bytes32 participantIdHash;
    ParticipantType participantType;
    uint64 validUntil;
    bytes32 evidenceHash;
}

struct ParticipantRecord {
    address wallet;
    bytes32 participantIdHash;
    ParticipantType participantType;
    ParticipantStatus status;
    uint64 validUntil;
    uint64 version;
    bytes32 evidenceHash;
}

struct EligibilityInput {
    address wallet;
    bytes32 assetVersionId;
    Decision decision;
    uint64 validFrom;
    uint64 validUntil;
    bytes32 kycDecisionVersion;
    bytes32 permissionVersion;
    bytes32 evidenceHash;
}

struct EligibilityRecord {
    // keccak256(abi.encode(chainId, wallet, assetVersionId))
    bytes32 eligibilityKey;
    address wallet;
    bytes32 assetVersionId;
    Decision decision;
    uint64 validFrom;
    uint64 validUntil;
    bytes32 kycDecisionVersion;
    bytes32 permissionVersion;
    uint64 recordVersion;
    bool paused;
    bool revoked;
    bytes32 evidenceHash;
}

struct FeePolicyEpochConfig {
    uint32 schemaVersion;
    uint64 feePolicyEpoch;
    uint256 chainId;
    uint64 quoteValidFrom;
    uint64 quoteValidUntil;
    uint64 settlementValidUntil;
    bytes32 configHash;
}

struct FeePolicyEpochRecord {
    FeePolicyEpochConfig config;
    FeePolicyEpochStatus status;
    bool isSealed;
    bool exists;
}

struct FeeConfig {
    uint32 schemaVersion;
    bytes32 feeVersionId;
    uint32 revision;
    uint256 chainId;
    uint64 feePolicyEpoch;
    ScopeType scopeType;
    bytes32 scopeKeyHash;
    bytes32 matchedScopeHash;
    uint16 investorRateBps;
    bool investorHasCap;
    uint256 investorCapAmount;
    uint16 makerRateBps;
    bool makerHasCap;
    uint256 makerCapAmount;
    RoundingMode roundingMode;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    address collector;
    uint64 validFrom;
    uint64 validUntil;
    bytes32 feeConstraintHash;
    bytes32 replacesFeeVersionId;
    bytes32 configHash;
}

struct FeeVersionRecord {
    FeeConfig config;
    FeeVersionStatus status;
    bool exists;
}

library HTPTypes {
    uint32 internal constant SCHEMA_VERSION = 1;
}
