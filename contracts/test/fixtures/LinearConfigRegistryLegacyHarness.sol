// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "../../src/libraries/ConfigId.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {LinearConfigMetadata} from "../../src/registry/LinearConfigRegistryBase.sol";
import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";

contract LinearConfigRegistryLegacyHarness is UUPSRegistryBase {
    uint8 private constant CONFIG_STATUS_REGISTERED = 1;
    uint8 private constant CONFIG_STATUS_ACTIVE = 2;
    bytes32 private constant CONFIG_NAMESPACE = 0xef09d4e1b5bdc23be85335f00c7d632f774f172ae3aabb47db96d9046fc7aa80;
    bytes32 private constant CONFIG_TYPEHASH = 0x0c6643da6aa8e3b43104abd9c2944d67bc8b7d391c98d6cc61355a0621e1334c;

    /// @custom:storage-location erc7201:htp.storage.LinearConfigRegistryBase
    struct LegacyLinearConfigRegistryStorage {
        mapping(bytes32 configId => LinearConfigMetadata metadata) configs;
        mapping(bytes32 subject => bytes32 configId) currentConfigIds;
        mapping(bytes32 subject => mapping(uint32 revision => bytes32 configId)) configIdsByRevision;
    }

    /// @custom:storage-location erc7201:htp.storage.LinearConfigRegistryHarness
    struct HarnessStorage {
        mapping(bytes32 configId => bytes32 payloadHash) payloadHashes;
    }

    bytes32 private constant LINEAR_CONFIG_REGISTRY_STORAGE_LOCATION =
        0x1d8e22faa80e1ae99c8b9340263952c288f12f756260a3c991daf97e855c7c00;
    bytes32 private constant HARNESS_STORAGE_LOCATION =
        0xc86116e233b06329fb8ad811402e8c01282a90b9c1ae08bb371aa35a4fc8bf00;

    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function registerConfig(
        bytes32 configId,
        bytes32 subject,
        uint32 revision,
        bytes32 replacesId,
        bytes32 payloadHash,
        bytes32 configHash
    ) external onlyRole(Roles.CONFIGURER_ROLE) {
        bytes32 derivedId = ConfigId.derive(CONFIG_NAMESPACE, 1, block.chainid, subject, revision);
        if (configId != derivedId) revert HTPErrors.ConfigIdMismatch(configId, derivedId);
        bytes32 recomputedHash = _hashFixtureConfig(subject, revision, replacesId, payloadHash);
        if (configHash != recomputedHash) {
            revert HTPErrors.ConfigHashMismatch(configHash, recomputedHash);
        }

        LegacyLinearConfigRegistryStorage storage $ = _getLegacyStorage();
        if ($.configs[configId].exists) revert HTPErrors.ConfigAlreadyExists(configId);
        bytes32 occupiedId = $.configIdsByRevision[subject][revision];
        if (occupiedId != bytes32(0)) {
            revert HTPErrors.ConfigRevisionAlreadyExists(subject, revision, occupiedId);
        }

        bytes32 currentId = $.currentConfigIds[subject];
        uint32 expectedRevision = currentId == bytes32(0) ? 1 : $.configs[currentId].revision + 1;
        if (revision != expectedRevision) {
            revert HTPErrors.ConfigRevisionMismatch(subject, expectedRevision, revision);
        }
        if (replacesId != currentId) revert HTPErrors.ConfigReplacesMismatch(currentId, replacesId);

        $.configs[configId] = LinearConfigMetadata({
            subject: subject,
            revision: revision,
            replacesId: replacesId,
            configHash: configHash,
            status: CONFIG_STATUS_REGISTERED,
            exists: true
        });
        $.configIdsByRevision[subject][revision] = configId;
        _getHarnessStorage().payloadHashes[configId] = payloadHash;
    }

    function activateConfig(bytes32 configId, bytes32 expectedConfigHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        LegacyLinearConfigRegistryStorage storage $ = _getLegacyStorage();
        LinearConfigMetadata storage metadata = $.configs[configId];
        if (!metadata.exists) revert HTPErrors.ConfigNotFound(configId);
        if (expectedConfigHash != metadata.configHash) {
            revert HTPErrors.ConfigHashMismatch(expectedConfigHash, metadata.configHash);
        }
        if (metadata.status != CONFIG_STATUS_REGISTERED) {
            revert HTPErrors.UnauthorizedStateTransition(configId, metadata.status, CONFIG_STATUS_ACTIVE);
        }
        metadata.status = CONFIG_STATUS_ACTIVE;
        $.currentConfigIds[metadata.subject] = configId;
    }

    function _hashFixtureConfig(bytes32 subject, uint32 revision, bytes32 replacesId, bytes32 payloadHash)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CONFIG_TYPEHASH, subject, revision, replacesId, payloadHash));
    }

    function _getLegacyStorage() private pure returns (LegacyLinearConfigRegistryStorage storage $) {
        assembly {
            $.slot := LINEAR_CONFIG_REGISTRY_STORAGE_LOCATION
        }
    }

    function _getHarnessStorage() private pure returns (HarnessStorage storage $) {
        assembly {
            $.slot := HARNESS_STORAGE_LOCATION
        }
    }
}
