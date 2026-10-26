// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPSettlement} from "../interfaces/IDvPSettlement.sol";
import {IFeeRegistry} from "../interfaces/IFeeRegistry.sol";
import {IMarketRuleRegistry} from "../interfaces/IMarketRuleRegistry.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterRecord,
    AdapterStatus,
    AssetClass,
    AssetVersionRecord,
    AssetVersionStatus,
    CalculatorStatus,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    MarketRuleRecord,
    PrincipalCalculatorRecord,
    RoundingMode,
    SettlementTokenRecord,
    SettlementTokenStatus
} from "../types/HTPTypes.sol";

struct AssetReference {
    bytes32 assetVersionId;
    address assetToken;
    uint8 assetDecimals;
    AssetClass assetClass;
    bytes32 principalCalculatorConfigId;
    bytes32 principalCalculatorConfigHash;
    bytes32 adapterConfigId;
    bytes32 adapterConfigHash;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    bytes32 deploymentVersionHash;
}

struct SettlementTokenReference {
    bytes32 configId;
    bytes32 configHash;
    address token;
    uint8 decimals;
}

struct AdapterReferences {
    bytes32 assetConfigId;
    bytes32 assetConfigHash;
    bytes32 settlementConfigId;
    bytes32 settlementConfigHash;
}

struct CalculatorReference {
    bytes32 configId;
    bytes32 configHash;
    AssetClass assetClass;
}

struct FeeReferences {
    uint64 policyEpoch;
    bytes32 versionId;
    bytes32 matchedScopeHash;
    bytes32 constraintHash;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    address collector;
    RoundingMode roundingMode;
    uint64 createdAt;
    uint64 tradeDeadline;
    uint64 quoteExpiresAt;
}

struct MarketRuleReferences {
    bytes32 configId;
    bytes32 configHash;
    bytes32 assetVersionId;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    uint64 createdAt;
    uint64 quoteExpiresAt;
    uint64 tradeDeadline;
}

struct MarketRuleQuantities {
    uint256 minimum;
    uint256 maximum;
    uint256 step;
    uint256 executed;
}

/// @notice Loads registry records and checks they match signed settlement references.
contract ConfigurationReferenceIntegrity {
    uint256 private constant REGISTRY_GAS_LIMIT = 300_000;

    /// @notice Loads asset version and tests snapshot field equality.
    function loadAssetVersion(address dvp, AssetReference calldata expected)
        external
        view
        returns (AssetVersionRecord memory record, bool matches)
    {
        record = IDvPSettlement(dvp).assetVersionRegistry().getAssetVersion{gas: REGISTRY_GAS_LIMIT}(
            expected.assetVersionId
        );
        matches = _assetVersionMatches(dvp, expected, record);
    }

    function loadSettlementToken(address dvp, SettlementTokenReference calldata expected)
        external
        view
        returns (SettlementTokenRecord memory record, bool matches)
    {
        record = IDvPSettlement(dvp).settlementTokenRegistry().getSettlementToken{gas: REGISTRY_GAS_LIMIT}(
            expected.configId
        );
        matches = record.exists && record.status == SettlementTokenStatus.ACTIVE
            && record.config.configId == expected.configId && record.config.configHash == expected.configHash
            && record.config.settlementToken == expected.token
            && record.config.settlementTokenDecimals == expected.decimals;
    }

    function loadAdapters(address dvp, AdapterReferences calldata expected)
        external
        view
        returns (
            AdapterRecord memory assetAdapter,
            AdapterRecord memory settlementAdapter,
            bool assetServiceable,
            bool settlementServiceable
        )
    {
        assetAdapter = IDvPSettlement(dvp).adapterRegistry().getAdapter{gas: REGISTRY_GAS_LIMIT}(expected.assetConfigId);
        settlementAdapter =
            IDvPSettlement(dvp).adapterRegistry().getAdapter{gas: REGISTRY_GAS_LIMIT}(expected.settlementConfigId);
        // N9: Preserve which adapter side failed so strict settlement reports its actual config ID.
        assetServiceable = _adapterActive(assetAdapter, expected.assetConfigId, expected.assetConfigHash);
        settlementServiceable =
            _adapterActive(settlementAdapter, expected.settlementConfigId, expected.settlementConfigHash);
    }

    function loadCalculator(address dvp, CalculatorReference calldata expected)
        external
        view
        returns (PrincipalCalculatorRecord memory record, bool serviceable)
    {
        record = IDvPSettlement(dvp).principalCalculatorRegistry().getPrincipalCalculator{gas: REGISTRY_GAS_LIMIT}(
            expected.configId
        );
        serviceable = record.exists && record.status == CalculatorStatus.ACTIVE
            && record.config.calculatorConfigId == expected.configId && record.config.configHash == expected.configHash
            && record.config.assetClass == expected.assetClass && record.config.calculator.code.length != 0
            && record.config.codeHash == record.config.calculator.codehash;
    }

    function loadFee(address dvp, bytes32 assetVersionId, FeeReferences calldata expected)
        external
        view
        returns (FeeVersionRecord memory fee, bytes4 failureReason)
    {
        IFeeRegistry registry = IDvPSettlement(dvp).feeRegistry();
        FeePolicyEpochRecord memory epoch = registry.getFeePolicyEpoch{gas: REGISTRY_GAS_LIMIT}(expected.policyEpoch);
        fee = registry.getFeeVersion{gas: REGISTRY_GAS_LIMIT}(expected.versionId);

        if (!_feeRecordsServiceable(expected, epoch, fee)) {
            return (fee, HTPErrors.FeeSnapshotMismatch.selector);
        }
        try registry.resolveApplicableFee{gas: REGISTRY_GAS_LIMIT}(expected.policyEpoch, assetVersionId) returns (
            bytes32 feeVersionId, bytes32 matchedScopeHash
        ) {
            if (feeVersionId != expected.versionId || matchedScopeHash != expected.matchedScopeHash) {
                return (fee, HTPErrors.FeeSnapshotMismatch.selector);
            }
        } catch (bytes memory revertData) {
            bytes4 reason = _errorSelector(revertData);
            if (reason == HTPErrors.FeeResolverNoMatch.selector) return (fee, reason);
            assembly ("memory-safe") {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }
    }

    /// @notice Confirms market rule serviceability and quantity grid constraints.
    function validateMarketRule(
        address dvp,
        MarketRuleReferences calldata expected,
        MarketRuleQuantities calldata quantities
    ) external view returns (bytes4 failureReason, uint256 priceTick, uint256 minCashPrincipal) {
        IMarketRuleRegistry registry = IDvPSettlement(dvp).marketRuleRegistry();
        MarketRuleRecord memory record = registry.getMarketRule{gas: REGISTRY_GAS_LIMIT}(expected.configId);
        bool serviceable = record.config.settlementToken == expected.settlementToken
            && record.config.settlementTokenConfigId == expected.settlementTokenConfigId
            && record.config.settlementTokenConfigHash == expected.settlementTokenConfigHash
            && registry.isMarketRuleServiceable{gas: REGISTRY_GAS_LIMIT}(
                expected.configId,
                expected.configHash,
                expected.assetVersionId,
                expected.createdAt,
                expected.quoteExpiresAt,
                expected.tradeDeadline
            );
        if (!serviceable) return (HTPErrors.MarketRuleSnapshotMismatch.selector, 0, 0);

        uint256 ruleStep = record.config.quantityStep;

        if (
            quantities.minimum < record.config.minExecutableQuantity || quantities.minimum % ruleStep != 0
                || quantities.maximum % ruleStep != 0 || quantities.step % ruleStep != 0
                || quantities.executed % ruleStep != 0
        ) return (HTPErrors.MarketRuleQuantityViolation.selector, 0, 0);
        return (bytes4(0), record.config.priceTick, record.config.minCashPrincipal);
    }

    function _assetVersionMatches(address dvp, AssetReference calldata expected, AssetVersionRecord memory record)
        private
        pure
        returns (bool)
    {
        return record.exists && record.status == AssetVersionStatus.ACTIVE
            && record.config.assetVersionId == expected.assetVersionId
            && record.config.assetToken == expected.assetToken && record.config.assetDecimals == expected.assetDecimals
            && record.config.assetClass == expected.assetClass
            && record.config.principalCalculatorConfigId == expected.principalCalculatorConfigId
            && record.config.principalCalculatorConfigHash == expected.principalCalculatorConfigHash
            && record.config.adapterConfigId == expected.adapterConfigId
            && record.config.adapterConfigHash == expected.adapterConfigHash
            && record.config.settlementToken == expected.settlementToken
            && record.config.settlementTokenConfigId == expected.settlementTokenConfigId
            && record.config.settlementTokenConfigHash == expected.settlementTokenConfigHash
            && record.config.dvpContract == dvp && record.config.deploymentVersionHash == expected.deploymentVersionHash;
    }

    function _feeRecordsServiceable(
        FeeReferences calldata expected,
        FeePolicyEpochRecord memory epoch,
        FeeVersionRecord memory fee
    ) private view returns (bool) {
        bool epochServiceable = epoch.exists && epoch.isSealed
            && (epoch.status == FeePolicyEpochStatus.ACTIVE || epoch.status == FeePolicyEpochStatus.LEGACY_SERVING);
        // N2: DEPRECATED remains serviceable for historical quotes; both paused states fail closed.
        bool feeServiceable =
            fee.exists && (fee.status == FeeVersionStatus.ACTIVE || fee.status == FeeVersionStatus.DEPRECATED);
        return epochServiceable && feeServiceable && epoch.config.feePolicyEpoch == expected.policyEpoch
            && fee.config.feeVersionId == expected.versionId && fee.config.feePolicyEpoch == expected.policyEpoch
            && fee.config.matchedScopeHash == expected.matchedScopeHash
            && fee.config.feeConstraintHash == expected.constraintHash
            && fee.config.settlementToken == expected.settlementToken
            && fee.config.settlementTokenConfigId == expected.settlementTokenConfigId
            && fee.config.settlementTokenConfigHash == expected.settlementTokenConfigHash
            && fee.config.collector == expected.collector && fee.config.roundingMode == RoundingMode.DOWN
            && expected.roundingMode == RoundingMode.DOWN && fee.config.roundingMode == expected.roundingMode
            && fee.config.validFrom <= expected.createdAt && expected.createdAt <= block.timestamp
            && block.timestamp <= expected.tradeDeadline && expected.tradeDeadline <= expected.quoteExpiresAt
            && expected.quoteExpiresAt <= fee.config.validUntil
            && expected.tradeDeadline <= epoch.config.settlementValidUntil;
    }

    function _adapterActive(AdapterRecord memory record, bytes32 expectedId, bytes32 expectedHash)
        private
        view
        returns (bool)
    {
        return record.exists && record.status == AdapterStatus.ACTIVE && record.config.adapterConfigId == expectedId
            && record.config.configHash == expectedHash && record.config.adapter.code.length != 0
            && record.config.adapter.codehash == record.config.codeHash;
    }

    function _errorSelector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}
