// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "../../src/libraries/ConfigId.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {
    LinearConfigMetadata,
    LinearConfigRegistryBase,
    LinearConfigTransition
} from "../../src/registry/LinearConfigRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {ReasonCode} from "../../src/types/HTPTypes.sol";

contract LinearConfigRegistryHarness is LinearConfigRegistryBase {
    bytes32 private constant CONFIG_NAMESPACE = 0xef09d4e1b5bdc23be85335f00c7d632f774f172ae3aabb47db96d9046fc7aa80;
    bytes32 private constant CONFIG_TYPEHASH = 0x0c6643da6aa8e3b43104abd9c2944d67bc8b7d391c98d6cc61355a0621e1334c;

    event Phase6ConfigRegistered(
        uint256 chainId,
        bytes32 indexed configId,
        bytes32 indexed subject,
        uint32 revision,
        bytes32 configHash,
        bytes32 replacesId,
        bytes32 payloadHash
    );
    event Phase6ConfigStatusChanged(
        uint256 chainId,
        bytes32 indexed configId,
        uint8 oldStatus,
        uint8 newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );
    event Phase6CurrentConfigChanged(
        uint256 chainId,
        bytes32 indexed subject,
        bytes32 indexed oldConfigId,
        bytes32 indexed newConfigId,
        address actor
    );

    /// @custom:storage-location erc7201:htp.storage.LinearConfigRegistryHarness
    struct HarnessStorage {
        mapping(bytes32 configId => bytes32 payloadHash) payloadHashes;
    }

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

        _getHarnessStorage().payloadHashes[configId] = payloadHash;
        _registerLinearConfig(configId, subject, revision, replacesId, configHash);
        emit Phase6ConfigRegistered(block.chainid, configId, subject, revision, configHash, replacesId, payloadHash);
    }

    function activateConfig(bytes32 configId, bytes32 expectedConfigHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        LinearConfigTransition memory transition = _activateLinearConfig(configId, expectedConfigHash);
        emit Phase6ConfigStatusChanged(
            block.chainid, configId, transition.oldStatus, transition.newStatus, ReasonCode.NONE, bytes32(0), msg.sender
        );
        emit Phase6CurrentConfigChanged(
            block.chainid, transition.subject, transition.oldCurrent, transition.newCurrent, msg.sender
        );
    }

    function pauseConfig(bytes32 configId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.PAUSER_ROLE)
    {
        _changeStatus(configId, CONFIG_STATUS_PAUSED, reason, evidenceHash);
    }

    function unpauseConfig(bytes32 configId, bytes32 expectedConfigHash, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        LinearConfigTransition memory transition =
            _unpauseLinearConfig(configId, expectedConfigHash, reason, evidenceHash);
        emit Phase6ConfigStatusChanged(
            block.chainid, configId, transition.oldStatus, transition.newStatus, reason, evidenceHash, msg.sender
        );
    }

    function deprecateConfig(bytes32 configId, ReasonCode reason, bytes32 evidenceHash)
        external
        onlyRole(Roles.GOVERNANCE_ROLE)
    {
        _changeStatus(configId, CONFIG_STATUS_DEPRECATED, reason, evidenceHash);
    }

    function getConfig(bytes32 configId)
        external
        view
        returns (LinearConfigMetadata memory metadata, bytes32 payloadHash)
    {
        metadata = _linearConfigMetadata(configId);
        payloadHash = _getHarnessStorage().payloadHashes[configId];
    }

    function getCurrentConfig(bytes32 subject)
        external
        view
        returns (LinearConfigMetadata memory metadata, bytes32 payloadHash)
    {
        bytes32 configId = _currentLinearConfigId(subject);
        metadata = _linearConfigMetadata(configId);
        payloadHash = _getHarnessStorage().payloadHashes[configId];
    }

    function implementationVersion() external pure virtual returns (uint256) {
        return 1;
    }

    function _changeStatus(bytes32 configId, uint8 newStatus, ReasonCode reason, bytes32 evidenceHash) private {
        uint8 oldStatus = _transitionLinearConfig(configId, newStatus, reason, evidenceHash).oldStatus;
        emit Phase6ConfigStatusChanged(block.chainid, configId, oldStatus, newStatus, reason, evidenceHash, msg.sender);
    }

    function _recomputeLinearConfigHash(bytes32 configId) internal view virtual override returns (bytes32) {
        LinearConfigMetadata memory metadata = _linearConfigMetadata(configId);
        return _hashFixtureConfig(
            metadata.subject, metadata.revision, metadata.replacesId, _getHarnessStorage().payloadHashes[configId]
        );
    }

    function _hashFixtureConfig(bytes32 subject, uint32 revision, bytes32 replacesId, bytes32 payloadHash)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CONFIG_TYPEHASH, subject, revision, replacesId, payloadHash));
    }

    function _getHarnessStorage() private pure returns (HarnessStorage storage $) {
        assembly {
            $.slot := HARNESS_STORAGE_LOCATION
        }
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract LinearConfigRegistryHarnessV2 is LinearConfigRegistryHarness {
    function implementationVersion() external pure override returns (uint256) {
        return 2;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract LinearConfigRegistryBadHashV2 is LinearConfigRegistryHarness {
    function _recomputeLinearConfigHash(bytes32 configId) internal view override returns (bytes32) {
        return bytes32(uint256(super._recomputeLinearConfigHash(configId)) ^ 1);
    }
}
