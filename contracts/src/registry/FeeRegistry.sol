// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetVersionRegistry} from "../interfaces/IAssetVersionRegistry.sol";
import {ISettlementTokenRegistry} from "../interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {FeeScope} from "../libraries/FeeScope.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AssetClass,
    AssetVersionRecord,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    HTPTypes,
    ParticipantType,
    ReasonCode,
    RoundingMode,
    ScopeType,
    SettlementTokenRecord
} from "../types/HTPTypes.sol";
import {UUPSRegistryBase} from "./UUPSRegistryBase.sol";

/// @notice Fee policy epochs and scoped fee versions for settlement.
contract FeeRegistry is UUPSRegistryBase {
    event FeePolicyEpochCreated(
        uint256 chainId,
        uint64 indexed feePolicyEpoch,
        uint64 quoteValidFrom,
        uint64 quoteValidUntil,
        uint64 settlementValidUntil,
        bytes32 configHash,
        address actor
    );
    event FeePolicyEpochSealed(uint256 chainId, uint64 indexed feePolicyEpoch, bytes32 configHash, address actor);
    event FeePolicyEpochStatusChanged(
        uint256 chainId,
        uint64 indexed feePolicyEpoch,
        FeePolicyEpochStatus oldStatus,
        FeePolicyEpochStatus newStatus,
        bytes32 evidenceHash,
        address actor
    );
    event FeeVersionStatusChanged(
        uint256 chainId,
        bytes32 indexed feeVersionId,
        uint64 indexed feePolicyEpoch,
        FeeVersionStatus oldStatus,
        FeeVersionStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );
    event FeeVersionRegistered(
        uint256 chainId,
        bytes32 indexed feeVersionId,
        uint64 indexed feePolicyEpoch,
        bytes32 indexed matchedScopeHash,
        uint32 schemaVersion,
        uint32 revision,
        ScopeType scopeType,
        bytes32 scopeKeyHash,
        uint16 investorRateBps,
        bool investorHasCap,
        uint256 investorCapAmount,
        uint16 makerRateBps,
        bool makerHasCap,
        uint256 makerCapAmount,
        RoundingMode roundingMode,
        address settlementToken,
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        address collector,
        uint64 validFrom,
        uint64 validUntil,
        bytes32 feeConstraintHash,
        bytes32 replacesFeeVersionId,
        bytes32 configHash
    );

    /// @custom:storage-location erc7201:htp.storage.FeeRegistry
    struct FeeRegistryStorage {
        IAssetVersionRegistry assetVersionRegistry;
        ISettlementTokenRegistry settlementTokenRegistry;
        mapping(uint64 feePolicyEpoch => FeePolicyEpochRecord record) epochs;
        uint64 latestFeePolicyEpoch;
        uint64 currentActiveEpoch;
        mapping(bytes32 feeVersionId => FeeVersionRecord record) feeVersions;

        mapping(bytes32 matchedScopeHash => bytes32 feeVersionId) scopeFeeVersionIds;

        mapping(bytes32 matchedScopeHash => bytes32 feeVersionId) scopeServingFeeVersionIds;
    }

    // ERC-7201: htp.storage.FeeRegistry
    bytes32 private constant FEE_REGISTRY_STORAGE_LOCATION =
        0xd5f91eebe3c9b6fa2817be8e91330e55c686945f9635944b031ba5309bdb9900;
    bytes32 private constant FEE_VERSION_REGISTERED_TOPIC = keccak256(
        "FeeVersionRegistered(uint256,bytes32,uint64,bytes32,uint32,uint32,uint8,bytes32,uint16,bool,uint256,uint16,bool,uint256,uint8,address,bytes32,bytes32,address,uint64,uint64,bytes32,bytes32,bytes32)"
    );
    bytes32 private constant FEE_POLICY_EPOCH_CREATED_TOPIC =
        0x7d43dc3c6f3d57c8ffce1061fccada9efed53bdd2532405eea0827729c901898;
    bytes32 private constant FEE_POLICY_EPOCH_STATUS_CHANGED_TOPIC =
        0xf9d1ca1c9e871ddeaacba2df9f4251811de55de3ab43c351952aaaf3be3bd6f9;
    bytes32 private constant FEE_VERSION_STATUS_CHANGED_TOPIC =
        0x153dc82feef2c8ab13b7fa9eacad96bf7d19c84ce29014b2eea80c1bf30c14ee;

    function initialize(
        address defaultAdmin,
        address governance,
        address upgrader,
        address pauser,
        address configurer,
        address assetVersionRegistry_,
        address settlementTokenRegistry_
    ) external initializer {
        if (assetVersionRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(assetVersionRegistry_);
        }
        if (settlementTokenRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(settlementTokenRegistry_);
        }
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);

        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        $.assetVersionRegistry = IAssetVersionRegistry(assetVersionRegistry_);
        $.settlementTokenRegistry = ISettlementTokenRegistry(settlementTokenRegistry_);
    }

    /// @notice Opens the next sequential fee policy epoch (draft).
    function createFeePolicyEpoch(FeePolicyEpochConfig calldata config) external onlyRole(Roles.GOVERNANCE_ROLE) {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }

        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        if ($.epochs[config.feePolicyEpoch].exists) {
            revert HTPErrors.FeePolicyEpochAlreadyExists(config.feePolicyEpoch);
        }
        uint64 expectedEpoch = $.latestFeePolicyEpoch + 1;
        if (config.feePolicyEpoch != expectedEpoch) {
            revert HTPErrors.FeePolicyEpochSequenceMismatch(expectedEpoch, config.feePolicyEpoch);
        }
        if (
            config.quoteValidFrom == 0 || config.quoteValidFrom > config.quoteValidUntil
                || config.quoteValidUntil > config.settlementValidUntil
        ) {
            revert HTPErrors.InvalidFeePolicyEpochValidity(
                config.quoteValidFrom, config.quoteValidUntil, config.settlementValidUntil
            );
        }

        bytes32 recomputedConfigHash = _hashEpochCalldata(config);
        if (config.configHash != recomputedConfigHash) {
            revert HTPErrors.FeePolicyEpochConfigHashMismatch(config.configHash, recomputedConfigHash);
        }

        $.epochs[config.feePolicyEpoch] =
            FeePolicyEpochRecord({config: config, status: FeePolicyEpochStatus.DRAFT, isSealed: false, exists: true});
        $.latestFeePolicyEpoch = config.feePolicyEpoch;

        _emitFeePolicyEpochCreated(config);
    }

    function sealFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        FeePolicyEpochRecord storage record = _getFeeRegistryStorage().epochs[feePolicyEpoch];
        if (!record.exists) revert HTPErrors.FeePolicyEpochNotFound(feePolicyEpoch);
        if (record.isSealed) revert HTPErrors.FeePolicyEpochSealed(feePolicyEpoch);
        _requireEpochConfigHashes(record.config, expectedConfigHash);

        record.isSealed = true;
        emit FeePolicyEpochSealed(block.chainid, feePolicyEpoch, record.config.configHash, _msgSender());
    }

    function activateFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 expectedConfigHash, bytes32 readinessFeeVersionId)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        FeePolicyEpochRecord storage record = $.epochs[feePolicyEpoch];
        if (!record.exists) revert HTPErrors.FeePolicyEpochNotFound(feePolicyEpoch);
        if (!record.isSealed) revert HTPErrors.FeePolicyEpochNotSealed(feePolicyEpoch);
        if (record.status != FeePolicyEpochStatus.DRAFT) {
            revert HTPErrors.UnauthorizedStateTransition(
                bytes32(uint256(feePolicyEpoch)), uint8(record.status), uint8(FeePolicyEpochStatus.ACTIVE)
            );
        }
        if (block.timestamp < record.config.quoteValidFrom || block.timestamp > record.config.quoteValidUntil) {
            revert HTPErrors.FeePolicyEpochOutsideQuoteWindow(feePolicyEpoch, uint64(block.timestamp));
        }
        _requireEpochConfigHashes(record.config, expectedConfigHash);
        _requireFeeVersionReadyForEpoch(feePolicyEpoch, readinessFeeVersionId);

        uint64 oldActiveEpoch = $.currentActiveEpoch;
        if (oldActiveEpoch != 0) {
            FeePolicyEpochRecord storage oldActive = $.epochs[oldActiveEpoch];
            oldActive.status = FeePolicyEpochStatus.LEGACY_SERVING;
            _emitFeePolicyEpochStatusChanged(
                oldActiveEpoch, FeePolicyEpochStatus.ACTIVE, FeePolicyEpochStatus.LEGACY_SERVING, bytes32(0)
            );
        }

        record.status = FeePolicyEpochStatus.ACTIVE;
        $.currentActiveEpoch = feePolicyEpoch;
        _emitFeePolicyEpochStatusChanged(
            feePolicyEpoch, FeePolicyEpochStatus.DRAFT, FeePolicyEpochStatus.ACTIVE, bytes32(0)
        );
    }

    function moveFeePolicyEpochToLegacyServing(uint64 feePolicyEpoch, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _transitionExpiredEpoch(
            feePolicyEpoch, evidenceHash, FeePolicyEpochStatus.ACTIVE, FeePolicyEpochStatus.LEGACY_SERVING, false
        );
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        if ($.currentActiveEpoch == feePolicyEpoch) $.currentActiveEpoch = 0;
    }

    function closeFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 evidenceHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        _transitionExpiredEpoch(
            feePolicyEpoch, evidenceHash, FeePolicyEpochStatus.LEGACY_SERVING, FeePolicyEpochStatus.CLOSED, true
        );
    }

    /// @notice Registers a fee version under an unsealed epoch.
    function registerFeeVersion(FeeConfig calldata config) external onlyRole(Roles.CONFIGURER_ROLE) {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        _validateFeeConfigIdentity(config);
        if ($.feeVersions[config.feeVersionId].exists) {
            revert HTPErrors.ConfigAlreadyExists(config.feeVersionId);
        }

        FeePolicyEpochRecord storage epoch = $.epochs[config.feePolicyEpoch];
        if (!epoch.exists) revert HTPErrors.FeePolicyEpochNotFound(config.feePolicyEpoch);
        if (epoch.isSealed) revert HTPErrors.FeePolicyEpochSealed(config.feePolicyEpoch);

        _validateFeeScope(config);
        _validateFeeTerms(config, epoch.config);
        _validateSettlementToken(
            config.settlementTokenConfigId, config.settlementTokenConfigHash, config.settlementToken, false
        );

        bytes32 latestId = $.scopeFeeVersionIds[config.matchedScopeHash];
        uint32 expectedRevision = latestId == bytes32(0) ? 1 : $.feeVersions[latestId].config.revision + 1;
        if (config.revision != expectedRevision) {
            revert HTPErrors.ConfigRevisionMismatch(config.matchedScopeHash, expectedRevision, config.revision);
        }
        if (config.replacesFeeVersionId != latestId) {
            revert HTPErrors.ConfigReplacesMismatch(latestId, config.replacesFeeVersionId);
        }

        $.feeVersions[config.feeVersionId] =
            FeeVersionRecord({config: config, status: FeeVersionStatus.REGISTERED, exists: true});
        $.scopeFeeVersionIds[config.matchedScopeHash] = config.feeVersionId;
        _emitFeeVersionRegistered(config);
    }

    function activateFeeVersion(bytes32 feeVersionId, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        FeeVersionRecord storage record = _requireFeeVersionInMutableEpoch(feeVersionId);
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        FeePolicyEpochRecord storage epoch = $.epochs[record.config.feePolicyEpoch];
        if (epoch.status != FeePolicyEpochStatus.DRAFT) {
            revert HTPErrors.UnauthorizedStateTransition(
                feeVersionId, uint8(epoch.status), uint8(FeePolicyEpochStatus.DRAFT)
            );
        }
        _validateSettlementToken(
            record.config.settlementTokenConfigId,
            record.config.settlementTokenConfigHash,
            record.config.settlementToken,
            true
        );
        _requireStoredFeeConfigHash(record.config, expectedConfigHash);
        if (record.status != FeeVersionStatus.REGISTERED) {
            revert HTPErrors.UnauthorizedStateTransition(
                feeVersionId, uint8(record.status), uint8(FeeVersionStatus.ACTIVE)
            );
        }
        record.status = FeeVersionStatus.ACTIVE;
        $.scopeServingFeeVersionIds[record.config.matchedScopeHash] = feeVersionId;
        _emitFeeVersionStatusChanged(
            record.config, FeeVersionStatus.REGISTERED, FeeVersionStatus.ACTIVE, ReasonCode.NONE, bytes32(0)
        );
    }

    function pauseFeeVersion(bytes32 feeVersionId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        FeeVersionRecord storage record = _requireFeeVersionInMutableEpoch(feeVersionId);
        _requireReasonAndEvidence(reason, evidenceHash);
        FeeVersionStatus oldStatus = record.status;
        // N2: Preserve the lifecycle-specific target in both events and transition errors.
        FeeVersionStatus newStatus = oldStatus == FeeVersionStatus.DEPRECATED
            || oldStatus == FeeVersionStatus.DEPRECATED_PAUSED
            ? FeeVersionStatus.DEPRECATED_PAUSED
            : FeeVersionStatus.PAUSED;
        if (oldStatus != FeeVersionStatus.ACTIVE && oldStatus != FeeVersionStatus.DEPRECATED) {
            revert HTPErrors.UnauthorizedStateTransition(feeVersionId, uint8(oldStatus), uint8(newStatus));
        }
        record.status = newStatus;
        _emitFeeVersionStatusChanged(record.config, oldStatus, newStatus, reason, evidenceHash);
    }

    function unpauseFeeVersion(
        bytes32 feeVersionId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external onlyRole(Roles.GOVERNANCE_ROLE) {
        FeeVersionRecord storage record = _requireFeeVersionInMutableEpoch(feeVersionId);
        _requireReasonAndEvidence(reason, evidenceHash);
        _validateSettlementToken(
            record.config.settlementTokenConfigId,
            record.config.settlementTokenConfigHash,
            record.config.settlementToken,
            true
        );
        _requireStoredFeeConfigHash(record.config, expectedConfigHash);
        FeeVersionStatus oldStatus = record.status;
        // N2: A paused deprecated version returns to DEPRECATED, never ACTIVE.
        FeeVersionStatus newStatus = oldStatus == FeeVersionStatus.DEPRECATED
            || oldStatus == FeeVersionStatus.DEPRECATED_PAUSED
            ? FeeVersionStatus.DEPRECATED
            : FeeVersionStatus.ACTIVE;
        if (oldStatus != FeeVersionStatus.PAUSED && oldStatus != FeeVersionStatus.DEPRECATED_PAUSED) {
            revert HTPErrors.UnauthorizedStateTransition(feeVersionId, uint8(oldStatus), uint8(newStatus));
        }
        record.status = newStatus;
        _emitFeeVersionStatusChanged(record.config, oldStatus, newStatus, reason, evidenceHash);
    }

    function deprecateFeeVersion(bytes32 feeVersionId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        FeeVersionRecord storage record = _requireFeeVersionInMutableEpoch(feeVersionId);
        _requireReasonAndEvidence(reason, evidenceHash);
        FeeVersionStatus oldStatus = record.status;
        if (oldStatus != FeeVersionStatus.ACTIVE) {
            revert HTPErrors.UnauthorizedStateTransition(
                feeVersionId, uint8(oldStatus), uint8(FeeVersionStatus.DEPRECATED)
            );
        }
        record.status = FeeVersionStatus.DEPRECATED;
        _emitFeeVersionStatusChanged(record.config, oldStatus, FeeVersionStatus.DEPRECATED, reason, evidenceHash);
    }

    function getFeePolicyEpoch(uint64 feePolicyEpoch) external view returns (FeePolicyEpochRecord memory) {
        return _getFeeRegistryStorage().epochs[feePolicyEpoch];
    }

    function getFeeVersion(bytes32 feeVersionId) external view returns (FeeVersionRecord memory record) {
        return _getFeeRegistryStorage().feeVersions[feeVersionId];
    }

    /// @notice Resolves highest-priority active fee version for an asset version.
    function resolveApplicableFee(uint64 feePolicyEpoch, bytes32 assetVersionId)
        external
        view
        returns (bytes32 feeVersionId, bytes32 matchedScopeHash)
    {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        FeePolicyEpochRecord storage epoch = $.epochs[feePolicyEpoch];
        if (!epoch.exists) revert HTPErrors.FeePolicyEpochNotFound(feePolicyEpoch);
        if (!epoch.isSealed) revert HTPErrors.FeePolicyEpochNotSealed(feePolicyEpoch);
        if (epoch.status != FeePolicyEpochStatus.ACTIVE && epoch.status != FeePolicyEpochStatus.LEGACY_SERVING) {
            revert HTPErrors.FeePolicyEpochNotServiceable(feePolicyEpoch, epoch.status);
        }

        AssetVersionRecord memory asset = $.assetVersionRegistry.getAssetVersion(assetVersionId);
        if (!asset.exists) revert HTPErrors.ConfigNotFound(assetVersionId);
        (bool found, bytes32 resolvedFeeVersionId, bytes32 resolvedMatchedScopeHash) =
            _findApplicableFee(feePolicyEpoch, assetVersionId, asset);
        if (found) return (resolvedFeeVersionId, resolvedMatchedScopeHash);
        revert HTPErrors.FeeResolverNoMatch(feePolicyEpoch, assetVersionId);
    }

    /// @notice Whether snapshot fee fields match a serviceable registry fee version.
    function isFeeVersionExecutable(
        uint64 feePolicyEpoch,
        bytes32 assetVersionId,
        bytes32 feeVersionId,
        bytes32 matchedScopeHash,
        bytes32 feeConstraintHash
    ) external view returns (bool) {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        FeePolicyEpochRecord storage epoch = $.epochs[feePolicyEpoch];
        if (
            !epoch.isSealed
                || (epoch.status != FeePolicyEpochStatus.ACTIVE && epoch.status != FeePolicyEpochStatus.LEGACY_SERVING)
        ) {
            return false;
        }

        AssetVersionRecord memory asset = $.assetVersionRegistry.getAssetVersion(assetVersionId);
        if (!asset.exists) return false;
        (bool found, bytes32 resolvedFeeVersionId, bytes32 resolvedMatchedScopeHash) =
            _findApplicableFee(feePolicyEpoch, assetVersionId, asset);
        if (!found || resolvedFeeVersionId != feeVersionId || resolvedMatchedScopeHash != matchedScopeHash) {
            return false;
        }

        FeeVersionRecord storage record = $.feeVersions[feeVersionId];
        // N2: Only unpaused lifecycle states are executable.
        if (record.status != FeeVersionStatus.ACTIVE && record.status != FeeVersionStatus.DEPRECATED) {
            return false;
        }
        FeeConfig storage config = record.config;
        return config.feeConstraintHash == feeConstraintHash && block.timestamp >= config.validFrom
            && block.timestamp <= config.validUntil
            && _isSettlementTokenValid(
            config.settlementTokenConfigId, config.settlementTokenConfigHash, config.settlementToken, true
        );
    }

    function _findApplicableFee(uint64 feePolicyEpoch, bytes32 assetVersionId, AssetVersionRecord memory asset)
        private
        view
        returns (bool found, bytes32 feeVersionId, bytes32 matchedScopeHash)
    {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        bytes32[5] memory scopeKeys;
        scopeKeys[0] = assetVersionId;
        scopeKeys[1] = asset.config.economicAssetIdHash;
        scopeKeys[2] = bytes32(uint256(asset.config.assetClass));
        scopeKeys[3] = bytes32(asset.config.chainId);
        ScopeType[5] memory scopeTypes = FeeScope.priority();
        for (uint256 i = 0; i < scopeKeys.length;) {
            matchedScopeHash = FeeScope.matchedHashWithoutValidation(feePolicyEpoch, scopeTypes[i], scopeKeys[i]);
            feeVersionId = $.scopeServingFeeVersionIds[matchedScopeHash];
            if (feeVersionId != bytes32(0)) {
                return (true, feeVersionId, matchedScopeHash);
            }
            unchecked {
                ++i;
            }
        }
        return (false, bytes32(0), bytes32(0));
    }

    function _validateFeeConfigIdentity(FeeConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }
        bytes32 recomputedId = ConfigId.derive(
            ConfigId.FEE_NAMESPACE, config.schemaVersion, block.chainid, config.matchedScopeHash, config.revision
        );
        if (config.feeVersionId != recomputedId) {
            revert HTPErrors.ConfigIdMismatch(config.feeVersionId, recomputedId);
        }
        bytes32 recomputedConfigHash = _hashFeeConfigCalldata(config);
        if (config.configHash != recomputedConfigHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedConfigHash);
        }
    }

    function _validateFeeScope(FeeConfig calldata config) private view {
        bytes32 recomputedMatchedScopeHash =
            FeeScope.matchedHashWithoutValidation(config.feePolicyEpoch, config.scopeType, config.scopeKeyHash);
        if (config.matchedScopeHash != recomputedMatchedScopeHash) {
            revert HTPErrors.FeeMatchedScopeHashMismatch(config.matchedScopeHash, recomputedMatchedScopeHash);
        }

        uint8 scope = uint8(config.scopeType);
        bool valid = scope >= uint8(ScopeType.GLOBAL) && scope <= uint8(ScopeType.ASSET_VERSION);
        if (scope == uint8(ScopeType.GLOBAL)) {
            valid = config.scopeKeyHash == bytes32(0);
        } else if (scope == uint8(ScopeType.CHAIN)) {
            valid = config.scopeKeyHash == bytes32(block.chainid);
        } else if (scope == uint8(ScopeType.ASSET_CLASS)) {
            uint256 value = uint256(config.scopeKeyHash);
            valid = value >= uint8(AssetClass.STOCK) && value <= uint8(AssetClass.BOND);
        } else if (valid) {
            valid = config.scopeKeyHash != bytes32(0);
        }
        if (!valid) revert HTPErrors.InvalidFeeScopeKey(config.scopeType, config.scopeKeyHash);
    }

    function _validateFeeTerms(FeeConfig calldata config, FeePolicyEpochConfig storage epoch) private view {
        if (config.investorRateBps > 10_000) {
            revert HTPErrors.FeeRateOutOfRange(ParticipantType.INVESTOR, config.investorRateBps);
        }
        if (config.makerRateBps > 10_000) {
            revert HTPErrors.FeeRateOutOfRange(ParticipantType.MAKER, config.makerRateBps);
        }

        uint16 higherRateBps =
            config.investorRateBps > config.makerRateBps ? config.investorRateBps : config.makerRateBps;
        uint256 worstCaseAggregateBps = 2 * uint256(higherRateBps);
        if (worstCaseAggregateBps > FeeMath.MAX_AGGREGATE_FEE_BPS) {
            revert HTPErrors.AggregateFeeRateOutOfRange(worstCaseAggregateBps, FeeMath.MAX_AGGREGATE_FEE_BPS);
        }
        if (!config.investorHasCap && config.investorCapAmount != 0) {
            revert HTPErrors.FeeCapNotCanonical(
                ParticipantType.INVESTOR, config.investorHasCap, config.investorCapAmount
            );
        }
        if (!config.makerHasCap && config.makerCapAmount != 0) {
            revert HTPErrors.FeeCapNotCanonical(ParticipantType.MAKER, config.makerHasCap, config.makerCapAmount);
        }
        if (
            config.roundingMode != RoundingMode.DOWN || config.settlementToken == address(0)
                || config.settlementTokenConfigId == bytes32(0) || config.settlementTokenConfigHash == bytes32(0)
                || config.collector == address(0)
        ) {
            revert HTPErrors.InvalidFeeConfig();
        }
        if (
            config.validFrom == 0 || config.validUntil < config.validFrom || config.validFrom < epoch.quoteValidFrom
                || config.validUntil > epoch.settlementValidUntil
        ) {
            revert HTPErrors.FeeValidityOutsideEpoch(config.feePolicyEpoch, config.validFrom, config.validUntil);
        }
        bytes32 recomputedConstraintHash = _hashFeeConstraintCalldata(config);
        if (config.feeConstraintHash != recomputedConstraintHash) {
            revert HTPErrors.FeeConstraintHashMismatch(config.feeConstraintHash, recomputedConstraintHash);
        }
    }

    function _validateSettlementToken(
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        address settlementToken,
        bool requireActive
    ) private view {
        if (!_isSettlementTokenValid(
                settlementTokenConfigId, settlementTokenConfigHash, settlementToken, requireActive
            )) {
            revert HTPErrors.ConfigReferenceMismatch(settlementTokenConfigId, settlementTokenConfigHash);
        }
    }

    function _isSettlementTokenValid(
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        address settlementToken,
        bool requireActive
    ) private view returns (bool) {
        ISettlementTokenRegistry registry = _getFeeRegistryStorage().settlementTokenRegistry;
        SettlementTokenRecord memory token = registry.getSettlementToken(settlementTokenConfigId);
        if (token.config.settlementToken != settlementToken) return false;
        return requireActive
            ? registry.isSettlementTokenConfigActive(settlementTokenConfigId, settlementTokenConfigHash)
            : registry.isSettlementTokenConfigRegisterable(settlementTokenConfigId, settlementTokenConfigHash);
    }

    function _requireFeeVersionInMutableEpoch(bytes32 feeVersionId)
        private
        view
        returns (FeeVersionRecord storage record)
    {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        record = $.feeVersions[feeVersionId];
        if (!record.exists) revert HTPErrors.ConfigNotFound(feeVersionId);
        FeePolicyEpochRecord storage epoch = $.epochs[record.config.feePolicyEpoch];
        if (!epoch.isSealed) revert HTPErrors.FeePolicyEpochNotSealed(record.config.feePolicyEpoch);
    }

    function _requireFeeVersionReadyForEpoch(uint64 feePolicyEpoch, bytes32 feeVersionId) private view {
        FeeRegistryStorage storage $ = _getFeeRegistryStorage();
        FeeVersionRecord storage record = $.feeVersions[feeVersionId];
        FeeConfig storage config = record.config;
        // N1: Recheck the selected serving fee and its runtime dependency before committing the epoch.
        if (
            !record.exists || config.feePolicyEpoch != feePolicyEpoch || record.status != FeeVersionStatus.ACTIVE
                || $.scopeServingFeeVersionIds[config.matchedScopeHash] != feeVersionId
                || block.timestamp < config.validFrom || block.timestamp > config.validUntil
                || !_isSettlementTokenValid(
                    config.settlementTokenConfigId, config.settlementTokenConfigHash, config.settlementToken, true
                )
        ) {
            revert HTPErrors.FeePolicyEpochFeeNotReady(feePolicyEpoch, feeVersionId);
        }
    }

    function _requireStoredFeeConfigHash(FeeConfig storage config, bytes32 expectedConfigHash) private view {
        if (expectedConfigHash != config.configHash) {
            revert HTPErrors.ConfigHashMismatch(expectedConfigHash, config.configHash);
        }
    }

    function _emitFeeVersionStatusChanged(
        FeeConfig storage config,
        FeeVersionStatus oldStatus,
        FeeVersionStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash
    ) private {
        bytes32 eventTopic = FEE_VERSION_STATUS_CHANGED_TOPIC;
        bytes32 feeVersionId = config.feeVersionId;
        bytes32 feePolicyEpoch = bytes32(uint256(config.feePolicyEpoch));
        address actor = _msgSender();
        assembly ("memory-safe") {
            let encodedData := mload(0x40)
            mstore(encodedData, chainid())
            mstore(add(encodedData, 0x20), oldStatus)
            mstore(add(encodedData, 0x40), newStatus)
            mstore(add(encodedData, 0x60), reason)
            mstore(add(encodedData, 0x80), evidenceHash)
            mstore(add(encodedData, 0xa0), actor)
            log3(encodedData, 0xc0, eventTopic, feeVersionId, feePolicyEpoch)
        }
    }

    function _emitFeePolicyEpochCreated(FeePolicyEpochConfig calldata config) private {
        bytes32 eventTopic = FEE_POLICY_EPOCH_CREATED_TOPIC;
        bytes32 epochTopic = bytes32(uint256(config.feePolicyEpoch));
        address actor = _msgSender();
        assembly ("memory-safe") {
            let encodedData := mload(0x40)
            mstore(encodedData, chainid())
            calldatacopy(add(encodedData, 0x20), add(config, 0x60), 0x80)
            mstore(add(encodedData, 0xa0), actor)
            log2(encodedData, 0xc0, eventTopic, epochTopic)
        }
    }

    function _emitFeePolicyEpochStatusChanged(
        uint64 feePolicyEpoch,
        FeePolicyEpochStatus oldStatus,
        FeePolicyEpochStatus newStatus,
        bytes32 evidenceHash
    ) private {
        bytes32 eventTopic = FEE_POLICY_EPOCH_STATUS_CHANGED_TOPIC;
        bytes32 epochTopic = bytes32(uint256(feePolicyEpoch));
        address actor = _msgSender();
        assembly ("memory-safe") {
            let encodedData := mload(0x40)
            mstore(encodedData, chainid())
            mstore(add(encodedData, 0x20), oldStatus)
            mstore(add(encodedData, 0x40), newStatus)
            mstore(add(encodedData, 0x60), evidenceHash)
            mstore(add(encodedData, 0x80), actor)
            log2(encodedData, 0xa0, eventTopic, epochTopic)
        }
    }

    function _emitFeeVersionRegistered(FeeConfig calldata config) private {
        bytes32 eventTopic = FEE_VERSION_REGISTERED_TOPIC;
        bytes32 feeVersionId = config.feeVersionId;
        bytes32 feePolicyEpoch = bytes32(uint256(config.feePolicyEpoch));
        bytes32 matchedScopeHash = config.matchedScopeHash;
        assembly ("memory-safe") {
            let encodedData := mload(0x40)
            mstore(encodedData, chainid())
            calldatacopy(add(encodedData, 0x20), config, 0x20)
            calldatacopy(add(encodedData, 0x40), add(config, 0x40), 0x20)
            calldatacopy(add(encodedData, 0x60), add(config, 0xa0), 0x40)
            calldatacopy(add(encodedData, 0xa0), add(config, 0x100), 0x200)
            mstore(0x40, add(encodedData, 0x2a0))
            log4(encodedData, 0x2a0, eventTopic, feeVersionId, feePolicyEpoch, matchedScopeHash)
        }
    }

    function _requireEpochConfigHashes(FeePolicyEpochConfig memory config, bytes32 expectedConfigHash) private pure {
        bytes32 recomputedConfigHash = _hashEpochMemory(config);
        if (expectedConfigHash != config.configHash || config.configHash != recomputedConfigHash) {
            revert HTPErrors.FeePolicyEpochExpectedHashMismatch(
                expectedConfigHash, config.configHash, recomputedConfigHash
            );
        }
    }

    function _transitionExpiredEpoch(
        uint64 feePolicyEpoch,
        bytes32 evidenceHash,
        FeePolicyEpochStatus oldStatus,
        FeePolicyEpochStatus newStatus,
        bool useSettlementWindow
    ) private {
        FeePolicyEpochRecord storage record = _getFeeRegistryStorage().epochs[feePolicyEpoch];
        if (!record.exists) revert HTPErrors.FeePolicyEpochNotFound(feePolicyEpoch);
        if (record.status != oldStatus) {
            revert HTPErrors.UnauthorizedStateTransition(
                bytes32(uint256(feePolicyEpoch)), uint8(record.status), uint8(newStatus)
            );
        }
        _requireReasonAndEvidence(ReasonCode.GOVERNANCE_ACTION, evidenceHash);
        uint64 deadline = useSettlementWindow ? record.config.settlementValidUntil : record.config.quoteValidUntil;
        if (block.timestamp <= deadline) {
            revert HTPErrors.FeePolicyEpochTransitionTooEarly(feePolicyEpoch, deadline + 1, uint64(block.timestamp));
        }
        record.status = newStatus;
        _emitFeePolicyEpochStatusChanged(feePolicyEpoch, oldStatus, newStatus, evidenceHash);
    }

    function _hashEpochCalldata(FeePolicyEpochConfig calldata config) private pure returns (bytes32 result) {
        bytes32 typeHash = HTPHashing.FEE_POLICY_EPOCH_CONFIG_TYPEHASH;
        assembly ("memory-safe") {
            let encoded := mload(0x40)
            mstore(encoded, typeHash)
            calldatacopy(add(encoded, 0x20), config, 0xc0)
            result := keccak256(encoded, 0xe0)
        }
    }

    function _hashEpochMemory(FeePolicyEpochConfig memory config) private pure returns (bytes32 result) {
        bytes32 typeHash = HTPHashing.FEE_POLICY_EPOCH_CONFIG_TYPEHASH;
        assembly ("memory-safe") {
            let encoded := mload(0x40)
            mstore(encoded, typeHash)
            for { let offset := 0 } lt(offset, 0xc0) { offset := add(offset, 0x20) } {
                mstore(add(add(encoded, 0x20), offset), mload(add(config, offset)))
            }
            result := keccak256(encoded, 0xe0)
        }
    }

    function _hashFeeConfigCalldata(FeeConfig calldata config) private pure returns (bytes32 result) {
        bytes32 typeHash = HTPHashing.FEE_CONFIG_TYPEHASH;
        assembly ("memory-safe") {
            let encoded := mload(0x40)
            mstore(encoded, typeHash)
            calldatacopy(add(encoded, 0x20), config, 0x2e0)
            result := keccak256(encoded, 0x300)
        }
    }

    function _hashFeeConstraintCalldata(FeeConfig calldata config) private pure returns (bytes32 result) {
        bytes32 typeHash = HTPHashing.FEE_CONSTRAINT_TYPEHASH;
        assembly ("memory-safe") {
            let encoded := mload(0x40)
            mstore(encoded, typeHash)
            calldatacopy(add(encoded, 0x20), add(config, 0x80), 0x20)
            calldatacopy(add(encoded, 0x40), add(config, 0x20), 0x20)
            calldatacopy(add(encoded, 0x60), add(config, 0xe0), 0x20)
            calldatacopy(add(encoded, 0x80), add(config, 0x100), 0x1a0)
            result := keccak256(encoded, 0x220)
        }
    }

    function _getFeeRegistryStorage() private pure returns (FeeRegistryStorage storage $) {
        assembly {
            $.slot := FEE_REGISTRY_STORAGE_LOCATION
        }
    }
}
