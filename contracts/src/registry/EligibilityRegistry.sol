// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {Decision, EligibilityInput, EligibilityRecord, ReasonCode} from "../types/HTPTypes.sol";
import {UUPSRegistryBase} from "./UUPSRegistryBase.sol";

contract EligibilityRegistry is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.EligibilityRegistry
    struct EligibilityRegistryStorage {
        mapping(bytes32 eligibilityKey => EligibilityRecord record) eligibilities;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.EligibilityRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ELIGIBILITY_REGISTRY_STORAGE_LOCATION =
        0x9791a9a8b9b8a2a73ceb19cc363f529ce15153a98f0f97ddc320a85ca4ba1a00;

    /// @notice Initializes roles for this upgradeable registry.
    function initialize(address defaultAdmin, address governance, address upgrader, address pauser, address configurer)
        external
        initializer
    {
        _initializeRegistryBase(defaultAdmin, governance, upgrader, pauser, configurer);
    }

    /// @notice Upserts eligibility for a wallet and asset version with version checks.
    function setEligibility(EligibilityInput calldata input, uint64 expectedRecordVersion)
        external
        onlyRole(Roles.CONFIGURER_ROLE)
    {
        if (
            input.wallet == address(0) || input.assetVersionId == bytes32(0) || input.decision == Decision.NONE
                || input.validUntil < input.validFrom || input.evidenceHash == bytes32(0)
        ) {
            revert HTPErrors.InvalidEligibilityInput();
        }

        bytes32 eligibilityKey = _eligibilityKey(input.wallet, input.assetVersionId);
        EligibilityRecord storage current = _getEligibilityRegistryStorage().eligibilities[eligibilityKey];
        if (current.recordVersion != expectedRecordVersion) {
            revert HTPErrors.EligibilityVersionConflict(eligibilityKey, expectedRecordVersion, current.recordVersion);
        }
        if (current.revoked) revert HTPErrors.EligibilityPausedOrRevoked(eligibilityKey);

        bool paused = current.paused;
        uint64 newRecordVersion = expectedRecordVersion + 1;
        _getEligibilityRegistryStorage().eligibilities[eligibilityKey] = EligibilityRecord({
            eligibilityKey: eligibilityKey,
            wallet: input.wallet,
            assetVersionId: input.assetVersionId,
            decision: input.decision,
            validFrom: input.validFrom,
            validUntil: input.validUntil,
            kycDecisionVersion: input.kycDecisionVersion,
            permissionVersion: input.permissionVersion,
            recordVersion: newRecordVersion,
            paused: paused,
            revoked: false,
            evidenceHash: input.evidenceHash
        });
        _emitEligibilityUpdated(_getEligibilityRegistryStorage().eligibilities[eligibilityKey], expectedRecordVersion);
    }

    /// @notice Pauses an eligibility record without revoking it.
    function pauseEligibility(bytes32 eligibilityKey, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        _requireReasonAndEvidence(reason, evidenceHash);
        EligibilityRecord storage record = _requireEligibilityVersion(eligibilityKey, expectedVersion);
        if (record.paused || record.revoked) revert HTPErrors.EligibilityPausedOrRevoked(eligibilityKey);
        record.paused = true;
        record.recordVersion = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitEligibilityUpdated(record, expectedVersion);
    }

    /// @notice Clears pause on an eligibility record under governance.
    function unpauseEligibility(bytes32 eligibilityKey, uint64 expectedVersion, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _requireReasonAndEvidence(reason, evidenceHash);
        EligibilityRecord storage record = _requireEligibilityVersion(eligibilityKey, expectedVersion);
        if (record.revoked) revert HTPErrors.EligibilityPausedOrRevoked(eligibilityKey);
        if (!record.paused) revert HTPErrors.InvalidEligibilityInput();
        record.paused = false;
        record.recordVersion = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitEligibilityUpdated(record, expectedVersion);
    }

    /// @notice Permanently revokes an eligibility record.
    function revokeEligibility(bytes32 eligibilityKey, uint64 expectedVersion, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
        EligibilityRecord storage record = _requireEligibilityVersion(eligibilityKey, expectedVersion);
        if (record.revoked) revert HTPErrors.EligibilityPausedOrRevoked(eligibilityKey);
        record.revoked = true;
        record.recordVersion = expectedVersion + 1;
        record.evidenceHash = evidenceHash;
        _emitEligibilityUpdated(record, expectedVersion);
        emit IEligibilityRegistry.EligibilityRevoked(
            block.chainid,
            eligibilityKey,
            record.assetVersionId,
            expectedVersion,
            record.recordVersion,
            evidenceHash,
            _msgSender()
        );
    }

    /// @notice Returns the eligibility record for a derived key.
    function getEligibility(bytes32 eligibilityKey) external view returns (EligibilityRecord memory) {
        return _getEligibilityRegistryStorage().eligibilities[eligibilityKey];
    }

    /// @notice Evaluates pass decision, pause/revoke flags, and validity window.
    function isEligible(address wallet, bytes32 assetVersionId) external view returns (bool eligible, bytes4 reason) {
        if (wallet == address(0) || assetVersionId == bytes32(0)) {
            return (false, HTPErrors.InvalidEligibilityInput.selector);
        }

        bytes32 eligibilityKey = _eligibilityKey(wallet, assetVersionId);
        EligibilityRecord storage record = _getEligibilityRegistryStorage().eligibilities[eligibilityKey];
        if (record.recordVersion == 0) return (false, HTPErrors.EligibilityNotFound.selector);
        if (record.eligibilityKey != eligibilityKey || record.wallet != wallet) {
            return (false, HTPErrors.EligibilityKeyMismatch.selector);
        }
        if (record.assetVersionId != assetVersionId) {
            return (false, HTPErrors.EligibilityAssetVersionMismatch.selector);
        }
        if (record.decision != Decision.PASS) return (false, HTPErrors.EligibilityNotPassed.selector);
        if (record.paused || record.revoked) return (false, HTPErrors.EligibilityPausedOrRevoked.selector);
        if (block.timestamp < record.validFrom || block.timestamp > record.validUntil) {
            return (false, HTPErrors.EligibilityExpired.selector);
        }
        return (true, bytes4(0));
    }

    function _eligibilityKey(address wallet, bytes32 assetVersionId) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, assetVersionId));
    }

    function _requireEligibilityVersion(bytes32 eligibilityKey, uint64 expectedVersion)
        private
        view
        returns (EligibilityRecord storage record)
    {
        record = _getEligibilityRegistryStorage().eligibilities[eligibilityKey];
        if (record.recordVersion == 0) revert HTPErrors.EligibilityNotFound(eligibilityKey);
        if (record.recordVersion != expectedVersion) {
            revert HTPErrors.EligibilityVersionConflict(eligibilityKey, expectedVersion, record.recordVersion);
        }
    }

    function _emitEligibilityUpdated(EligibilityRecord storage record, uint64 oldRecordVersion) private {
        emit IEligibilityRegistry.EligibilityUpdated(
            block.chainid,
            record.eligibilityKey,
            record.wallet,
            record.assetVersionId,
            record.decision,
            record.validFrom,
            record.validUntil,
            record.kycDecisionVersion,
            record.permissionVersion,
            oldRecordVersion,
            record.recordVersion,
            record.paused,
            record.revoked,
            record.evidenceHash,
            _msgSender()
        );
    }

    function _getEligibilityRegistryStorage() private pure returns (EligibilityRegistryStorage storage $) {
        assembly {
            $.slot := ELIGIBILITY_REGISTRY_STORAGE_LOCATION
        }
    }
}
