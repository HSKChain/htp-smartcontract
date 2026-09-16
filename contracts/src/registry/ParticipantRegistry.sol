// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IParticipantRegistry} from "../interfaces/IParticipantRegistry.sol";
import {Roles} from "../libraries/Roles.sol";
import {
    ParticipantInput,
    ParticipantRecord,
    ParticipantStatus,
    ParticipantType,
    ReasonCode
} from "../types/HTPTypes.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {UUPSRegistryBase} from "./UUPSRegistryBase.sol";

contract ParticipantRegistry is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.ParticipantRegistry
    struct ParticipantRegistryStorage {
        mapping(address wallet => ParticipantRecord record) participants;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.ParticipantRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PARTICIPANT_REGISTRY_STORAGE_LOCATION =
        0x32f888f469726dc3bc7f8a2fba96525072e5836aa02a6633ea10b07558070e00;

    /// @notice Initializes roles for this upgradeable registry.
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }

    /// @notice Creates or updates a participant record with optimistic versioning.
    function setParticipant(ParticipantInput calldata input, uint64 expectedVersion)
        external
        onlyRole(Roles.CONFIGURER_ROLE)
    {
        _validateParticipantInput(input);
        ParticipantRegistryStorage storage $ = _getParticipantRegistryStorage();
        ParticipantRecord storage current = $.participants[input.wallet];
        uint64 actualVersion = current.version;
        if (actualVersion != expectedVersion) {
            revert HTPErrors.ParticipantVersionConflict(input.wallet, expectedVersion, actualVersion);
        }
        ParticipantStatus oldStatus = current.status;
        if (actualVersion == 0) {
            $.participants[input.wallet] = ParticipantRecord({
                wallet: input.wallet,
                participantIdHash: input.participantIdHash,
                participantType: input.participantType,
                status: ParticipantStatus.ACTIVE,
                validUntil: input.validUntil,
                version: 1,
                evidenceHash: input.evidenceHash
            });
        } else {
            if (current.status == ParticipantStatus.REVOKED) {
                revert HTPErrors.ParticipantPermanentlyRevoked(input.wallet);
            }
            if (
                current.participantIdHash != input.participantIdHash || current.participantType != input.participantType
            ) {
                revert HTPErrors.ParticipantIdentityImmutable(input.wallet);
            }
            current.validUntil = input.validUntil;
            current.version = actualVersion + 1;
            current.evidenceHash = input.evidenceHash;
        }
        _emitParticipantUpdated($.participants[input.wallet], oldStatus, actualVersion);
    }

    /// @notice Returns the stored participant record for a wallet.
    function getParticipant(address wallet) external view returns (ParticipantRecord memory) {
        return _getParticipantRegistryStorage().participants[wallet];
    }

    /// @notice Checks active status, type, and validity window for a wallet.
    function isParticipantActive(address wallet, ParticipantType expectedType) external view returns (bool) {
        ParticipantRecord storage record = _getParticipantRegistryStorage().participants[wallet];
        return record.version != 0 && record.status == ParticipantStatus.ACTIVE
            && record.participantType == expectedType && record.validUntil > block.timestamp;
    }

    /// @notice Pauses an active participant; requires reason and evidence.
    function pauseParticipant(address wallet, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        _requireReasonAndEvidence(reason, evidenceHash);
        ParticipantRecord storage record = _requireParticipantVersion(wallet, expectedVersion);
        if (record.status == ParticipantStatus.REVOKED) {
            revert HTPErrors.ParticipantPermanentlyRevoked(wallet);
        }
        if (record.status != ParticipantStatus.ACTIVE) {
            revert HTPErrors.ParticipantStateTransitionInvalid(wallet, record.status, ParticipantStatus.PAUSED);
        }
        record.status = ParticipantStatus.PAUSED;
        record.version = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitParticipantUpdated(record, ParticipantStatus.ACTIVE, expectedVersion);
    }

    /// @notice Resumes a paused participant under governance.
    function unpauseParticipant(address wallet, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _requireReasonAndEvidence(reason, evidenceHash);
        ParticipantRecord storage record = _requireParticipantVersion(wallet, expectedVersion);
        if (record.status == ParticipantStatus.REVOKED) {
            revert HTPErrors.ParticipantPermanentlyRevoked(wallet);
        }
        if (record.status != ParticipantStatus.PAUSED) {
            revert HTPErrors.ParticipantStateTransitionInvalid(wallet, record.status, ParticipantStatus.ACTIVE);
        }
        record.status = ParticipantStatus.ACTIVE;
        record.version = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitParticipantUpdated(record, ParticipantStatus.PAUSED, expectedVersion);
    }

    /// @notice Permanently revokes a participant; identity cannot be reused.
    function revokeParticipant(address wallet, uint64 expectedVersion, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
        ParticipantRecord storage record = _requireParticipantVersion(wallet, expectedVersion);
        if (record.status == ParticipantStatus.REVOKED) {
            revert HTPErrors.ParticipantPermanentlyRevoked(wallet);
        }
        ParticipantStatus oldStatus = record.status;
        record.status = ParticipantStatus.REVOKED;
        record.version = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitParticipantUpdated(record, oldStatus, expectedVersion);
        emit IParticipantRegistry.ParticipantRevoked(
            block.chainid, wallet, record.participantIdHash, expectedVersion, record.version, evidenceHash, _msgSender()
        );
    }

    function _getParticipantRegistryStorage() private pure returns (ParticipantRegistryStorage storage $) {
        assembly {
            $.slot := PARTICIPANT_REGISTRY_STORAGE_LOCATION
        }
    }

    function _validateParticipantInput(ParticipantInput calldata input) private view {
        if (input.wallet == address(0) || input.participantIdHash == bytes32(0)) {
            revert HTPErrors.InvalidParticipantInput();
        }
        if (input.participantType == ParticipantType.NONE) {
            revert HTPErrors.InvalidParticipantType(input.participantType);
        }
        if (input.validUntil <= block.timestamp) {
            revert HTPErrors.InvalidParticipantValidity(input.validUntil, uint64(block.timestamp));
        }
    }

    function _requireParticipantVersion(address wallet, uint64 expectedVersion)
        private
        view
        returns (ParticipantRecord storage record)
    {
        record = _getParticipantRegistryStorage().participants[wallet];
        if (record.version == 0) revert HTPErrors.ParticipantNotFound(wallet);
        if (record.version != expectedVersion) {
            revert HTPErrors.ParticipantVersionConflict(wallet, expectedVersion, record.version);
        }
    }

    function _emitParticipantUpdated(ParticipantRecord storage record, ParticipantStatus oldStatus, uint64 oldVersion)
        private
    {
        emit IParticipantRegistry.ParticipantUpdated(
            block.chainid,
            record.wallet,
            record.participantIdHash,
            record.participantType,
            oldStatus,
            record.status,
            record.validUntil,
            oldVersion,
            record.version,
            record.evidenceHash,
            _msgSender()
        );
    }
}
