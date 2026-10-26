// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetVersionRegistry} from "../interfaces/IAssetVersionRegistry.sol";
import {IMarketRuleRegistry} from "../interfaces/IMarketRuleRegistry.sol";
import {ISettlementTokenRegistry} from "../interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {PrincipalMath} from "../libraries/PrincipalMath.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AssetClass,
    AssetVersionRecord,
    AssetVersionStatus,
    HTPTypes,
    MarketRuleConfig,
    MarketRuleRecord,
    MarketRuleStatus,
    ReasonCode,
    SettlementTokenRecord
} from "../types/HTPTypes.sol";
import {UUPSRegistryBase} from "./UUPSRegistryBase.sol";

/// @notice Per-asset-version market rules (quantity, price ticks, validity windows).
contract MarketRuleRegistry is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.MarketRuleRegistry
    struct MarketRuleRegistryStorage {
        IAssetVersionRegistry assetVersionRegistry;
        ISettlementTokenRegistry settlementTokenRegistry;
        mapping(bytes32 configId => MarketRuleRecord record) records;
        mapping(bytes32 assetVersionId => bytes32 configId) latestConfigIds;
        mapping(bytes32 assetVersionId => bytes32 configId) currentConfigIds;
        mapping(bytes32 assetVersionId => mapping(uint32 revision => bytes32 configId)) configIdsByRevision;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.MarketRuleRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKET_RULE_REGISTRY_STORAGE_LOCATION =
        0xeb21d333001ce399c618e2cbf5ecd60ed16938a2f6e71320d97155b0ce947f00;

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
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        $.assetVersionRegistry = IAssetVersionRegistry(assetVersionRegistry_);
        $.settlementTokenRegistry = ISettlementTokenRegistry(settlementTokenRegistry_);
    }

    /// @notice Registers the next revision of a market rule (draft).
    function registerMarketRule(MarketRuleConfig calldata config) external onlyRole(Roles.CONFIGURER_ROLE) {
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        _validateIdentity(config);
        if ($.records[config.marketRuleConfigId].exists) {
            revert HTPErrors.ConfigAlreadyExists(config.marketRuleConfigId);
        }
        if ($.configIdsByRevision[config.assetVersionId][config.revision] != bytes32(0)) {
            revert HTPErrors.ConfigRevisionAlreadyExists(
                config.assetVersionId, config.revision, $.configIdsByRevision[config.assetVersionId][config.revision]
            );
        }
        _validateReferencesAndRules(config, false);

        bytes32 latestId = $.latestConfigIds[config.assetVersionId];
        uint32 expectedRevision = latestId == bytes32(0) ? 1 : $.records[latestId].config.revision + 1;
        if (config.revision != expectedRevision) {
            revert HTPErrors.ConfigRevisionMismatch(config.assetVersionId, expectedRevision, config.revision);
        }
        if (config.replacesConfigId != latestId) {
            revert HTPErrors.ConfigReplacesMismatch(latestId, config.replacesConfigId);
        }

        $.records[config.marketRuleConfigId] = MarketRuleRecord({
            config: config, status: MarketRuleStatus.DRAFT, isSealed: false, paused: false, exists: true
        });
        $.configIdsByRevision[config.assetVersionId][config.revision] = config.marketRuleConfigId;
        $.latestConfigIds[config.assetVersionId] = config.marketRuleConfigId;
        emit IMarketRuleRegistry.MarketRuleRegistered(
            block.chainid,
            config.marketRuleConfigId,
            config.assetVersionId,
            config.revision,
            config.replacesConfigId,
            config.configHash,
            _msgSender()
        );
    }

    /// @notice Freezes config content before activation.
    function sealMarketRule(bytes32 configId, bytes32 expectedConfigHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        MarketRuleRecord storage record = _requireRecord(configId);
        if (record.isSealed) revert HTPErrors.MarketRuleAlreadySealed(configId);
        if (record.status != MarketRuleStatus.DRAFT) {
            revert HTPErrors.UnauthorizedStateTransition(configId, uint8(record.status), uint8(MarketRuleStatus.DRAFT));
        }
        _requireConfigHash(record.config, expectedConfigHash);
        record.isSealed = true;
        emit IMarketRuleRegistry.MarketRuleSealed(block.chainid, configId, record.config.configHash, _msgSender());
    }

    /// @notice Activates sealed rule and demotes prior current to legacy serving.
    function activateMarketRule(bytes32 configId, bytes32 expectedConfigHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        MarketRuleRecord storage record = _requireRecord(configId);
        if (!record.isSealed) revert HTPErrors.MarketRuleNotSealed(configId);
        if (record.status != MarketRuleStatus.DRAFT) {
            revert HTPErrors.UnauthorizedStateTransition(configId, uint8(record.status), uint8(MarketRuleStatus.ACTIVE));
        }
        if ($.latestConfigIds[record.config.assetVersionId] != configId) {
            revert HTPErrors.ConfigNotLatest(configId, $.latestConfigIds[record.config.assetVersionId]);
        }
        if (block.timestamp < record.config.quoteValidFrom || block.timestamp > record.config.quoteValidUntil) {
            revert HTPErrors.MarketRuleOutsideQuoteWindow(configId, uint64(block.timestamp));
        }
        _requireConfigHash(record.config, expectedConfigHash);
        _validateReferencesAndRules(record.config, true);

        bytes32 oldCurrent = $.currentConfigIds[record.config.assetVersionId];
        if (oldCurrent != bytes32(0)) {
            MarketRuleRecord storage previous = $.records[oldCurrent];
            MarketRuleStatus oldStatus = previous.status;
            if (oldStatus != MarketRuleStatus.ACTIVE) {
                revert HTPErrors.UnauthorizedStateTransition(
                    oldCurrent, uint8(oldStatus), uint8(MarketRuleStatus.LEGACY_SERVING)
                );
            }
            previous.status = MarketRuleStatus.LEGACY_SERVING;
            emit IMarketRuleRegistry.MarketRuleStatusChanged(
                block.chainid,
                oldCurrent,
                previous.config.assetVersionId,
                oldStatus,
                MarketRuleStatus.LEGACY_SERVING,
                bytes32(0),
                _msgSender()
            );
        }
        record.status = MarketRuleStatus.ACTIVE;
        $.currentConfigIds[record.config.assetVersionId] = configId;
        emit IMarketRuleRegistry.MarketRuleStatusChanged(
            block.chainid,
            configId,
            record.config.assetVersionId,
            MarketRuleStatus.DRAFT,
            MarketRuleStatus.ACTIVE,
            bytes32(0),
            _msgSender()
        );
        emit IMarketRuleRegistry.CurrentMarketRuleChanged(
            block.chainid, record.config.assetVersionId, oldCurrent, configId, _msgSender()
        );
    }

    function pauseMarketRule(bytes32 configId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        MarketRuleRecord storage record = _requireServiceableStatus(configId);
        _requireReasonAndEvidence(reason, evidenceHash);
        if (record.paused) revert HTPErrors.MarketRulePaused(configId);
        record.paused = true;
        emit IMarketRuleRegistry.MarketRulePauseChanged(
            block.chainid, configId, true, reason, evidenceHash, _msgSender()
        );
    }

    function unpauseMarketRule(bytes32 configId, bytes32 expectedConfigHash, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        MarketRuleRecord storage record = _requireServiceableStatus(configId);
        _requireReasonAndEvidence(reason, evidenceHash);
        if (!record.paused) revert HTPErrors.ContractNotPaused();
        _requireConfigHash(record.config, expectedConfigHash);
        _validateReferencesAndRules(record.config, true);
        record.paused = false;
        emit IMarketRuleRegistry.MarketRulePauseChanged(
            block.chainid, configId, false, reason, evidenceHash, _msgSender()
        );
    }

    function closeMarketRule(bytes32 configId, bytes32 evidenceHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        MarketRuleRecord storage record = _requireServiceableStatus(configId);
        _requireReasonAndEvidence(ReasonCode.GOVERNANCE_ACTION, evidenceHash);
        if (block.timestamp <= record.config.settlementValidUntil) {
            revert HTPErrors.MarketRuleTransitionTooEarly(
                configId, record.config.settlementValidUntil + 1, uint64(block.timestamp)
            );
        }
        MarketRuleStatus oldStatus = record.status;
        bool wasPaused = record.paused;
        record.status = MarketRuleStatus.CLOSED;
        record.paused = false;
        // N8: Keep independently replayed pause state consistent with storage on close.
        if (wasPaused) {
            emit IMarketRuleRegistry.MarketRulePauseChanged(
                block.chainid, configId, false, ReasonCode.GOVERNANCE_ACTION, evidenceHash, _msgSender()
            );
        }
        if ($.currentConfigIds[record.config.assetVersionId] == configId) {
            $.currentConfigIds[record.config.assetVersionId] = bytes32(0);
            emit IMarketRuleRegistry.CurrentMarketRuleChanged(
                block.chainid, record.config.assetVersionId, configId, bytes32(0), _msgSender()
            );
        }
        emit IMarketRuleRegistry.MarketRuleStatusChanged(
            block.chainid,
            configId,
            record.config.assetVersionId,
            oldStatus,
            MarketRuleStatus.CLOSED,
            evidenceHash,
            _msgSender()
        );
    }

    function getMarketRule(bytes32 configId) external view returns (MarketRuleRecord memory) {
        return _getMarketRuleRegistryStorage().records[configId];
    }

    function getCurrentMarketRule(bytes32 assetVersionId) external view returns (MarketRuleRecord memory) {
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        return $.records[$.currentConfigIds[assetVersionId]];
    }

    /// @notice Whether a rule may bind quotes and settle trades in the given windows.
    function isMarketRuleServiceable(
        bytes32 configId,
        bytes32 expectedConfigHash,
        bytes32 assetVersionId,
        uint64 quoteCreatedAt,
        uint64 quoteExpiresAt,
        uint64 tradeDeadline
    ) external view returns (bool) {
        MarketRuleRecord storage record = _getMarketRuleRegistryStorage().records[configId];
        MarketRuleConfig storage config = record.config;
        return record.exists && record.isSealed && !record.paused
            && (record.status == MarketRuleStatus.ACTIVE || record.status == MarketRuleStatus.LEGACY_SERVING)
            && config.configHash == expectedConfigHash && HTPHashing.hashMarketRuleConfig(config) == expectedConfigHash
            && config.assetVersionId == assetVersionId && quoteCreatedAt >= config.quoteValidFrom
            && quoteCreatedAt <= config.quoteValidUntil && quoteCreatedAt <= block.timestamp
            && tradeDeadline <= quoteExpiresAt && quoteExpiresAt <= config.settlementValidUntil
            && tradeDeadline <= config.settlementValidUntil;
    }

    function _validateIdentity(MarketRuleConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }
        bytes32 recomputedId = ConfigId.derive(
            ConfigId.MARKET_RULE_NAMESPACE, config.schemaVersion, config.chainId, config.assetVersionId, config.revision
        );
        if (config.marketRuleConfigId != recomputedId) {
            revert HTPErrors.ConfigIdMismatch(config.marketRuleConfigId, recomputedId);
        }
        bytes32 recomputedHash = HTPHashing.hashMarketRuleConfig(config);
        if (config.configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedHash);
        }
    }

    function _validateReferencesAndRules(MarketRuleConfig memory config, bool requireActive) private view {
        MarketRuleRegistryStorage storage $ = _getMarketRuleRegistryStorage();
        AssetVersionRecord memory asset = $.assetVersionRegistry.getAssetVersion(config.assetVersionId);
        if (
            !asset.exists || asset.config.assetVersionId != config.assetVersionId
                || (requireActive && asset.status != AssetVersionStatus.ACTIVE)
                || asset.config.assetClass == AssetClass.NONE || uint8(asset.config.assetClass) > uint8(AssetClass.BOND)
        ) revert HTPErrors.ConfigReferenceMismatch(config.assetVersionId, bytes32(0));

        ISettlementTokenRegistry settlementTokenRegistry = $.settlementTokenRegistry;

        bool settlementUsable = requireActive
            ? settlementTokenRegistry.isSettlementTokenConfigActive(
                config.settlementTokenConfigId, config.settlementTokenConfigHash
            )
            : settlementTokenRegistry.isSettlementTokenConfigRegisterable(
                config.settlementTokenConfigId, config.settlementTokenConfigHash
            );
        SettlementTokenRecord memory settlement =
            settlementTokenRegistry.getSettlementToken(config.settlementTokenConfigId);
        if (
            !settlementUsable || settlement.config.settlementToken != config.settlementToken
                || asset.config.settlementToken != config.settlementToken
                || asset.config.settlementTokenConfigId != config.settlementTokenConfigId
                || asset.config.settlementTokenConfigHash != config.settlementTokenConfigHash
        ) {
            revert HTPErrors.ConfigReferenceMismatch(config.settlementTokenConfigId, config.settlementTokenConfigHash);
        }
        if (
            config.minCashPrincipal == 0 || config.minExecutableQuantity == 0 || config.quantityStep == 0
                || config.priceTick == 0 || config.priceDecimals == 0 || config.quantityDecimals == 0
                || config.quoteValidFrom == 0 || config.quoteValidFrom > config.quoteValidUntil
                || config.quoteValidUntil > config.settlementValidUntil
                || asset.config.assetDecimals > PrincipalMath.MAX_ASSET_DECIMALS
                || settlement.config.settlementTokenDecimals > PrincipalMath.MAX_ASSET_DECIMALS
                || config.quantityDecimals > asset.config.assetDecimals
                || config.priceDecimals > settlement.config.settlementTokenDecimals
        ) revert HTPErrors.InvalidMarketRule();

        uint256 quantityQuantum = 10 ** uint256(asset.config.assetDecimals - config.quantityDecimals);
        uint256 priceQuantum = 10 ** uint256(settlement.config.settlementTokenDecimals - config.priceDecimals);
        if (
            config.minExecutableQuantity % quantityQuantum != 0 || config.quantityStep % quantityQuantum != 0
                || config.priceTick % priceQuantum != 0
        ) revert HTPErrors.InvalidMarketRule();
    }

    function _requireConfigHash(MarketRuleConfig storage config, bytes32 expectedConfigHash) private view {
        bytes32 recomputed = HTPHashing.hashMarketRuleConfig(config);
        if (expectedConfigHash != config.configHash || recomputed != config.configHash) {
            revert HTPErrors.ConfigHashMismatch(expectedConfigHash, recomputed);
        }
    }

    function _requireRecord(bytes32 configId) private view returns (MarketRuleRecord storage record) {
        record = _getMarketRuleRegistryStorage().records[configId];
        if (!record.exists) revert HTPErrors.ConfigNotFound(configId);
    }

    function _requireServiceableStatus(bytes32 configId) private view returns (MarketRuleRecord storage record) {
        record = _requireRecord(configId);
        if (record.status != MarketRuleStatus.ACTIVE && record.status != MarketRuleStatus.LEGACY_SERVING) {
            revert HTPErrors.MarketRuleNotServiceable(configId, record.status);
        }
    }

    function _getMarketRuleRegistryStorage() private pure returns (MarketRuleRegistryStorage storage $) {
        assembly {
            $.slot := MARKET_RULE_REGISTRY_STORAGE_LOCATION
        }
    }
}
