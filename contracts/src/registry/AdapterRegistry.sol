// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {RegistryImplementationValidation} from "../libraries/RegistryImplementationValidation.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AdapterRecord,
    AdapterStatus,
    HTPTypes,
    PrecheckMethod,
    ReasonCode,
    RestrictionMode,
    TokenStandard
} from "../types/HTPTypes.sol";
import {LinearConfigMetadata, LinearConfigRegistryBase, LinearConfigTransition} from "./LinearConfigRegistryBase.sol";

contract AdapterRegistry is LinearConfigRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.AdapterRegistry
    struct AdapterRegistryStorage {
        mapping(bytes32 adapterConfigId => AdapterConfig config) configs;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.AdapterRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ADAPTER_REGISTRY_STORAGE_LOCATION =
        0x5690ed5754e0f5716bc670645aa45ded6dcddb9460f99672476d24dab8a9b400;

    uint256 private constant VALID_TRANSFER_LEG_MASK = 14;

    /// @notice Initializes roles for this upgradeable registry.
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }

    /// @notice Registers a new adapter config revision after on-chain validation.
    function registerAdapter(AdapterConfig calldata config) external onlyRole(Roles.CONFIGURER_ROLE) {
        _validateConfigIdentity(config);
        if (_linearConfigMetadata(config.adapterConfigId).exists) {
            revert HTPErrors.ConfigAlreadyExists(config.adapterConfigId);
        }
        _validateAdapter(config);

        _getAdapterRegistryStorage().configs[config.adapterConfigId] = config;
        _registerLinearConfig(
            config.adapterConfigId, config.capabilityHash, config.revision, config.replacesId, config.configHash
        );
        _emitAdapterRegistered(config);
    }

    /// @notice Activates a registered adapter and sets it as current for its capability.
    function activateAdapter(bytes32 adapterConfigId, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        AdapterRecord memory beforeRecord = _adapterRecord(adapterConfigId);
        _requireAdapterExists(adapterConfigId, beforeRecord);
        _validateAdapter(beforeRecord.config);

        LinearConfigTransition memory transition = _activateLinearConfig(adapterConfigId, expectedConfigHash);

        emit IAdapterRegistry.AdapterStatusChanged(
            block.chainid,
            adapterConfigId,
            AdapterStatus(transition.oldStatus),
            AdapterStatus(transition.newStatus),
            ReasonCode.NONE,
            bytes32(0),
            _msgSender()
        );
        emit IAdapterRegistry.CurrentAdapterChanged(
            block.chainid,
            beforeRecord.config.capabilityHash,
            transition.oldCurrent,
            transition.newCurrent,
            _msgSender()
        );
    }

    /// @notice Pauses an active adapter configuration.
    function pauseAdapter(bytes32 adapterConfigId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        _changeStatus(adapterConfigId, AdapterStatus.PAUSED, reason, evidenceHash);
    }

    /// @notice Resumes a paused adapter after re-validation.
    function unpauseAdapter(
        bytes32 adapterConfigId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external onlyRole(Roles.GOVERNANCE_ROLE) {
        AdapterRecord memory record = _adapterRecord(adapterConfigId);
        _requireAdapterExists(adapterConfigId, record);
        _validateAdapter(record.config);
        LinearConfigTransition memory transition =
            _unpauseLinearConfig(adapterConfigId, expectedConfigHash, reason, evidenceHash);
        emit IAdapterRegistry.AdapterStatusChanged(
            block.chainid,
            adapterConfigId,
            AdapterStatus(transition.oldStatus),
            AdapterStatus(transition.newStatus),
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    /// @notice Deprecates an adapter configuration with audit trail.
    function deprecateAdapter(bytes32 adapterConfigId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _changeStatus(adapterConfigId, AdapterStatus.DEPRECATED, reason, evidenceHash);
    }

    /// @notice Returns adapter record for a config id.
    function getAdapter(bytes32 adapterConfigId) external view returns (AdapterRecord memory) {
        return _adapterRecord(adapterConfigId);
    }

    /// @notice Returns the current active adapter for a capability hash.
    function getCurrentAdapter(bytes32 capabilityHash) external view returns (AdapterRecord memory) {
        return _adapterRecord(_currentLinearConfigId(capabilityHash));
    }

    /// @notice True when the config exists and linear status is active.
    function isAdapterActive(bytes32 adapterConfigId) external view returns (bool) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(adapterConfigId);
        return metadata.exists && metadata.status == CONFIG_STATUS_ACTIVE;
    }

    function _recomputeLinearConfigHash(bytes32 adapterConfigId) internal view override returns (bytes32) {
        return HTPHashing.hashAdapterConfig(_getAdapterRegistryStorage().configs[adapterConfigId]);
    }

    function _validateConfigIdentity(AdapterConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }

        bytes32 recomputedCapabilityHash = HTPHashing.hashAdapterCapabilities(config.capabilities);
        if (config.capabilityHash != recomputedCapabilityHash) {
            revert HTPErrors.AdapterCapabilityHashMismatch(config.capabilityHash, recomputedCapabilityHash);
        }
        bytes32 recomputedId = ConfigId.derive(
            ConfigId.ADAPTER_NAMESPACE, config.schemaVersion, block.chainid, config.capabilityHash, config.revision
        );
        if (config.adapterConfigId != recomputedId) {
            revert HTPErrors.ConfigIdMismatch(config.adapterConfigId, recomputedId);
        }
        bytes32 recomputedHash = HTPHashing.hashAdapterConfig(config);
        if (config.configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedHash);
        }
    }

    function _validateAdapter(AdapterConfig memory config) private view {
        _validateCapabilities(config.capabilities);
        bytes32 actualCodeHash = RegistryImplementationValidation.requireDirectCode(config.adapter);
        if (config.codeHash != actualCodeHash) {
            revert HTPErrors.AdapterCodeHashMismatch(config.codeHash, actualCodeHash);
        }
        if (config.interfaceVersion != InterfaceVersions.ASSET_ADAPTER_V1) {
            revert HTPErrors.AdapterInterfaceMismatch(InterfaceVersions.ASSET_ADAPTER_V1, config.interfaceVersion);
        }
        _validateAdapterVersion(config);
        _validateAdapterCapabilities(config);
        _validateAdapterCapabilityHash(config);
        _validateAdapterProviderHash(config);
    }

    function _validateAdapterVersion(AdapterConfig memory config) private view {
        (bool callSucceeded, bool returnWellFormed, bytes32 actualVersion) = BoundedStaticCall.staticCallWordStatus(
            config.adapter,
            abi.encodeCall(IAssetAdapter.interfaceVersion, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        _requireAdapterCallResult(config.adapterConfigId, callSucceeded, returnWellFormed);
        if (actualVersion != config.interfaceVersion) {
            revert HTPErrors.AdapterInterfaceMismatch(config.interfaceVersion, actualVersion);
        }
    }

    function _validateAdapterCapabilities(AdapterConfig memory config) private view {
        (
            bool callSucceeded,
            bool returnWellFormed,
            bytes32 tokenStandard,
            bytes32 restrictionMode,
            bytes32 precheckMethod,
            bytes32 mask
        ) = BoundedStaticCall.staticCallFourWordsStatus(
            config.adapter,
            abi.encodeCall(IAssetAdapter.capabilities, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        if (
            !callSucceeded || !returnWellFormed || uint256(tokenStandard) > uint8(TokenStandard.ERC1404)
                || uint256(restrictionMode) > uint8(RestrictionMode.TOKEN_ENFORCED)
                || uint256(precheckMethod) > uint8(PrecheckMethod.TOKEN_SPECIFIC_CHECK)
        ) {
            revert HTPErrors.AdapterReturnMalformed(config.adapterConfigId);
        }
        if (
            uint256(tokenStandard) != uint8(config.capabilities.tokenStandard)
                || uint256(restrictionMode) != uint8(config.capabilities.restrictionMode)
                || uint256(precheckMethod) != uint8(config.capabilities.precheckMethod)
                || uint256(mask) != config.capabilities.transferLegMask
        ) {
            revert HTPErrors.AdapterCapabilitiesMismatch();
        }
    }

    function _validateAdapterCapabilityHash(AdapterConfig memory config) private view {
        (bool callSucceeded, bool returnWellFormed, bytes32 actualCapabilityHash) = BoundedStaticCall.staticCallWordStatus(
            config.adapter,
            abi.encodeCall(IAssetAdapter.capabilityHash, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        _requireAdapterCallResult(config.adapterConfigId, callSucceeded, returnWellFormed);
        if (actualCapabilityHash != config.capabilityHash) {
            revert HTPErrors.AdapterCapabilityHashMismatch(config.capabilityHash, actualCapabilityHash);
        }
    }

    function _validateAdapterProviderHash(AdapterConfig memory config) private view {
        (bool callSucceeded, bool returnWellFormed, bytes32 actualProviderHash) = BoundedStaticCall.staticCallWordStatus(
            config.adapter,
            abi.encodeCall(IAssetAdapter.providerHash, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        _requireAdapterCallResult(config.adapterConfigId, callSucceeded, returnWellFormed);
        if (actualProviderHash != config.providerHash) {
            revert HTPErrors.AdapterProviderHashMismatch(config.providerHash, actualProviderHash);
        }
    }

    function _requireAdapterCallResult(bytes32 adapterConfigId, bool callSucceeded, bool returnWellFormed)
        private
        pure
    {
        if (!callSucceeded || !returnWellFormed) revert HTPErrors.AdapterReturnMalformed(adapterConfigId);
    }

    function _validateCapabilities(AdapterCapabilities memory capabilities) private pure {
        if (
            capabilities.tokenStandard == TokenStandard.NONE || capabilities.restrictionMode == RestrictionMode.NONE
                || capabilities.precheckMethod == PrecheckMethod.NONE || capabilities.transferLegMask == 0
                || capabilities.transferLegMask & ~VALID_TRANSFER_LEG_MASK != 0
        ) {
            revert HTPErrors.AdapterCapabilitiesInvalid();
        }
    }

    function _emitAdapterRegistered(AdapterConfig calldata config) private {
        emit IAdapterRegistry.AdapterRegistered(
            block.chainid,
            config.adapterConfigId,
            config.capabilityHash,
            config.adapter,
            config.schemaVersion,
            config.revision,
            config.interfaceVersion,
            config.codeHash,
            config.capabilities.tokenStandard,
            config.capabilities.restrictionMode,
            config.capabilities.precheckMethod,
            config.capabilities.transferLegMask,
            config.providerHash,
            config.configHash,
            config.replacesId
        );
    }

    function _changeStatus(bytes32 adapterConfigId, AdapterStatus newStatus, ReasonCode reason, bytes32 evidenceHash)
        private
    {
        uint8 oldStatus = _transitionLinearConfig(adapterConfigId, uint8(newStatus), reason, evidenceHash).oldStatus;
        emit IAdapterRegistry.AdapterStatusChanged(
            block.chainid, adapterConfigId, AdapterStatus(oldStatus), newStatus, reason, evidenceHash, _msgSender()
        );
    }

    function _adapterRecord(bytes32 adapterConfigId) private view returns (AdapterRecord memory record) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(adapterConfigId);
        record.config = _getAdapterRegistryStorage().configs[adapterConfigId];
        record.status = AdapterStatus(metadata.status);
        record.exists = metadata.exists;
    }

    function _requireAdapterExists(bytes32 adapterConfigId, AdapterRecord memory record) private pure {
        if (!record.exists) revert HTPErrors.ConfigNotFound(adapterConfigId);
    }

    function _getAdapterRegistryStorage() private pure returns (AdapterRegistryStorage storage $) {
        assembly {
            $.slot := ADAPTER_REGISTRY_STORAGE_LOCATION
        }
    }
}
