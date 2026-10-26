// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    ReasonCode,
    RoundingMode,
    ScopeType
} from "../types/HTPTypes.sol";

interface IFeeRegistry {
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

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Open a new fee policy epoch with quote and settlement validity windows.
    function createFeePolicyEpoch(FeePolicyEpochConfig calldata config) external;

    function sealFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 expectedConfigHash) external;
    function activateFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 expectedConfigHash, bytes32 readinessFeeVersionId)
        external;
    function moveFeePolicyEpochToLegacyServing(uint64 feePolicyEpoch, bytes32 evidenceHash) external;
    function closeFeePolicyEpoch(uint64 feePolicyEpoch, bytes32 evidenceHash) external;

    /// @notice Register a fee version under an epoch and matched scope.
    function registerFeeVersion(FeeConfig calldata config) external;

    function activateFeeVersion(bytes32 feeVersionId, bytes32 expectedConfigHash) external;
    function pauseFeeVersion(bytes32 feeVersionId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseFeeVersion(
        bytes32 feeVersionId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external;

    function deprecateFeeVersion(bytes32 feeVersionId, ReasonCode reason, bytes32 evidenceHash) external;
    function getFeePolicyEpoch(uint64 feePolicyEpoch) external view returns (FeePolicyEpochRecord memory);
    function getFeeVersion(bytes32 feeVersionId) external view returns (FeeVersionRecord memory);

    /// @notice Resolve best-matching fee version for epoch and asset version.
    function resolveApplicableFee(uint64 feePolicyEpoch, bytes32 assetVersionId)
        external
        view
        returns (bytes32 feeVersionId, bytes32 matchedScopeHash);

    /// @notice Whether fee version is executable for epoch, asset, and constraint binding.
    function isFeeVersionExecutable(
        uint64 feePolicyEpoch,
        bytes32 assetVersionId,
        bytes32 feeVersionId,
        bytes32 matchedScopeHash,
        bytes32 feeConstraintHash
    ) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
