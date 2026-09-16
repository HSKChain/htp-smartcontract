// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    ParticipantInput, ParticipantRecord, ParticipantStatus, ParticipantType, ReasonCode
} from "../types/HTPTypes.sol";

interface IParticipantRegistry {
    event ParticipantUpdated(
        uint256 chainId,
        address indexed wallet,
        bytes32 indexed participantIdHash,
        ParticipantType participantType,
        ParticipantStatus oldStatus,
        ParticipantStatus newStatus,
        uint64 validUntil,
        uint64 oldVersion,
        uint64 newVersion,
        bytes32 evidenceHash,
        address actor
    );

    event ParticipantRevoked(
        uint256 chainId,
        address indexed wallet,
        bytes32 indexed participantIdHash,
        uint64 oldVersion,
        uint64 newVersion,
        bytes32 evidenceHash,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Register or update participant identity; identity fields immutable after first write.
    function setParticipant(ParticipantInput calldata input, uint64 expectedVersion) external;

    function pauseParticipant(address wallet, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseParticipant(address wallet, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash) external;

    function revokeParticipant(address wallet, uint64 expectedVersion, bytes32 evidenceHash) external;

    function getParticipant(address wallet) external view returns (ParticipantRecord memory);

    /// @notice Fail-closed active check: registered, ACTIVE, type match, validUntil > now.
    function isParticipantActive(address wallet, ParticipantType expectedType) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
