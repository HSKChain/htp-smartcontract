// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "../types/HTPErrors.sol";
import {ReasonCode} from "../types/HTPTypes.sol";
import {UUPSRegistryBase} from "./UUPSRegistryBase.sol";

struct LinearConfigMetadata {
    bytes32 subject;
    uint32 revision;
    bytes32 replacesId;
    bytes32 configHash;
    uint8 status;
    bool exists;
}

struct LinearConfigTransition {
    bytes32 subject;
    uint8 oldStatus;
    uint8 newStatus;
    bytes32 oldCurrent;
    bytes32 newCurrent;
}

abstract contract LinearConfigRegistryBase is UUPSRegistryBase {
    uint8 internal constant CONFIG_STATUS_REGISTERED = 1;
    uint8 internal constant CONFIG_STATUS_ACTIVE = 2;
    uint8 internal constant CONFIG_STATUS_PAUSED = 3;
    uint8 internal constant CONFIG_STATUS_DEPRECATED = 4;

    /// @custom:storage-location erc7201:htp.storage.LinearConfigRegistryBase
    struct LinearConfigRegistryStorage {
        mapping(bytes32 configId => LinearConfigMetadata metadata) configs;
        mapping(bytes32 subject => bytes32 configId) currentConfigIds;
        mapping(bytes32 subject => mapping(uint32 revision => bytes32 configId)) configIdsByRevision;
        mapping(bytes32 subject => bytes32 configId) latestConfigIds;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.LinearConfigRegistryBase")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LINEAR_CONFIG_REGISTRY_STORAGE_LOCATION =
        0x1d8e22faa80e1ae99c8b9340263952c288f12f756260a3c991daf97e855c7c00;

    function _registerLinearConfig(
        bytes32 configId,
        bytes32 subject,
        uint32 revision,
        bytes32 replacesId,
        bytes32 configHash
    ) internal {
        if (configId == bytes32(0) || configHash == bytes32(0)) {
            revert HTPErrors.InvalidConfigIdentity();
        }

        LinearConfigRegistryStorage storage $ = _getLinearConfigRegistryStorage();
        if ($.configs[configId].exists) revert HTPErrors.ConfigAlreadyExists(configId);

        bytes32 occupiedId = $.configIdsByRevision[subject][revision];
        if (occupiedId != bytes32(0)) {
            revert HTPErrors.ConfigRevisionAlreadyExists(subject, revision, occupiedId);
        }

        bytes32 latestId = $.latestConfigIds[subject];
        if (latestId == bytes32(0) && replacesId != bytes32(0)) {
            LinearConfigMetadata storage replacement = $.configs[replacesId];
            _requireExisting(replacesId, replacement);
            if (replacement.subject != subject) {
                revert HTPErrors.ConfigSubjectMismatch(replacesId, subject, replacement.subject);
            }
            latestId = replacesId;
        }
        uint32 expectedRevision = 1;
        if (latestId != bytes32(0)) {
            expectedRevision = $.configs[latestId].revision + 1;
        }
        if (revision != expectedRevision) {
            revert HTPErrors.ConfigRevisionMismatch(subject, expectedRevision, revision);
        }
        if (replacesId != latestId) {
            revert HTPErrors.ConfigReplacesMismatch(latestId, replacesId);
        }

        $.configs[configId] = LinearConfigMetadata({
            subject: subject,
            revision: revision,
            replacesId: replacesId,
            configHash: configHash,
            status: CONFIG_STATUS_REGISTERED,
            exists: true
        });
        $.configIdsByRevision[subject][revision] = configId;
        $.latestConfigIds[subject] = configId;
    }

    function _activateLinearConfig(bytes32 configId, bytes32 expectedConfigHash)
        internal
        returns (LinearConfigTransition memory transition)
    {
        LinearConfigRegistryStorage storage $ = _getLinearConfigRegistryStorage();
        LinearConfigMetadata storage metadata = $.configs[configId];
        _requireExisting(configId, metadata);
        _requireConfigHashes(configId, expectedConfigHash, metadata.configHash);
        bytes32 latestId = $.latestConfigIds[metadata.subject];
        if (latestId != bytes32(0) && latestId != configId) {
            revert HTPErrors.ConfigNotLatest(configId, latestId);
        }
        if (metadata.status != CONFIG_STATUS_REGISTERED) {
            revert HTPErrors.UnauthorizedStateTransition(configId, metadata.status, CONFIG_STATUS_ACTIVE);
        }

        transition.subject = metadata.subject;
        transition.oldStatus = metadata.status;
        transition.oldCurrent = $.currentConfigIds[metadata.subject];
        metadata.status = CONFIG_STATUS_ACTIVE;
        if (latestId == bytes32(0)) $.latestConfigIds[metadata.subject] = configId;
        $.currentConfigIds[metadata.subject] = configId;
        transition.newStatus = CONFIG_STATUS_ACTIVE;
        transition.newCurrent = configId;
    }

    function _unpauseLinearConfig(bytes32 configId, bytes32 expectedConfigHash, ReasonCode reason, bytes32 evidenceHash)
        internal
        returns (LinearConfigTransition memory transition)
    {
        LinearConfigRegistryStorage storage $ = _getLinearConfigRegistryStorage();
        LinearConfigMetadata storage metadata = $.configs[configId];
        _requireExisting(configId, metadata);
        _requireReasonAndEvidence(reason, evidenceHash);
        _requireConfigHashes(configId, expectedConfigHash, metadata.configHash);
        if (metadata.status != CONFIG_STATUS_PAUSED) {
            revert HTPErrors.UnauthorizedStateTransition(configId, metadata.status, CONFIG_STATUS_ACTIVE);
        }
        transition.subject = metadata.subject;
        transition.oldStatus = metadata.status;
        transition.oldCurrent = $.currentConfigIds[metadata.subject];
        metadata.status = CONFIG_STATUS_ACTIVE;
        transition.newStatus = CONFIG_STATUS_ACTIVE;
        transition.newCurrent = transition.oldCurrent;
    }

    function _transitionLinearConfig(bytes32 configId, uint8 newStatus, ReasonCode reason, bytes32 evidenceHash)
        internal
        returns (LinearConfigTransition memory transition)
    {
        LinearConfigRegistryStorage storage $ = _getLinearConfigRegistryStorage();
        LinearConfigMetadata storage metadata = $.configs[configId];
        _requireExisting(configId, metadata);
        _requireReasonAndEvidence(reason, evidenceHash);

        transition.subject = metadata.subject;
        transition.oldStatus = metadata.status;
        transition.oldCurrent = $.currentConfigIds[metadata.subject];
        bool allowed = transition.oldStatus == CONFIG_STATUS_ACTIVE && newStatus == CONFIG_STATUS_PAUSED;
        allowed = allowed || transition.oldStatus == CONFIG_STATUS_PAUSED && newStatus == CONFIG_STATUS_DEPRECATED;
        if (!allowed) {
            revert HTPErrors.UnauthorizedStateTransition(configId, transition.oldStatus, newStatus);
        }
        metadata.status = newStatus;
        transition.newStatus = newStatus;
        transition.newCurrent = transition.oldCurrent;
    }

    function _linearConfigMetadata(bytes32 configId) internal view returns (LinearConfigMetadata memory) {
        return _getLinearConfigRegistryStorage().configs[configId];
    }

    function _currentLinearConfigId(bytes32 subject) internal view returns (bytes32) {
        return _getLinearConfigRegistryStorage().currentConfigIds[subject];
    }

    function _recomputeLinearConfigHash(bytes32 configId) internal view virtual returns (bytes32);

    function _requireConfigHashes(bytes32 configId, bytes32 expectedConfigHash, bytes32 storedConfigHash) private view {
        if (expectedConfigHash != storedConfigHash) {
            revert HTPErrors.ConfigHashMismatch(expectedConfigHash, storedConfigHash);
        }
        bytes32 recomputedConfigHash = _recomputeLinearConfigHash(configId);
        if (storedConfigHash != recomputedConfigHash) {
            revert HTPErrors.ConfigHashMismatch(storedConfigHash, recomputedConfigHash);
        }
    }

    function _requireExisting(bytes32 configId, LinearConfigMetadata storage metadata) private view {
        if (!metadata.exists) revert HTPErrors.ConfigNotFound(configId);
    }

    function _getLinearConfigRegistryStorage() private pure returns (LinearConfigRegistryStorage storage $) {
        assembly {
            $.slot := LINEAR_CONFIG_REGISTRY_STORAGE_LOCATION
        }
    }
}
