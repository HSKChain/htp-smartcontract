// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Decision, EligibilityInput, EligibilityRecord, ReasonCode} from "../types/HTPTypes.sol";

interface IEligibilityRegistry {
    event EligibilityUpdated(
        uint256 chainId,
        bytes32 indexed eligibilityKey,
        address indexed wallet,
        bytes32 indexed assetVersionId,
        Decision decision,
        uint64 validFrom,
        uint64 validUntil,
        bytes32 kycDecisionVersion,
        bytes32 permissionVersion,
        uint64 oldRecordVersion,
        uint64 newRecordVersion,
        bool paused,
        bool revoked,
        bytes32 evidenceHash,
        address actor
    );

    event EligibilityRevoked(
        uint256 chainId,
        bytes32 indexed eligibilityKey,
        bytes32 indexed assetVersionId,
        uint64 oldRecordVersion,
        uint64 newRecordVersion,
        bytes32 evidenceHash,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Create or update eligibility; optimistic concurrency via expectedRecordVersion.
    function setEligibility(EligibilityInput calldata input, uint64 expectedRecordVersion) external;

    function pauseEligibility(bytes32 eligibilityKey, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external;

    function unpauseEligibility(bytes32 eligibilityKey, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external;

    /// @notice Permanently revoke eligibility for the key.
    function revokeEligibility(bytes32 eligibilityKey, uint64 expectedVersion, bytes32 evidenceHash) external;

    function getEligibility(bytes32 eligibilityKey) external view returns (EligibilityRecord memory);

    /// @notice Fail-closed eligibility check for wallet and asset version.
    function isEligible(address wallet, bytes32 assetVersionId) external view returns (bool eligible, bytes4 reason);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
