// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {ISettlementTokenRegistry} from "../interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {Roles} from "../libraries/Roles.sol";
import {TokenMetadataValidation} from "../libraries/TokenMetadataValidation.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterRecord,
    AdapterStatus,
    HTPTypes,
    PermitCapability,
    ReasonCode,
    SettlementTokenConfig,
    SettlementTokenRecord,
    SettlementTokenStatus,
    TokenStandard,
    TransferLeg
} from "../types/HTPTypes.sol";
import {LinearConfigMetadata, LinearConfigRegistryBase, LinearConfigTransition} from "./LinearConfigRegistryBase.sol";

contract SettlementTokenRegistry is LinearConfigRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.SettlementTokenRegistry
    struct SettlementTokenRegistryStorage {
        IAdapterRegistry adapterRegistry;
        mapping(bytes32 configId => SettlementTokenConfig config) configs;
        mapping(bytes32 configId => bool implementationChangedPause) implementationChangedPauses;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.SettlementTokenRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SETTLEMENT_TOKEN_REGISTRY_STORAGE_LOCATION =
        0xaec168487638ceefac70663f44a41a76c887a35cdd0b990075d67f46370d8900;

    /// @notice Initializes roles and binds the adapter registry dependency.
    function initialize(
        address defaultAdmin,
        address governance,
        address upgrader,
        address pauser,
        address configurer,
        address adapterRegistry_
    ) external initializer {
        if (adapterRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(adapterRegistry_);
        }
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
        _getSettlementTokenRegistryStorage().adapterRegistry = IAdapterRegistry(adapterRegistry_);
    }

    /// @notice Registers settlement token metadata and linear config revision.
    function registerSettlementToken(SettlementTokenConfig calldata config) external onlyRole(Roles.CONFIGURER_ROLE) {
        _validateConfigIdentity(config);
        if (_linearConfigMetadata(config.configId).exists) {
            revert HTPErrors.ConfigAlreadyExists(config.configId);
        }
        TokenMetadataValidation.requireTokenDeployment(
            config.settlementToken,
            config.tokenDeploymentKind,
            config.tokenCodeHash,
            config.implementation,
            config.implementationCodeHash
        );
        TokenMetadataValidation.requireSettlementTokenDecimals(config.settlementToken, config.settlementTokenDecimals);
        if (config.permitCapability == PermitCapability.NONE) {
            revert HTPErrors.InvalidPermitCapability(config.permitCapability);
        }
        _validateAdapterReference(config, false);

        _getSettlementTokenRegistryStorage().configs[config.configId] = config;
        _registerLinearConfig(
            config.configId,
            _tokenSubject(config.settlementToken),
            config.revision,
            config.replacesConfigId,
            config.configHash
        );
        _emitSettlementTokenRegistered(config);
    }

    /// @notice Activates a registered settlement token config as current for the token.
    function activateSettlementToken(bytes32 configId, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        SettlementTokenRecord memory record = _settlementTokenRecord(configId);
        _requireSettlementTokenExists(configId, record);
        _validateToken(record.config);
        _validateAdapterReference(record.config, true);
        LinearConfigTransition memory transition = _activateLinearConfig(configId, expectedConfigHash);
        emit ISettlementTokenRegistry.SettlementTokenStatusChanged(
            block.chainid,
            configId,
            SettlementTokenStatus(transition.oldStatus),
            SettlementTokenStatus(transition.newStatus),
            ReasonCode.NONE,
            bytes32(0),
            _msgSender()
        );
        emit ISettlementTokenRegistry.CurrentSettlementTokenChanged(
            block.chainid, record.config.settlementToken, transition.oldCurrent, transition.newCurrent, _msgSender()
        );
    }

    /// @notice Pauses a settlement token config; tracks implementation-changed pauses.
    function pauseSettlementToken(bytes32 configId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(configId);
        if (
            reason == ReasonCode.IMPLEMENTATION_CHANGED && metadata.exists
                && metadata.status == uint8(SettlementTokenStatus.PAUSED)
        ) {
            _requireReasonAndEvidence(reason, evidenceHash);
            _getSettlementTokenRegistryStorage().implementationChangedPauses[configId] = true;
            emit ISettlementTokenRegistry.SettlementTokenStatusChanged(
                block.chainid,
                configId,
                SettlementTokenStatus.PAUSED,
                SettlementTokenStatus.PAUSED,
                reason,
                evidenceHash,
                _msgSender()
            );
            return;
        }
        _changeStatus(configId, SettlementTokenStatus.PAUSED, reason, evidenceHash);
        if (reason == ReasonCode.IMPLEMENTATION_CHANGED) {
            _getSettlementTokenRegistryStorage().implementationChangedPauses[configId] = true;
        }
    }

    /// @notice Resumes unless blocked by an implementation-changed pause flag.
    function unpauseSettlementToken(
        bytes32 configId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external onlyRole(Roles.GOVERNANCE_ROLE) {
        if (_getSettlementTokenRegistryStorage().implementationChangedPauses[configId]) {
            revert HTPErrors.SettlementTokenImplementationChanged(configId);
        }
        SettlementTokenRecord memory record = _settlementTokenRecord(configId);
        _requireSettlementTokenExists(configId, record);
        _validateToken(record.config);
        _validateAdapterReference(record.config, true);
        LinearConfigTransition memory transition =
            _unpauseLinearConfig(configId, expectedConfigHash, reason, evidenceHash);
        emit ISettlementTokenRegistry.SettlementTokenStatusChanged(
            block.chainid,
            configId,
            SettlementTokenStatus(transition.oldStatus),
            SettlementTokenStatus(transition.newStatus),
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    /// @notice Deprecates a settlement token configuration.
    function deprecateSettlementToken(bytes32 configId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _changeStatus(configId, SettlementTokenStatus.DEPRECATED, reason, evidenceHash);
    }

    /// @notice Returns settlement token record for a config id.
    function getSettlementToken(bytes32 configId) external view returns (SettlementTokenRecord memory) {
        return _settlementTokenRecord(configId);
    }

    /// @notice Returns the current config for a settlement token address.
    function getCurrentSettlementToken(address token) external view returns (SettlementTokenRecord memory) {
        return _settlementTokenRecord(_currentLinearConfigId(_tokenSubject(token)));
    }

    /// @notice True when config is active, hash matches, and on-chain token metadata is valid.
    function isSettlementTokenConfigActive(bytes32 configId, bytes32 expectedConfigHash) external view returns (bool) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(configId);
        return metadata.exists && metadata.status == CONFIG_STATUS_ACTIVE && metadata.configHash == expectedConfigHash
            && _isTokenValid(_getSettlementTokenRegistryStorage().configs[configId]);
    }

    /// @notice True when config exists, hash matches, and token deployment metadata is valid.
    function isSettlementTokenConfigRegisterable(bytes32 configId, bytes32 expectedConfigHash)
        external
        view
        returns (bool)
    {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(configId);
        return metadata.exists && metadata.configHash == expectedConfigHash
            && _isTokenValid(_getSettlementTokenRegistryStorage().configs[configId]);
    }

    function _recomputeLinearConfigHash(bytes32 configId) internal view override returns (bytes32) {
        return HTPHashing.hashSettlementTokenConfig(_getSettlementTokenRegistryStorage().configs[configId]);
    }

    function _validateConfigIdentity(SettlementTokenConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }
        bytes32 recomputedId = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            config.schemaVersion,
            block.chainid,
            _tokenSubject(config.settlementToken),
            config.revision
        );
        if (config.configId != recomputedId) {
            revert HTPErrors.ConfigIdMismatch(config.configId, recomputedId);
        }
        bytes32 recomputedHash = HTPHashing.hashSettlementTokenConfig(config);
        if (config.configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedHash);
        }
    }

    function _validateToken(SettlementTokenConfig memory config) private view {
        TokenMetadataValidation.requireTokenDeployment(
            config.settlementToken,
            config.tokenDeploymentKind,
            config.tokenCodeHash,
            config.implementation,
            config.implementationCodeHash
        );
        TokenMetadataValidation.requireSettlementTokenDecimals(config.settlementToken, config.settlementTokenDecimals);
    }

    function _isTokenValid(SettlementTokenConfig storage config) private view returns (bool) {
        if (
            !TokenMetadataValidation.isSettlementTokenDecimalsSupported(config.settlementTokenDecimals)
                || !TokenMetadataValidation.deploymentBaselineMatches(
                    config.settlementToken,
                    config.tokenDeploymentKind,
                    config.tokenCodeHash,
                    config.implementation,
                    config.implementationCodeHash
                )
        ) {
            return false;
        }
        (bool validDecimals, uint256 actualDecimals) = TokenMetadataValidation.readDecimals(config.settlementToken);
        return validDecimals && actualDecimals == config.settlementTokenDecimals;
    }

    function _validateAdapterReference(SettlementTokenConfig memory config, bool requireActive) private view {
        AdapterRecord memory adapter =
            _getSettlementTokenRegistryStorage().adapterRegistry.getAdapter(config.adapterConfigId);
        if (
            !adapter.exists || adapter.config.configHash != config.adapterConfigHash
                || (requireActive && adapter.status != AdapterStatus.ACTIVE)
        ) {
            revert HTPErrors.ConfigReferenceMismatch(config.adapterConfigId, config.adapterConfigHash);
        }

        uint256 requiredMask = (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_SELLER))
            | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_COLLECTOR));
        if (
            adapter.config.capabilities.tokenStandard != TokenStandard.ERC20
                || adapter.config.capabilities.transferLegMask & requiredMask != requiredMask
        ) {
            revert HTPErrors.SettlementAdapterCapabilitiesInvalid(config.adapterConfigId);
        }
    }

    function _emitSettlementTokenRegistered(SettlementTokenConfig calldata config) private {
        emit ISettlementTokenRegistry.SettlementTokenRegistered(
            block.chainid,
            config.configId,
            config.settlementToken,
            config.adapterConfigId,
            config.schemaVersion,
            config.revision,
            config.tokenDeploymentKind,
            config.settlementTokenDecimals,
            config.tokenCodeHash,
            config.implementation,
            config.implementationCodeHash,
            config.adapterConfigHash,
            config.permitCapability,
            config.configHash,
            config.replacesConfigId
        );
    }

    function _changeStatus(bytes32 configId, SettlementTokenStatus newStatus, ReasonCode reason, bytes32 evidenceHash)
        private
    {
        uint8 oldStatus = _transitionLinearConfig(configId, uint8(newStatus), reason, evidenceHash).oldStatus;
        emit ISettlementTokenRegistry.SettlementTokenStatusChanged(
            block.chainid, configId, SettlementTokenStatus(oldStatus), newStatus, reason, evidenceHash, _msgSender()
        );
    }

    function _settlementTokenRecord(bytes32 configId) private view returns (SettlementTokenRecord memory record) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(configId);
        record.config = _getSettlementTokenRegistryStorage().configs[configId];
        record.status = SettlementTokenStatus(metadata.status);
        record.exists = metadata.exists;
    }

    function _tokenSubject(address token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function _requireSettlementTokenExists(bytes32 configId, SettlementTokenRecord memory record) private pure {
        if (!record.exists) revert HTPErrors.ConfigNotFound(configId);
    }

    function _getSettlementTokenRegistryStorage() private pure returns (SettlementTokenRegistryStorage storage $) {
        assembly {
            $.slot := SETTLEMENT_TOKEN_REGISTRY_STORAGE_LOCATION
        }
    }
}
