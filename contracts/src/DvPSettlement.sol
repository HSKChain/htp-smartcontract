// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAdapterRegistry} from "./interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "./interfaces/IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "./interfaces/IFeeRegistry.sol";
import {IDvPSettlement} from "./interfaces/IDvPSettlement.sol";
import {IDvPSignedPayloadValidator} from "./interfaces/IDvPSignedPayloadValidator.sol";
import {IDvPCurrentStateValidator} from "./interfaces/IDvPCurrentStateValidator.sol";
import {IDvPCurrentStateValidatorFactory} from "./interfaces/IDvPCurrentStateValidatorFactory.sol";
import {IParticipantRegistry} from "./interfaces/IParticipantRegistry.sol";
import {IMarketRuleRegistry} from "./interfaces/IMarketRuleRegistry.sol";
import {IPrincipalCalculatorRegistry} from "./interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "./interfaces/ISettlementTokenRegistry.sol";
import {DeploymentVersion} from "./libraries/DeploymentVersion.sol";
import {HTPHashing} from "./libraries/HTPHashing.sol";
import {Roles} from "./libraries/Roles.sol";
import {HTPErrors} from "./types/HTPErrors.sol";
import {DvPSignedPayloadValidator} from "./validation/DvPSignedPayloadValidator.sol";
import {
    Decision,
    NonceCancellation,
    NonceStatus,
    NonceType,
    PermitData,
    ReasonCode,
    SettlementParams,
    TransferLeg
} from "./types/HTPTypes.sol";

struct DvPRoles {
    address defaultAdmin;
    address governance;
    address pauser;
    address executor;
}

struct DvPRegistries {
    address participant;
    address assetVersion;
    address eligibility;
    address fee;
    address marketRule;
    address settlementToken;
    address adapter;
    address principalCalculator;
}

/// @notice On-chain DvP settlement orchestrator (signatures, state, adapter transfers).
contract DvPSettlement is AccessControl, ReentrancyGuard, IDvPSettlement {
    bytes32 private constant CURRENT_STATE_VALIDATOR_FACTORY_CODE_HASH =
        0x890fee98fba1a49d554379f71bf4711d00d0caf2e46974ec9a428c6d9d43f17b;
    bytes4 private constant ALLOWANCE_SELECTOR = 0xdd62ed3e;
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd;
    bytes4 private constant PERMIT_SELECTOR = 0xd505accf;
    bytes32 private constant SETTLEMENT_EXECUTED_TOPIC = IDvPSettlement.SettlementExecuted.selector;
    bytes32 private constant FEE_COLLECTED_TOPIC = 0xbc3cb3ef76421eeef50f0a68e293ddd9c094e8a104394fe59ca13c21c9ef778b;
    uint256 private constant TOKEN_VIEW_GAS_LIMIT = 30_000;
    uint256 private constant TOKEN_WRITE_GAS_LIMIT = 100_000;

    struct AdapterCallResult {
        bool callSucceeded;
        bool returnWellFormed;
        bytes32 decisionWord;
        bytes32 restrictionCode;
        bytes32 reasonHash;
    }

    struct AdapterValidationResult {
        Decision decision;
        bytes4 reason;
        uint256 restrictionCode;
        bytes32 reasonHash;
    }

    struct BalanceSnapshot {
        uint256 assetSender;
        uint256 assetReceiver;
        uint256 dvpAsset;
        uint256 settlementBuyer;
        uint256 settlementSeller;
        uint256 settlementCollector;
        uint256 dvpSettlement;
    }

    struct SettlementEventData {
        uint256 chainId;
        bytes32 quoteHash;
        uint256 requesterType;
        uint256 requesterSide;
        address requester;
        address quotingMaker;
        address buyer;
        address seller;
        address assetToken;
        address settlementToken;
        uint256 executedQuantity;
        uint256 assetClass;
        bytes32 priceTermsHash;
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
        uint256 feePolicyEpoch;
        bytes32 feeVersionId;
        bytes32 matchedScopeHash;
        uint256 makerQuoteNonce;
        uint256 requesterTradeNonce;
        bytes32 deploymentVersionHash;
    }

    struct FeeEventData {
        uint256 chainId;
        bytes32 snapshotHash;
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 collectorCredit;
        uint256 feePolicyEpoch;
        bytes32 feeVersionId;
        bytes32 matchedScopeHash;
        bytes32 deploymentVersionHash;
    }

    IParticipantRegistry public immutable override participantRegistry;
    IAssetVersionRegistry public immutable override assetVersionRegistry;
    IEligibilityRegistry public immutable override eligibilityRegistry;
    IFeeRegistry public immutable override feeRegistry;
    IMarketRuleRegistry public immutable override marketRuleRegistry;
    ISettlementTokenRegistry public immutable override settlementTokenRegistry;
    IAdapterRegistry public immutable override adapterRegistry;
    IPrincipalCalculatorRegistry public immutable override principalCalculatorRegistry;

    bytes32 public immutable override deploymentVersionHash;
    uint256 private immutable DEPLOYED_CHAIN_ID;
    bytes32 private immutable DOMAIN_VERSION_HASH;
    bytes32 private immutable DOMAIN_SEPARATOR;
    IDvPSignedPayloadValidator private immutable SIGNED_PAYLOAD_VALIDATOR;
    bytes32 private immutable SIGNED_PAYLOAD_VALIDATOR_CODE_HASH;
    IDvPCurrentStateValidator private immutable CURRENT_STATE_VALIDATOR;
    bytes32 private immutable CURRENT_STATE_VALIDATOR_CODE_HASH;

    bool public override globalPaused;
    bool public override retired;
    mapping(bytes32 quoteHash => bool used) public override usedQuoteHash;
    mapping(bytes32 snapshotHash => bool used) public override usedSnapshotHash;
    mapping(bytes32 tradeIdHash => bool used) public override usedTradeIdHash;
    mapping(address signer => mapping(NonceType nonceType => mapping(uint256 nonce => NonceStatus status))) private
        nonceStates;

    uint256 private _defaultAdminCount;

    constructor(
        DvPRoles memory roles,
        DvPRegistries memory registries,
        uint256 chainId_,
        bytes memory deploymentVersion_,
        address currentStateValidatorFactory_
    ) {
        _requireRoleHolder(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin);
        _requireRoleHolder(Roles.GOVERNANCE_ROLE, roles.governance);
        _requireRoleHolder(Roles.PAUSER_ROLE, roles.pauser);
        _requireRoleHolder(Roles.EXECUTOR_ROLE, roles.executor);
        if (chainId_ != block.chainid) {
            revert HTPErrors.InvalidChainOrContract(chainId_, address(this));
        }

        _requireRegistry(registries.participant);
        _requireRegistry(registries.assetVersion);
        _requireRegistry(registries.eligibility);
        _requireRegistry(registries.fee);
        _requireRegistry(registries.marketRule);
        _requireRegistry(registries.settlementToken);
        _requireRegistry(registries.adapter);
        _requireRegistry(registries.principalCalculator);

        if (
            currentStateValidatorFactory_ == address(0) || currentStateValidatorFactory_.code.length == 0
                || currentStateValidatorFactory_.codehash != CURRENT_STATE_VALIDATOR_FACTORY_CODE_HASH
        ) {
            revert HTPErrors.InvalidDvpValidatorFactory(currentStateValidatorFactory_);
        }

        participantRegistry = IParticipantRegistry(registries.participant);
        assetVersionRegistry = IAssetVersionRegistry(registries.assetVersion);
        eligibilityRegistry = IEligibilityRegistry(registries.eligibility);
        feeRegistry = IFeeRegistry(registries.fee);
        marketRuleRegistry = IMarketRuleRegistry(registries.marketRule);
        settlementTokenRegistry = ISettlementTokenRegistry(registries.settlementToken);
        adapterRegistry = IAdapterRegistry(registries.adapter);
        principalCalculatorRegistry = IPrincipalCalculatorRegistry(registries.principalCalculator);

        DEPLOYED_CHAIN_ID = chainId_;
        deploymentVersionHash = DeploymentVersion.hash(deploymentVersion_);
        DOMAIN_VERSION_HASH = keccak256(bytes(DeploymentVersion.domainVersion(deploymentVersion_)));
        DOMAIN_SEPARATOR = HTPHashing.domainSeparator(deploymentVersion_, chainId_, address(this));
        IDvPSignedPayloadValidator signedPayloadValidator =
            IDvPSignedPayloadValidator(address(new DvPSignedPayloadValidator(address(this))));
        SIGNED_PAYLOAD_VALIDATOR = signedPayloadValidator;
        SIGNED_PAYLOAD_VALIDATOR_CODE_HASH = address(signedPayloadValidator).codehash;
        IDvPCurrentStateValidator currentStateValidator;
        try IDvPCurrentStateValidatorFactory(currentStateValidatorFactory_).deployValidator(address(this)) returns (
            IDvPCurrentStateValidator deployedValidator
        ) {
            currentStateValidator = deployedValidator;
        } catch {
            revert HTPErrors.InvalidDvpValidatorFactory(currentStateValidatorFactory_);
        }
        if (address(currentStateValidator) == address(0) || address(currentStateValidator).code.length == 0) {
            revert HTPErrors.InvalidDvpValidator(address(currentStateValidator));
        }
        CURRENT_STATE_VALIDATOR = currentStateValidator;
        CURRENT_STATE_VALIDATOR_CODE_HASH = address(currentStateValidator).codehash;

        _grantRole(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin);
        _grantRole(Roles.GOVERNANCE_ROLE, roles.governance);
        _grantRole(Roles.PAUSER_ROLE, roles.pauser);
        _grantRole(Roles.EXECUTOR_ROLE, roles.executor);
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        // N3: A zero address cannot be the actionable successor counted by the last-admin guard.
        if (role == Roles.DEFAULT_ADMIN_ROLE) _requireRoleHolder(role, account);
        granted = super._grantRole(role, account);
        if (granted && role == Roles.DEFAULT_ADMIN_ROLE) ++_defaultAdminCount;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        if (role == Roles.DEFAULT_ADMIN_ROLE && _defaultAdminCount == 1 && hasRole(role, account)) {
            revert HTPErrors.LastDefaultAdminCannotBeRemoved(account);
        }
        revoked = super._revokeRole(role, account);
        if (revoked && role == Roles.DEFAULT_ADMIN_ROLE) --_defaultAdminCount;
    }

    /// @notice EIP-712 domain separator (cached when chain id matches deploy chain).
    function domainSeparatorV4() public view override returns (bytes32) {
        if (block.chainid == DEPLOYED_CHAIN_ID) return DOMAIN_SEPARATOR;
        return keccak256(
            abi.encode(
                HTPHashing.EIP712_DOMAIN_TYPEHASH,
                HTPHashing.EIP712_NAME_HASH,
                DOMAIN_VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Read-only settlement feasibility (signatures, replay, registry, adapters).
    function preCheck(SettlementParams calldata params)
        external
        view
        override
        returns (Decision decision, bytes4 reason)
    {
        if (retired) return (Decision.BLOCK, HTPErrors.RetiredContract.selector);
        if (globalPaused) return (Decision.BLOCK, HTPErrors.ContractPaused.selector);
        if (block.chainid != DEPLOYED_CHAIN_ID) {
            return (Decision.BLOCK, HTPErrors.InvalidChainOrContract.selector);
        }
        if (address(SIGNED_PAYLOAD_VALIDATOR).codehash != SIGNED_PAYLOAD_VALIDATOR_CODE_HASH) {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
        }
        try SIGNED_PAYLOAD_VALIDATOR.preCheck(params) returns (
            Decision signedPayloadDecision, bytes4 signedPayloadReason
        ) {
            if (signedPayloadDecision != Decision.PASS) return (signedPayloadDecision, signedPayloadReason);
        } catch {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
        }

        (bytes4 replayReason,) = _usedReplayHash(params);
        if (replayReason != bytes4(0)) return (Decision.BLOCK, replayReason);
        address validator = address(CURRENT_STATE_VALIDATOR);
        if (validator.codehash != CURRENT_STATE_VALIDATOR_CODE_HASH) {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
        }

        bool callSucceeded;
        uint256 rawDecision;
        bytes32 rawReason;
        uint256 rawAssetAdapter;
        uint256 rawSettlementAdapter;

        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, 0, calldatasize())
            let output := add(input, and(add(calldatasize(), 0x1f), not(0x1f)))
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            mstore(add(output, 0x40), 0)
            mstore(add(output, 0x60), 0)
            callSucceeded := staticcall(gas(), validator, input, calldatasize(), output, 0x80)
            if callSucceeded {
                callSucceeded := eq(returndatasize(), 0x80)
                rawDecision := mload(output)
                rawReason := mload(add(output, 0x20))
                rawAssetAdapter := mload(add(output, 0x40))
                rawSettlementAdapter := mload(add(output, 0x60))
            }
        }
        if (
            !callSucceeded || rawDecision == uint256(Decision.NONE) || rawDecision > uint256(Decision.UNKNOWN)
                || uint224(uint256(rawReason)) != 0 || rawAssetAdapter > type(uint160).max
                || rawSettlementAdapter > type(uint160).max
        ) {
            return (Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
        }
        decision = Decision(rawDecision);
        reason = bytes4(rawReason);
        if (decision != Decision.PASS) return (decision, reason);
        return _validateAdapters(
            params, address(uint160(rawAssetAdapter)), address(uint160(rawSettlementAdapter)), false, bytes32(0)
        );
    }

    function getNonceStatus(address signer, NonceType nonceType, uint256 nonce)
        public
        view
        override
        returns (NonceStatus status)
    {
        status = nonceStates[signer][nonceType][nonce];
        return status == NonceStatus.NONE ? NonceStatus.UNUSED : status;
    }

    function cancelNonce(NonceType nonceType, uint256 nonce) external override nonReentrant {
        _cancelNonce(_msgSender(), nonceType, nonce);
    }

    function cancelNonceBySig(NonceCancellation calldata cancellation, bytes calldata signature)
        external
        override
        nonReentrant
    {
        if (cancellation.nonceType != NonceType.MAKER_QUOTE && cancellation.nonceType != NonceType.REQUESTER_TRADE) {
            revert HTPErrors.InvalidNonceType(cancellation.nonceType);
        }
        if (block.timestamp > cancellation.deadline) {
            revert HTPErrors.SignatureExpired(cancellation.deadline);
        }

        if (address(SIGNED_PAYLOAD_VALIDATOR).codehash != SIGNED_PAYLOAD_VALIDATOR_CODE_HASH) {
            revert HTPErrors.ExternalCallFailed(IDvPSignedPayloadValidator.validateNonceCancellation.selector);
        }
        SIGNED_PAYLOAD_VALIDATOR.validateNonceCancellation(cancellation, signature);
        _cancelNonce(cancellation.signer, cancellation.nonceType, cancellation.nonce);
    }

    function pauseGlobal(ReasonCode reason, bytes32 evidenceHash)
        external
        override
        onlyRole(Roles.PAUSER_ROLE)
        nonReentrant
    {
        if (globalPaused) revert HTPErrors.ContractPaused();
        _requireReasonAndEvidence(reason, evidenceHash);

        globalPaused = true;
        emit GlobalPaused(block.chainid, reason, evidenceHash, _msgSender());
    }

    function unpauseGlobal(ReasonCode reason, bytes32 evidenceHash)
        external
        override
        onlyRole(Roles.GOVERNANCE_ROLE)
        nonReentrant
    {
        if (retired) revert HTPErrors.RetiredContract();
        if (!globalPaused) revert HTPErrors.ContractNotPaused();
        _requireReasonAndEvidence(reason, evidenceHash);

        globalPaused = false;
        emit GlobalUnpaused(block.chainid, reason, evidenceHash, _msgSender());
    }

    function retire(ReasonCode reason, bytes32 evidenceHash)
        external
        override
        onlyRole(Roles.GOVERNANCE_ROLE)
        nonReentrant
    {
        if (retired) revert HTPErrors.RetiredContract();
        if (!globalPaused) revert HTPErrors.ContractNotPaused();
        _requireReasonAndEvidence(reason, evidenceHash);

        retired = true;
        emit Retired(block.chainid, reason, evidenceHash, _msgSender());
    }

    /// @notice Executes atomic DvP after full validation (executor role).
    function settle(SettlementParams calldata params) external override {
        _checkRole(Roles.EXECUTOR_ROLE, _msgSender());
        if (retired) revert HTPErrors.RetiredContract();
        if (globalPaused) revert HTPErrors.ContractPaused();
        if (block.chainid != DEPLOYED_CHAIN_ID) {
            revert HTPErrors.InvalidChainOrContract(block.chainid, address(this));
        }
        _settle(params);
    }

    /// @dev Settlement pipeline: validate, lock replay/nonces, permits, transfers, balance proof, events.
    function _settle(SettlementParams calldata params) private nonReentrant {
        if (address(SIGNED_PAYLOAD_VALIDATOR).codehash != SIGNED_PAYLOAD_VALIDATOR_CODE_HASH) {
            revert HTPErrors.ExternalCallFailed(IDvPSignedPayloadValidator.validateForSettlement.selector);
        }
        SIGNED_PAYLOAD_VALIDATOR.validateForSettlement(params);

        _validateReplayAvailability(params);

        (address assetAdapter, address settlementAdapter, bytes32 settlementAdapterConfigId) =
            _validateSettlementCurrentState(params);

        _validateAdapters(params, assetAdapter, settlementAdapter, true, settlementAdapterConfigId);

        _writeExecutionLocks(params);

        _tryPermits(params);
        BalanceSnapshot memory beforeBalances = _snapshotBalancesAndRequireFunds(params);

        _executeTransfers(params);
        BalanceSnapshot memory afterBalances = _snapshotBalances(params);

        _validateBalanceDeltas(params, beforeBalances, afterBalances);
        _emitSettlementEvents(params);
    }

    function _validateSettlementCurrentState(SettlementParams calldata params)
        private
        view
        returns (address assetAdapter, address settlementAdapter, bytes32 settlementAdapterConfigId)
    {
        address validator = address(CURRENT_STATE_VALIDATOR);
        if (validator.codehash != CURRENT_STATE_VALIDATOR_CODE_HASH) {
            revert HTPErrors.ExternalCallFailed(IDvPCurrentStateValidator.validateForSettlement.selector);
        }
        return CURRENT_STATE_VALIDATOR.validateForSettlement(params);
    }

    function _usedReplayHash(SettlementParams calldata params)
        private
        view
        returns (bytes4 reason, bytes32 offendingHash)
    {
        bytes32 quoteHash = params.tradeIntent.quoteHash;
        bytes32 snapshotHash = params.tradeIntent.snapshotHash;
        bytes32 tradeIdHash = params.tradeIntent.tradeIdHash;
        if (usedQuoteHash[quoteHash]) return (HTPErrors.QuoteAlreadyExecuted.selector, quoteHash);
        if (usedSnapshotHash[snapshotHash]) return (HTPErrors.SnapshotAlreadyExecuted.selector, snapshotHash);
        if (usedTradeIdHash[tradeIdHash]) return (HTPErrors.TradeAlreadyExecuted.selector, tradeIdHash);
        return (bytes4(0), bytes32(0));
    }

    function _validateReplayAvailability(SettlementParams calldata params) private view {
        (bytes4 reason, bytes32 offendingHash) = _usedReplayHash(params);
        if (reason == HTPErrors.QuoteAlreadyExecuted.selector) {
            revert HTPErrors.QuoteAlreadyExecuted(offendingHash);
        }
        if (reason == HTPErrors.SnapshotAlreadyExecuted.selector) {
            revert HTPErrors.SnapshotAlreadyExecuted(offendingHash);
        }
        if (reason == HTPErrors.TradeAlreadyExecuted.selector) {
            revert HTPErrors.TradeAlreadyExecuted(offendingHash);
        }

        _requireUnusedNonce(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);
        _requireUnusedNonce(params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
    }

    function _writeExecutionLocks(SettlementParams calldata params) private {
        bytes32 quoteHash = params.tradeIntent.quoteHash;
        bytes32 snapshotHash = params.tradeIntent.snapshotHash;
        bytes32 tradeIdHash = params.tradeIntent.tradeIdHash;

        usedQuoteHash[quoteHash] = true;
        usedSnapshotHash[snapshotHash] = true;
        usedTradeIdHash[tradeIdHash] = true;
        nonceStates[params.firmQuote.quotingMaker][NonceType.MAKER_QUOTE][params.firmQuote.quoteNonce] =
        NonceStatus.USED;
        nonceStates[params.tradeIntent.requester][NonceType.REQUESTER_TRADE][params.tradeIntent.tradeNonce] =
        NonceStatus.USED;
        emit NonceConsumed(
            block.chainid,
            params.firmQuote.quotingMaker,
            NonceType.MAKER_QUOTE,
            params.firmQuote.quoteNonce,
            tradeIdHash
        );
        emit NonceConsumed(
            block.chainid,
            params.tradeIntent.requester,
            NonceType.REQUESTER_TRADE,
            params.tradeIntent.tradeNonce,
            tradeIdHash
        );
    }

    function _requireUnusedNonce(address signer, NonceType nonceType, uint256 nonce) private view {
        NonceStatus status = getNonceStatus(signer, nonceType, nonce);
        if (status != NonceStatus.UNUSED) revert HTPErrors.NonceUnavailable(signer, nonceType, nonce, status);
    }

    function _tryPermits(SettlementParams calldata params) private {
        if (params.assetPermit.usePermit) _tryPermit(params.assetPermit);
        if (params.settlementPermit.usePermit) _tryPermit(params.settlementPermit);
    }

    function _tryPermit(PermitData calldata permit) private {
        address token = permit.token;
        address owner = permit.owner;
        uint256 value = permit.value;
        uint256 deadline = permit.deadline;
        uint256 v = permit.v;
        bytes32 r = permit.r;
        bytes32 s = permit.s;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, PERMIT_SELECTOR)
            mstore(add(input, 0x04), owner)
            mstore(add(input, 0x24), address())
            mstore(add(input, 0x44), value)
            mstore(add(input, 0x64), deadline)
            mstore(add(input, 0x84), v)
            mstore(add(input, 0xa4), r)
            mstore(add(input, 0xc4), s)
            pop(call(TOKEN_WRITE_GAS_LIMIT, token, 0, input, 0xe4, 0, 0))
        }
    }

    function _snapshotBalancesAndRequireFunds(SettlementParams calldata params)
        private
        view
        returns (BalanceSnapshot memory balances)
    {
        uint256 assetAllowance =
            _readTokenWord(params.snapshot.assetToken, ALLOWANCE_SELECTOR, params.snapshot.seller, address(this));
        if (assetAllowance < params.snapshot.executedQuantity) {
            revert HTPErrors.InsufficientAllowance(
                params.snapshot.assetToken, params.snapshot.seller, params.snapshot.executedQuantity, assetAllowance
            );
        }
        uint256 settlementAllowance =
            _readTokenWord(params.snapshot.settlementToken, ALLOWANCE_SELECTOR, params.snapshot.buyer, address(this));
        if (settlementAllowance < params.snapshot.buyerDebit) {
            revert HTPErrors.InsufficientAllowance(
                params.snapshot.settlementToken, params.snapshot.buyer, params.snapshot.buyerDebit, settlementAllowance
            );
        }

        balances = _snapshotBalances(params);
        if (balances.assetSender < params.snapshot.executedQuantity) {
            revert HTPErrors.InsufficientBalance(
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.executedQuantity,
                balances.assetSender
            );
        }
        if (balances.settlementBuyer < params.snapshot.buyerDebit) {
            revert HTPErrors.InsufficientBalance(
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.buyerDebit,
                balances.settlementBuyer
            );
        }
    }

    function _snapshotBalances(SettlementParams calldata params)
        private
        view
        returns (BalanceSnapshot memory balances)
    {
        balances.assetSender = _readTokenWord(
            params.snapshot.assetToken, BALANCE_OF_SELECTOR, params.snapshot.seller, address(0)
        );
        balances.assetReceiver =
            _readTokenWord(params.snapshot.assetToken, BALANCE_OF_SELECTOR, params.snapshot.buyer, address(0));
        balances.dvpAsset = _readTokenWord(params.snapshot.assetToken, BALANCE_OF_SELECTOR, address(this), address(0));
        balances.settlementBuyer =
            _readTokenWord(params.snapshot.settlementToken, BALANCE_OF_SELECTOR, params.snapshot.buyer, address(0));
        balances.settlementSeller =
            _readTokenWord(params.snapshot.settlementToken, BALANCE_OF_SELECTOR, params.snapshot.seller, address(0));
        balances.settlementCollector =
            _readTokenWord(params.snapshot.settlementToken, BALANCE_OF_SELECTOR, params.snapshot.collector, address(0));
        balances.dvpSettlement =
            _readTokenWord(params.snapshot.settlementToken, BALANCE_OF_SELECTOR, address(this), address(0));
    }

    function _readTokenWord(address token, bytes4 selector, address first, address second)
        private
        view
        returns (uint256 value)
    {
        bool success;
        uint256 returnSize;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selector)
            mstore(add(input, 0x04), first)
            mstore(add(input, 0x24), second)
            let inputSize := 0x24
            if eq(selector, ALLOWANCE_SELECTOR) { inputSize := 0x44 }
            success := staticcall(TOKEN_VIEW_GAS_LIMIT, token, input, inputSize, input, 0x20)
            returnSize := returndatasize()
            value := mload(input)
        }
        if (!success || returnSize != 32) revert HTPErrors.UnsupportedTokenBehavior(token);
    }

    function _executeTransfers(SettlementParams calldata params) private {
        _safeTransferFrom(
            params.snapshot.assetToken, params.snapshot.seller, params.snapshot.buyer, params.snapshot.executedQuantity
        );
        if (params.snapshot.sellerCredit != 0) {
            _safeTransferFrom(
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.seller,
                params.snapshot.sellerCredit
            );
        }
        if (params.snapshot.collectorCredit != 0) {
            _safeTransferFrom(
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.collector,
                params.snapshot.collectorCredit
            );
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, TRANSFER_FROM_SELECTOR)
            mstore(add(input, 0x04), from)
            mstore(add(input, 0x24), to)
            mstore(add(input, 0x44), amount)
            success := call(gas(), token, 0, input, 0x64, input, 0x20)
            returnSize := returndatasize()
            returnValue := mload(input)
        }
        if (!success || (returnSize != 0 && (returnSize != 32 || returnValue != 1))) {
            revert HTPErrors.UnsupportedTokenBehavior(token);
        }
    }

    function _validateBalanceDeltas(
        SettlementParams calldata params,
        BalanceSnapshot memory beforeBalances,
        BalanceSnapshot memory afterBalances
    ) private view {
        _requireDecrease(
            params.snapshot.assetToken,
            params.snapshot.seller,
            beforeBalances.assetSender,
            afterBalances.assetSender,
            params.snapshot.executedQuantity
        );
        _requireIncrease(
            params.snapshot.assetToken,
            params.snapshot.buyer,
            beforeBalances.assetReceiver,
            afterBalances.assetReceiver,
            params.snapshot.executedQuantity
        );
        _requireUnchanged(params.snapshot.assetToken, address(this), beforeBalances.dvpAsset, afterBalances.dvpAsset);
        _requireDecrease(
            params.snapshot.settlementToken,
            params.snapshot.buyer,
            beforeBalances.settlementBuyer,
            afterBalances.settlementBuyer,
            params.snapshot.buyerDebit
        );
        _requireIncrease(
            params.snapshot.settlementToken,
            params.snapshot.seller,
            beforeBalances.settlementSeller,
            afterBalances.settlementSeller,
            params.snapshot.sellerCredit
        );
        _requireIncrease(
            params.snapshot.settlementToken,
            params.snapshot.collector,
            beforeBalances.settlementCollector,
            afterBalances.settlementCollector,
            params.snapshot.collectorCredit
        );
        _requireUnchanged(
            params.snapshot.settlementToken, address(this), beforeBalances.dvpSettlement, afterBalances.dvpSettlement
        );
    }

    function _requireDecrease(address token, address account, uint256 beforeValue, uint256 afterValue, uint256 expected)
        private
        pure
    {
        if (beforeValue < afterValue) {
            revert HTPErrors.BalanceDeltaMismatch(token, account, expected, afterValue - beforeValue);
        }
        uint256 actual = beforeValue - afterValue;
        if (actual != expected) revert HTPErrors.BalanceDeltaMismatch(token, account, expected, actual);
    }

    function _requireIncrease(address token, address account, uint256 beforeValue, uint256 afterValue, uint256 expected)
        private
        pure
    {
        if (afterValue < beforeValue) {
            revert HTPErrors.BalanceDeltaMismatch(token, account, expected, beforeValue - afterValue);
        }
        uint256 actual = afterValue - beforeValue;
        if (actual != expected) revert HTPErrors.BalanceDeltaMismatch(token, account, expected, actual);
    }

    function _requireUnchanged(address token, address account, uint256 beforeValue, uint256 afterValue) private pure {
        uint256 actual = beforeValue >= afterValue ? beforeValue - afterValue : afterValue - beforeValue;
        if (actual != 0) revert HTPErrors.BalanceDeltaMismatch(token, account, 0, actual);
    }

    // log4：SettlementExecuted(topics=tradeId/snapshot/assetVersion) + FeeCollected(topics=tradeId/collector/token)。
    function _emitSettlementEvents(SettlementParams calldata params) private {
        SettlementEventData memory data;
        data.chainId = block.chainid;
        data.quoteHash = params.tradeIntent.quoteHash;
        data.requesterType = uint256(params.snapshot.requesterType);
        data.requesterSide = uint256(params.snapshot.requesterSide);
        data.requester = params.snapshot.requester;
        data.quotingMaker = params.snapshot.quotingMaker;
        data.buyer = params.snapshot.buyer;
        data.seller = params.snapshot.seller;
        data.assetToken = params.snapshot.assetToken;
        data.settlementToken = params.snapshot.settlementToken;
        data.executedQuantity = params.snapshot.executedQuantity;
        data.assetClass = uint256(params.snapshot.assetClass);
        data.priceTermsHash = params.snapshot.priceTermsHash;
        data.principalCalculatorConfigId = params.snapshot.principalCalculatorConfigId;
        data.principalCalculatorConfigHash = params.snapshot.principalCalculatorConfigHash;
        data.adapterConfigId = params.snapshot.adapterConfigId;
        data.adapterConfigHash = params.snapshot.adapterConfigHash;
        data.settlementTokenConfigId = params.snapshot.settlementTokenConfigId;
        data.settlementTokenConfigHash = params.snapshot.settlementTokenConfigHash;
        data.marketRuleConfigId = params.snapshot.marketRuleConfigId;
        data.marketRuleConfigHash = params.snapshot.marketRuleConfigHash;
        data.cashPrincipal = params.snapshot.cashPrincipal;
        data.buyerFee = params.snapshot.buyerFee;
        data.sellerFee = params.snapshot.sellerFee;
        data.buyerDebit = params.snapshot.buyerDebit;
        data.sellerCredit = params.snapshot.sellerCredit;
        data.feePolicyEpoch = params.snapshot.feePolicyEpoch;
        data.feeVersionId = params.snapshot.feeVersionId;
        data.matchedScopeHash = params.snapshot.matchedScopeHash;
        data.makerQuoteNonce = params.snapshot.makerQuoteNonce;
        data.requesterTradeNonce = params.snapshot.requesterTradeNonce;
        data.deploymentVersionHash = deploymentVersionHash;
        bytes32 tradeIdHash = params.tradeIntent.tradeIdHash;
        bytes32 snapshotHash = params.tradeIntent.snapshotHash;
        bytes32 assetVersionId = params.snapshot.assetVersionId;
        bytes32 eventTopic = SETTLEMENT_EXECUTED_TOPIC;
        assembly ("memory-safe") {
            log4(data, 0x400, eventTopic, tradeIdHash, snapshotHash, assetVersionId)
        }
        FeeEventData memory feeData;
        feeData.chainId = block.chainid;
        feeData.snapshotHash = params.tradeIntent.snapshotHash;
        feeData.buyerFee = params.snapshot.buyerFee;
        feeData.sellerFee = params.snapshot.sellerFee;
        feeData.collectorCredit = params.snapshot.collectorCredit;
        feeData.feePolicyEpoch = params.snapshot.feePolicyEpoch;
        feeData.feeVersionId = params.snapshot.feeVersionId;
        feeData.matchedScopeHash = params.snapshot.matchedScopeHash;
        feeData.deploymentVersionHash = deploymentVersionHash;
        bytes32 collectorTopic = bytes32(uint256(uint160(params.snapshot.collector)));
        bytes32 settlementTokenTopic = bytes32(uint256(uint160(params.snapshot.settlementToken)));
        eventTopic = FEE_COLLECTED_TOPIC;
        assembly ("memory-safe") {
            log4(feeData, 0x120, eventTopic, tradeIdHash, collectorTopic, settlementTokenTopic)
        }
    }

    function _requireRegistry(address registry) private view {
        if (registry == address(0) || registry.code.length == 0) {
            revert HTPErrors.InvalidDvpRegistry(registry);
        }
    }

    function _validateAdapters(
        SettlementParams calldata params,
        address assetAdapter,
        address settlementAdapter,
        bool strict,
        bytes32 settlementAdapterConfigId
    ) private view returns (Decision, bytes4) {
        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        AdapterValidationResult memory result = _callAdapter(
            assetAdapter,
            params.snapshot.assetToken,
            params.snapshot.seller,
            params.snapshot.buyer,
            params.snapshot.executedQuantity,
            TransferLeg.ASSET,
            snapshotHash
        );
        if (result.decision != Decision.PASS) {
            if (strict) {
                _revertAdapterFailure(
                    result.decision, params.snapshot.adapterConfigId, result.restrictionCode, result.reasonHash
                );
            }
            return (result.decision, result.reason);
        }

        if (params.snapshot.sellerCredit != 0) {
            result = _callAdapter(
                settlementAdapter,
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.seller,
                params.snapshot.sellerCredit,
                TransferLeg.SETTLEMENT_TO_SELLER,
                snapshotHash
            );
            if (result.decision != Decision.PASS) {
                if (strict) {
                    _revertAdapterFailure(
                        result.decision, settlementAdapterConfigId, result.restrictionCode, result.reasonHash
                    );
                }
                return (result.decision, result.reason);
            }
        }
        if (params.snapshot.collectorCredit != 0) {
            result = _callAdapter(
                settlementAdapter,
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.collector,
                params.snapshot.collectorCredit,
                TransferLeg.SETTLEMENT_TO_COLLECTOR,
                snapshotHash
            );
            if (result.decision != Decision.PASS) {
                if (strict) {
                    _revertAdapterFailure(
                        result.decision, settlementAdapterConfigId, result.restrictionCode, result.reasonHash
                    );
                }
                return (result.decision, result.reason);
            }
        }
        return (Decision.PASS, bytes4(0));
    }

    function _revertAdapterFailure(
        Decision decision,
        bytes32 adapterConfigId,
        uint256 restrictionCode,
        bytes32 reasonHash
    ) private pure {
        if (decision == Decision.BLOCK) {
            revert HTPErrors.TransferRestricted(adapterConfigId, restrictionCode, reasonHash);
        }
        revert HTPErrors.ExternalCallFailed(bytes4(0x4b5cf187));
    }

    // Adapter.preCheck(token, from, to, amount, leg, snapshotHash)。

    function _callAdapter(
        address adapter,
        address token,
        address from,
        address to,
        uint256 amount,
        TransferLeg leg,
        bytes32 snapshotHash
    ) private view returns (AdapterValidationResult memory result) {
        AdapterCallResult memory callResult;
        assembly ("memory-safe") {
            let input := mload(0x40)
            // Reviewed IAssetAdapter.preCheck selector; 100k remains subject to T374 gas evidence.
            mstore(input, shl(224, 0x4b5cf187))
            mstore(add(input, 0x04), token)
            mstore(add(input, 0x24), from)
            mstore(add(input, 0x44), to)
            mstore(add(input, 0x64), amount)
            mstore(add(input, 0x84), leg)
            mstore(add(input, 0xa4), snapshotHash)
            let output := add(input, 0xc4)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            mstore(add(output, 0x40), 0)
            mstore(callResult, staticcall(100000, adapter, input, 0xc4, output, 0x60))
            mstore(add(callResult, 0x20), eq(returndatasize(), 0x60))
            mstore(add(callResult, 0x40), mload(output))
            mstore(add(callResult, 0x60), mload(add(output, 0x20)))
            mstore(add(callResult, 0x80), mload(add(output, 0x40)))
        }
        uint256 rawDecision = uint256(callResult.decisionWord);
        if (!callResult.callSucceeded || !callResult.returnWellFormed || rawDecision > uint256(Decision.UNKNOWN)) {
            result.decision = Decision.UNKNOWN;
            result.reason = HTPErrors.ExternalCallFailed.selector;
            return result;
        }
        Decision adapterDecision = Decision(rawDecision);
        result.restrictionCode = uint256(callResult.restrictionCode);
        result.reasonHash = callResult.reasonHash;
        if (
            adapterDecision == Decision.PASS
                && (uint256(callResult.restrictionCode) != 0 || callResult.reasonHash != bytes32(0))
        ) {
            result.decision = Decision.UNKNOWN;
            result.reason = HTPErrors.ExternalCallFailed.selector;
            return result;
        }
        if (adapterDecision == Decision.BLOCK) {
            result.decision = Decision.BLOCK;
            result.reason = HTPErrors.TransferRestricted.selector;
            return result;
        }
        if (adapterDecision != Decision.PASS) {
            result.decision = Decision.UNKNOWN;
            result.reason = HTPErrors.TransferRestricted.selector;
            return result;
        }
        result.decision = Decision.PASS;
    }

    function _requireReasonAndEvidence(ReasonCode reason, bytes32 evidenceHash) private pure {
        if (reason == ReasonCode.NONE) revert HTPErrors.ReasonCodeRequired(reason);
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
    }

    function _cancelNonce(address signer, NonceType nonceType, uint256 nonce) private {
        if (nonceType != NonceType.MAKER_QUOTE && nonceType != NonceType.REQUESTER_TRADE) {
            revert HTPErrors.InvalidNonceType(nonceType);
        }
        NonceStatus status = getNonceStatus(signer, nonceType, nonce);
        if (status != NonceStatus.UNUSED) {
            revert HTPErrors.NonceUnavailable(signer, nonceType, nonce, status);
        }
        nonceStates[signer][nonceType][nonce] = NonceStatus.CANCELLED;
        emit NonceCancelled(block.chainid, signer, nonceType, nonce);
    }

    function _requireRoleHolder(bytes32 role, address account) private pure {
        if (account == address(0)) revert HTPErrors.InvalidRoleHolder(role, account);
    }
}
