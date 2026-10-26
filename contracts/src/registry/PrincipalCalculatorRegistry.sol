// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IPrincipalCalculator} from "../interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {IPrincipalCalculatorRegistry} from "../interfaces/IPrincipalCalculatorRegistry.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {ConfigId} from "../libraries/ConfigId.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {ProtocolSecurityLimits} from "../libraries/ProtocolSecurityLimits.sol";
import {RegistryImplementationValidation} from "../libraries/RegistryImplementationValidation.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AssetClass,
    BondPriceTerms,
    CalculatorStatus,
    FundPriceTerms,
    HTPTypes,
    PrincipalCalculatorConfig,
    PrincipalCalculatorRecord,
    ReasonCode,
    StockPriceTerms
} from "../types/HTPTypes.sol";
import {LinearConfigMetadata, LinearConfigRegistryBase, LinearConfigTransition} from "./LinearConfigRegistryBase.sol";

contract PrincipalCalculatorRegistry is LinearConfigRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.PrincipalCalculatorRegistry
    struct PrincipalCalculatorRegistryStorage {
        mapping(bytes32 calculatorConfigId => PrincipalCalculatorConfig config) configs;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.PrincipalCalculatorRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRINCIPAL_CALCULATOR_REGISTRY_STORAGE_LOCATION =
        0x20464761bfb922242712a952d932f3bfd3a65e14b981242aad7e96247b149b00;

    bytes32 private constant PROBE_SOURCE_HASH = 0x0eebab6126c6f50b833b7104b7ccd1a91b3ed8681d07db05dad5417c42398f59;

    /// @notice Initializes roles for this upgradeable registry.
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }

    /// @notice Registers a principal calculator config after static validation.
    function registerPrincipalCalculator(PrincipalCalculatorConfig calldata config)
        external
        onlyRole(Roles.CONFIGURER_ROLE)
    {
        _validateConfigIdentity(config);
        if (_linearConfigMetadata(config.calculatorConfigId).exists) {
            revert HTPErrors.ConfigAlreadyExists(config.calculatorConfigId);
        }
        _validateCalculator(config);

        _getPrincipalCalculatorRegistryStorage().configs[config.calculatorConfigId] = config;
        _registerLinearConfig(
            config.calculatorConfigId,
            _assetClassSubject(config.assetClass),
            config.revision,
            config.replacesId,
            config.configHash
        );
        emit IPrincipalCalculatorRegistry.PrincipalCalculatorRegistered(
            block.chainid,
            config.calculatorConfigId,
            config.assetClass,
            config.calculator,
            config.schemaVersion,
            config.revision,
            config.interfaceVersion,
            config.codeHash,
            config.configHash,
            config.replacesId
        );
    }

    /// @notice Activates a calculator config and sets it current for the asset class.
    function activatePrincipalCalculator(bytes32 calculatorConfigId, bytes32 expectedConfigHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        PrincipalCalculatorRecord memory beforeRecord = _calculatorRecord(calculatorConfigId);
        _requireCalculatorExists(calculatorConfigId, beforeRecord);
        _validateCalculator(beforeRecord.config);

        LinearConfigTransition memory transition = _activateLinearConfig(calculatorConfigId, expectedConfigHash);

        emit IPrincipalCalculatorRegistry.PrincipalCalculatorStatusChanged(
            block.chainid,
            calculatorConfigId,
            CalculatorStatus(transition.oldStatus),
            CalculatorStatus(transition.newStatus),
            ReasonCode.NONE,
            bytes32(0),
            _msgSender()
        );
        emit IPrincipalCalculatorRegistry.CurrentPrincipalCalculatorChanged(
            block.chainid, beforeRecord.config.assetClass, transition.oldCurrent, transition.newCurrent, _msgSender()
        );
    }

    /// @notice Pauses an active principal calculator configuration.
    function pausePrincipalCalculator(bytes32 calculatorConfigId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        _changeStatus(calculatorConfigId, CalculatorStatus.PAUSED, reason, evidenceHash);
    }

    /// @notice Resumes a paused calculator after re-validation.
    function unpausePrincipalCalculator(
        bytes32 calculatorConfigId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external onlyRole(Roles.GOVERNANCE_ROLE) {
        PrincipalCalculatorRecord memory record = _calculatorRecord(calculatorConfigId);
        _requireCalculatorExists(calculatorConfigId, record);
        _validateCalculator(record.config);
        LinearConfigTransition memory transition =
            _unpauseLinearConfig(calculatorConfigId, expectedConfigHash, reason, evidenceHash);
        emit IPrincipalCalculatorRegistry.PrincipalCalculatorStatusChanged(
            block.chainid,
            calculatorConfigId,
            CalculatorStatus(transition.oldStatus),
            CalculatorStatus(transition.newStatus),
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    /// @notice Deprecates a principal calculator configuration.
    function deprecatePrincipalCalculator(bytes32 calculatorConfigId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _changeStatus(calculatorConfigId, CalculatorStatus.DEPRECATED, reason, evidenceHash);
    }

    /// @notice Returns calculator record for a config id.
    function getPrincipalCalculator(bytes32 calculatorConfigId)
        external
        view
        returns (PrincipalCalculatorRecord memory)
    {
        return _calculatorRecord(calculatorConfigId);
    }

    /// @notice Returns the current calculator for an asset class.
    function getCurrentPrincipalCalculator(AssetClass assetClass)
        external
        view
        returns (PrincipalCalculatorRecord memory)
    {
        if (!_isValidAssetClass(assetClass)) revert HTPErrors.InvalidAssetClass(uint8(assetClass));
        return _calculatorRecord(_currentLinearConfigId(_assetClassSubject(assetClass)));
    }

    /// @notice True when config is active and matches expected hash and asset class.
    function isPrincipalCalculatorConfigActive(
        bytes32 calculatorConfigId,
        bytes32 expectedConfigHash,
        AssetClass expectedAssetClass
    ) external view returns (bool) {
        PrincipalCalculatorRecord memory record = _calculatorRecord(calculatorConfigId);
        return record.exists && record.status == CalculatorStatus.ACTIVE
            && record.config.configHash == expectedConfigHash && record.config.assetClass == expectedAssetClass;
    }

    function _recomputeLinearConfigHash(bytes32 calculatorConfigId) internal view override returns (bytes32) {
        return
            HTPHashing.hashPrincipalCalculatorConfig(
                _getPrincipalCalculatorRegistryStorage().configs[calculatorConfigId]
            );
    }

    function _validateConfigIdentity(PrincipalCalculatorConfig calldata config) private view {
        if (config.schemaVersion != HTPTypes.SCHEMA_VERSION) {
            revert HTPErrors.InvalidSchemaVersion(config.schemaVersion);
        }
        if (config.chainId != block.chainid) {
            revert HTPErrors.ConfigChainMismatch(block.chainid, config.chainId);
        }
        if (!_isValidAssetClass(config.assetClass)) {
            revert HTPErrors.InvalidAssetClass(uint8(config.assetClass));
        }

        bytes32 recomputedId = ConfigId.derive(
            ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE,
            config.schemaVersion,
            block.chainid,
            _assetClassSubject(config.assetClass),
            config.revision
        );
        if (config.calculatorConfigId != recomputedId) {
            revert HTPErrors.ConfigIdMismatch(config.calculatorConfigId, recomputedId);
        }
        bytes32 recomputedHash = HTPHashing.hashPrincipalCalculatorConfig(config);
        if (config.configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(config.configHash, recomputedHash);
        }
    }

    function _validateCalculator(PrincipalCalculatorConfig memory config) private view {
        bytes32 actualCodeHash = RegistryImplementationValidation.requireDirectCode(config.calculator);
        if (config.codeHash != actualCodeHash) {
            revert HTPErrors.CalculatorCodeHashMismatch(config.codeHash, actualCodeHash);
        }
        if (config.interfaceVersion != InterfaceVersions.PRINCIPAL_CALCULATOR_V1) {
            revert HTPErrors.CalculatorInterfaceMismatch(
                InterfaceVersions.PRINCIPAL_CALCULATOR_V1, config.interfaceVersion
            );
        }

        (bool versionCallSucceeded, bool versionReturnWellFormed, bytes32 actualVersion) = BoundedStaticCall.staticCallWordStatus(
            config.calculator,
            abi.encodeCall(IPrincipalCalculator.interfaceVersion, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        _requireCalculatorCallResult(config.calculatorConfigId, versionCallSucceeded, versionReturnWellFormed);
        if (actualVersion != config.interfaceVersion) {
            revert HTPErrors.CalculatorInterfaceMismatch(config.interfaceVersion, actualVersion);
        }

        (bool assetClassCallSucceeded, bool assetClassReturnWellFormed, bytes32 actualAssetClassWord) = BoundedStaticCall.staticCallWordStatus(
            config.calculator,
            abi.encodeCall(IPrincipalCalculator.assetClass, ()),
            RegistryImplementationValidation.VALIDATION_GAS_LIMIT
        );
        _requireCalculatorCallResult(config.calculatorConfigId, assetClassCallSucceeded, assetClassReturnWellFormed);
        if (uint256(actualAssetClassWord) > uint8(AssetClass.BOND)) {
            revert HTPErrors.CalculatorReturnMalformed(config.calculatorConfigId);
        }
        AssetClass actualAssetClass = AssetClass(uint8(uint256(actualAssetClassWord)));
        if (actualAssetClass != config.assetClass) {
            revert HTPErrors.CalculatorAssetClassMismatch(config.assetClass, actualAssetClass);
        }

        (bool calculateCallSucceeded, bool calculateReturnWellFormed,,,,) = BoundedStaticCall.staticCallFourWordsStatus(
            config.calculator,
            abi.encodeCall(IPrincipalCalculator.calculate, (_probePriceData(config.assetClass), uint256(1), uint8(0))),
            ProtocolSecurityLimits.PRINCIPAL_CALCULATOR_CALL_GAS
        );
        _requireCalculatorCallResult(config.calculatorConfigId, calculateCallSucceeded, calculateReturnWellFormed);
    }

    function _requireCalculatorCallResult(bytes32 calculatorConfigId, bool callSucceeded, bool returnWellFormed)
        private
        pure
    {
        if (!callSucceeded) revert HTPErrors.CalculatorStaticCallFailed(calculatorConfigId);
        if (!returnWellFormed) revert HTPErrors.CalculatorReturnMalformed(calculatorConfigId);
    }

    function _probePriceData(AssetClass assetClass) private pure returns (bytes memory) {
        if (assetClass == AssetClass.STOCK) {
            return abi.encode(
                StockPriceTerms({
                    unitPrice: 1,
                    priceAsOf: 1,
                    referenceMarketHash: PROBE_SOURCE_HASH,
                    priceSourceHash: PROBE_SOURCE_HASH
                })
            );
        }
        if (assetClass == AssetClass.FUND) {
            return abi.encode(FundPriceTerms({navPerUnit: 1, navDate: 20_000_101, navSourceHash: PROBE_SOURCE_HASH}));
        }
        return abi.encode(
            BondPriceTerms({
                cleanPricePerUnit: 1,
                accruedInterestPerUnit: 1,
                settlementDate: 20_000_101,
                sourceHash: PROBE_SOURCE_HASH
            })
        );
    }

    function _changeStatus(
        bytes32 calculatorConfigId,
        CalculatorStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash
    ) private {
        uint8 oldStatus = _transitionLinearConfig(calculatorConfigId, uint8(newStatus), reason, evidenceHash).oldStatus;
        emit IPrincipalCalculatorRegistry.PrincipalCalculatorStatusChanged(
            block.chainid,
            calculatorConfigId,
            CalculatorStatus(oldStatus),
            newStatus,
            reason,
            evidenceHash,
            _msgSender()
        );
    }

    function _calculatorRecord(bytes32 calculatorConfigId)
        private
        view
        returns (PrincipalCalculatorRecord memory record)
    {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(calculatorConfigId);
        record.config = _getPrincipalCalculatorRegistryStorage().configs[calculatorConfigId];
        record.status = CalculatorStatus(metadata.status);
        record.exists = metadata.exists;
    }

    function _assetClassSubject(AssetClass assetClass) private pure returns (bytes32) {
        return bytes32(uint256(assetClass));
    }

    function _isValidAssetClass(AssetClass assetClass) private pure returns (bool) {
        return assetClass != AssetClass.NONE && uint8(assetClass) <= uint8(AssetClass.BOND);
    }

    function _requireCalculatorExists(bytes32 calculatorConfigId, PrincipalCalculatorRecord memory record)
        private
        pure
    {
        if (!record.exists) revert HTPErrors.ConfigNotFound(calculatorConfigId);
    }

    function _getPrincipalCalculatorRegistryStorage()
        private
        pure
        returns (PrincipalCalculatorRegistryStorage storage $)
    {
        assembly {
            $.slot := PRINCIPAL_CALCULATOR_REGISTRY_STORAGE_LOCATION
        }
    }
}
