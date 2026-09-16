// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "../interfaces/IAssetVersionRegistry.sol";
import {IDvPGovernanceView} from "../interfaces/IDvPGovernanceView.sol";
import {IPrincipalCalculatorRegistry} from "../interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "../interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {Roles} from "../libraries/Roles.sol";
import {TokenMetadataValidation} from "../libraries/TokenMetadataValidation.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterRecord,
    AdapterStatus,
    AssetClass,
    AssetVersionConfig,
    AssetVersionRecord,
    AssetVersionStatus,
    CalculatorStatus,
    HTPTypes,
    PermitCapability,
    PrincipalCalculatorRecord,
    ReasonCode,
    RestrictionMode,
    SettlementTokenRecord,
    TokenDeploymentKind,
    TokenStandard,
    TransferLeg
} from "../types/HTPTypes.sol";
import {LinearConfigMetadata, LinearConfigRegistryBase, LinearConfigTransition} from "./LinearConfigRegistryBase.sol";

/// @notice Versioned asset token configs linked to calculators, adapters, and DvP.
contract AssetVersionRegistry is LinearConfigRegistryBase {
    event AssetVersionRegistered(
        uint256 chainId,
        bytes32 indexed assetVersionId,
        bytes32 indexed economicAssetIdHash,
        address indexed assetToken,
        uint32 schemaVersion,
        uint32 versionNo,
        TokenStandard tokenStandard,
        TokenDeploymentKind tokenDeploymentKind,
        uint8 assetDecimals,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash,
        PermitCapability assetPermitCapability,
        AssetClass assetClass,
        bytes32 principalCalculatorConfigId,
        bytes32 principalCalculatorConfigHash,
        bytes32 adapterConfigId,
        bytes32 adapterConfigHash,
        RestrictionMode restrictionMode,
        address settlementToken,
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        address dvpContract,
        bytes32 deploymentVersionHash,
        bytes32 replacesAssetVersionId,
        bytes32 configHash
    );

    /// @custom:storage-location erc7201:htp.storage.AssetVersionRegistry
    struct AssetVersionRegistryStorage {
        ISettlementTokenRegistry settlementTokenRegistry;
        IAdapterRegistry adapterRegistry;
        IPrincipalCalculatorRegistry principalCalculatorRegistry;
        mapping(bytes32 assetVersionId => AssetVersionConfig config) configs;
        mapping(address assetToken => bytes32 economicAssetIdHash) economicAssetIds;
        mapping(bytes32 assetVersionId => bool implementationChangedPause) implementationChangedPauses;
    }

    // ERC-7201: htp.storage.AssetVersionRegistry
    bytes32 private constant ASSET_VERSION_REGISTRY_STORAGE_LOCATION =
        0xfdb037db09caf56f4088d97b678789f28e0851d4dc6c2b67c09fd14bb56c3100;

    bytes32 private constant ASSET_VERSION_REGISTERED_TOPIC =
        0x100773d51fab64b1962f8e4e5966207b6779560f02b61810ce0f40a1fc2f3fc4;

    function initialize(
        address defaultAdmin,
        address governance,
        address upgrader,
        address pauser,
        address configurer,
        address settlementTokenRegistry_,
        address adapterRegistry_,
        address principalCalculatorRegistry_
    ) external initializer {
        if (settlementTokenRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(settlementTokenRegistry_);
        }
        if (adapterRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(adapterRegistry_);
        }
        if (principalCalculatorRegistry_.code.length == 0) {
            revert HTPErrors.InvalidRegistryDependency(principalCalculatorRegistry_);
        }
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);

        AssetVersionRegistryStorage storage $ = _getAssetVersionRegistryStorage();
        $.settlementTokenRegistry = ISettlementTokenRegistry(settlementTokenRegistry_);
        $.adapterRegistry = IAdapterRegistry(adapterRegistry_);
        $.principalCalculatorRegistry = IPrincipalCalculatorRegistry(principalCalculatorRegistry_);
    }

    /// @notice Registers a new asset version config (registered status).
    function registerAssetVersion(AssetVersionConfig calldata config) external onlyRole(Roles.CONFIGURER_ROLE) {
        _validateConfigIdentity(config);
        if (_linearConfigMetadata(config.assetVersionId).exists) {
            revert HTPErrors.ConfigAlreadyExists(config.assetVersionId);
        }
        TokenMetadataValidation.requireTokenDeployment(
            config.assetToken,
            config.tokenDeploymentKind,
            config.tokenCodeHash,
            config.implementation,
            config.implementationCodeHash
        );
        TokenMetadataValidation.requireAssetDecimals(config.assetToken, config.assetDecimals);
        _validateReferences(config, false);
        _validateDvp(config);

        AssetVersionRegistryStorage storage $ = _getAssetVersionRegistryStorage();
        bytes32 existingOwner = $.economicAssetIds[config.assetToken];
        if (existingOwner != bytes32(0) && existingOwner != config.economicAssetIdHash) {
            revert HTPErrors.AssetTokenAlreadyRegistered(config.assetToken);
        }
        $.configs[config.assetVersionId] = config;
        if (existingOwner == bytes32(0)) {
            $.economicAssetIds[config.assetToken] = config.economicAssetIdHash;
        }
        _registerLinearConfig(
            config.assetVersionId,
            _tokenSubject(config.assetToken),
            config.versionNo,
            config.replacesAssetVersionId,
            config.configHash
        );
        _emitAssetVersionRegistered(config);
    }

    /// @notice Activates a registered asset version after hash confirmation.
    function activateAssetVersion(bytes32 assetVersionId, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        AssetVersionRecord memory record = _assetVersionRecord(assetVersionId);
        _requireAssetVersionExists(assetVersionId, record);
        _validateToken(record.config);
        _validateReferences(record.config, true);
        _validateDvp(record.config);
        LinearConfigTransition memory transition = _activateLinearConfig(assetVersionId, expectedConfigHash);
        emit IAssetVersionRegistry.AssetVersionStatusChanged(
            block.chainid,
            assetVersionId,
            AssetVersionStatus(transition.oldStatus),
            AssetVersionStatus(transition.newStatus),
            ReasonCode.NONE,
            bytes32(0),
            _msgSender()
        );
        emit IAssetVersionRegistry.CurrentAssetVersionChanged(
            block.chainid, record.config.assetToken, transition.oldCurrent, transition.newCurrent, _msgSender()
        );
    }

    function pauseAssetVersion(bytes32 assetVersionId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        if (reason == ReasonCode.IMPLEMENTATION_CHANGED) {
            LinearConfigMetadata memory metadata = _linearConfigMetadata(assetVersionId);
            if (metadata.exists && metadata.status == uint8(AssetVersionStatus.PAUSED)) {
                _requireReasonAndEvidence(reason, evidenceHash);
                _getAssetVersionRegistryStorage().implementationChangedPauses[assetVersionId] = true;
                emit IAssetVersionRegistry.AssetVersionStatusChanged(
                    block.chainid,
                    assetVersionId,
                    AssetVersionStatus.PAUSED,
                    AssetVersionStatus.PAUSED,
                    reason,
                    evidenceHash,
                    _msgSender()
                );
                return;
            }
        }
        uint8 oldStatus =
            _transitionLinearConfig(assetVersionId, uint8(AssetVersionStatus.PAUSED), reason, evidenceHash).oldStatus;
        if (reason == ReasonCode.IMPLEMENTATION_CHANGED) {
            _getAssetVersionRegistryStorage().implementationChangedPauses[assetVersionId] = true;
        }
        emit IAssetVersionRegistry.AssetVersionStatusChanged(
            block.chainid,
            assetVersionId,
            AssetVersionStatus(oldStatus),
            AssetVersionStatus.PAUSED,
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    function unpauseAssetVersion(
        bytes32 assetVersionId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external onlyRole(Roles.GOVERNANCE_ROLE) {
        AssetVersionRegistryStorage storage $ = _getAssetVersionRegistryStorage();
        if ($.implementationChangedPauses[assetVersionId]) {
            revert HTPErrors.AssetVersionImplementationChanged(assetVersionId);
        }
        AssetVersionRecord memory record = _assetVersionRecord(assetVersionId);
        _requireAssetVersionExists(assetVersionId, record);
        _validateToken(record.config);
        _validateReferences(record.config, true);
        _validateDvp(record.config);
        LinearConfigTransition memory transition =
            _unpauseLinearConfig(assetVersionId, expectedConfigHash, reason, evidenceHash);
        emit IAssetVersionRegistry.AssetVersionStatusChanged(
            block.chainid,
            assetVersionId,
            AssetVersionStatus(transition.oldStatus),
            AssetVersionStatus(transition.newStatus),
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    function deprecateAssetVersion(bytes32 assetVersionId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        LinearConfigTransition memory transition =
            _transitionLinearConfig(assetVersionId, uint8(AssetVersionStatus.DEPRECATED), reason, evidenceHash);
        emit IAssetVersionRegistry.AssetVersionStatusChanged(
            block.chainid,
            assetVersionId,
            AssetVersionStatus(transition.oldStatus),
            AssetVersionStatus.DEPRECATED,
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    function getAssetVersion(bytes32 assetVersionId) external view returns (AssetVersionRecord memory) {
        return _assetVersionRecord(assetVersionId);
    }

    function getCurrentAssetVersion(address assetToken) external view returns (AssetVersionRecord memory) {
        return _assetVersionRecord(_currentLinearConfigId(_tokenSubject(assetToken)));
    }

    function getEconomicAssetIdHash(address assetToken) external view returns (bytes32) {
        return _getAssetVersionRegistryStorage().economicAssetIds[assetToken];
    }

    function _recomputeLinearConfigHash(bytes32 assetVersionId) internal view override returns (bytes32) {
        return HTPHashing.hashAssetVersionConfig(_getAssetVersionRegistryStorage().configs[assetVersionId]);
    }

    function _validateConfigIdentity(AssetVersionConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }
        if (config.economicAssetIdHash == bytes32(0)) {
            revert HTPErrors.InvalidConfigIdentity();
        }
        if (config.assetDecimals > 36) {
            revert HTPErrors.AssetDecimalsOutOfRange(config.assetDecimals);
        }
        bytes32 recomputedId = ConfigId.assetVersion(
            config.schemaVersion, config.economicAssetIdHash, block.chainid, config.assetToken, config.versionNo
        );
        if (config.assetVersionId != recomputedId) {
            revert HTPErrors.AssetVersionIdMismatch(config.assetVersionId, recomputedId);
        }
        bytes32 recomputedHash = HTPHashing.hashAssetVersionConfig(config);
        if (config.configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedHash);
        }
    }

    function _validateToken(AssetVersionConfig memory config) private view {
        TokenMetadataValidation.requireTokenDeployment(
            config.assetToken,
            config.tokenDeploymentKind,
            config.tokenCodeHash,
            config.implementation,
            config.implementationCodeHash
        );
        TokenMetadataValidation.requireAssetDecimals(config.assetToken, config.assetDecimals);
    }

    function _validateReferences(AssetVersionConfig memory config, bool requireActive) private view {
        if (config.assetPermitCapability == PermitCapability.NONE) {
            revert HTPErrors.InvalidPermitCapability(config.assetPermitCapability);
        }
        AssetVersionRegistryStorage storage $ = _getAssetVersionRegistryStorage();
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
        if (!settlementUsable || settlement.config.settlementToken != config.settlementToken) {
            revert HTPErrors.ConfigReferenceMismatch(config.settlementTokenConfigId, config.settlementTokenConfigHash);
        }

        AdapterRecord memory adapter = $.adapterRegistry.getAdapter(config.adapterConfigId);
        if (
            !adapter.exists || adapter.config.configHash != config.adapterConfigHash
                || (requireActive && adapter.status != AdapterStatus.ACTIVE)
        ) {
            revert HTPErrors.ConfigReferenceMismatch(config.adapterConfigId, config.adapterConfigHash);
        }
        uint256 assetLeg = uint256(1) << uint8(TransferLeg.ASSET);
        if (
            adapter.config.capabilities.tokenStandard != config.tokenStandard
                || adapter.config.capabilities.restrictionMode != config.restrictionMode
                || adapter.config.capabilities.transferLegMask & assetLeg == 0
        ) {
            revert HTPErrors.AssetAdapterCapabilitiesInvalid(config.adapterConfigId);
        }

        PrincipalCalculatorRecord memory calculator =
            $.principalCalculatorRegistry.getPrincipalCalculator(config.principalCalculatorConfigId);
        if (
            !calculator.exists || calculator.config.configHash != config.principalCalculatorConfigHash
                || calculator.config.assetClass != config.assetClass
                || (requireActive && calculator.status != CalculatorStatus.ACTIVE)
        ) {
            revert HTPErrors.ConfigReferenceMismatch(
                config.principalCalculatorConfigId, config.principalCalculatorConfigHash
            );
        }
    }

    function _validateDvp(AssetVersionConfig memory config) private view {
        if (config.dvpContract.code.length == 0) {
            revert HTPErrors.InvalidDependentDvp(config.dvpContract);
        }
        if (!_isDependentDvpRegistered(config.dvpContract)) {
            revert HTPErrors.DependentDvpNotRegistered(config.dvpContract);
        }
        (bool pausedValid,) = _readCanonicalBoolResult(config.dvpContract, IDvPGovernanceView.globalPaused.selector);
        (bool retiredValid, bool isRetired) =
            _readCanonicalBoolResult(config.dvpContract, IDvPGovernanceView.retired.selector);
        if (!pausedValid || !retiredValid) {
            revert HTPErrors.DvpInterfaceMismatch(config.dvpContract);
        }
        if (isRetired) revert HTPErrors.DvpRetired(config.dvpContract);
        (bool callSucceeded, bool returnWellFormed, bytes32 actualVersion) = BoundedStaticCall.staticCallWordStatus(
            config.dvpContract,
            abi.encodeCall(IDvPGovernanceView.deploymentVersionHash, ()),
            TokenMetadataValidation.VALIDATION_GAS_LIMIT
        );
        if (!callSucceeded || !returnWellFormed) {
            revert HTPErrors.DvpDeploymentVersionMalformed(config.dvpContract);
        }
        if (actualVersion != config.deploymentVersionHash) {
            revert HTPErrors.DvpDeploymentVersionMismatch(
                config.dvpContract, config.deploymentVersionHash, actualVersion
            );
        }
    }

    function _readCanonicalBoolResult(address target, bytes4 selector) private view returns (bool valid, bool value) {
        (bool callSucceeded, bool returnWellFormed, bytes32 result) = BoundedStaticCall.staticCallWordStatus(
            target, abi.encodeWithSelector(selector), TokenMetadataValidation.VALIDATION_GAS_LIMIT
        );
        uint256 word = uint256(result);
        valid = callSucceeded && returnWellFormed && word <= 1;
        value = word == 1;
    }

    function _emitAssetVersionRegistered(AssetVersionConfig calldata config) private {
        bytes32 tokenTopic = bytes32(uint256(uint160(config.assetToken)));
        bytes32 eventTopic = ASSET_VERSION_REGISTERED_TOPIC;
        bytes32 assetVersionId = config.assetVersionId;
        bytes32 economicAssetIdHash = config.economicAssetIdHash;
        assembly ("memory-safe") {
            let encodedData := mload(0x40)
            mstore(encodedData, chainid())
            calldatacopy(add(encodedData, 0x20), config, 0x20)
            calldatacopy(add(encodedData, 0x40), add(config, 0x80), 0x20)
            calldatacopy(add(encodedData, 0x60), add(config, 0xc0), 0x280)
            mstore(0x40, add(encodedData, 0x2e0))
            log4(encodedData, 0x2e0, eventTopic, assetVersionId, economicAssetIdHash, tokenTopic)
        }
    }

    function _assetVersionRecord(bytes32 assetVersionId) private view returns (AssetVersionRecord memory record) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(assetVersionId);
        record.config = _getAssetVersionRegistryStorage().configs[assetVersionId];
        record.status = AssetVersionStatus(metadata.status);
        record.exists = metadata.exists;
    }

    function _tokenSubject(address token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function _requireAssetVersionExists(bytes32 assetVersionId, AssetVersionRecord memory record) private pure {
        if (!record.exists) revert HTPErrors.ConfigNotFound(assetVersionId);
    }

    function _getAssetVersionRegistryStorage() private pure returns (AssetVersionRegistryStorage storage $) {
        assembly {
            $.slot := ASSET_VERSION_REGISTRY_STORAGE_LOCATION
        }
    }
}
