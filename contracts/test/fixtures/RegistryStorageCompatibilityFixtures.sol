// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UUPSRegistryBase} from "../../src/registry/UUPSRegistryBase.sol";

contract RegistryStorageCompatibilityV1 is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.RegistryStorageCompatibilityFixture
    struct FixtureStorage {
        uint256 value;
        address owner;
    }

    bytes32 private constant FIXTURE_STORAGE_LOCATION =
        0xeec37312ed1cd3f131330b6b072fdeab7ce5e0f90c42c1f9328e55d15b714000;

    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function setFixture(uint256 value, address owner) external {
        FixtureStorage storage $ = _getFixtureStorage();
        $.value = value;
        $.owner = owner;
    }

    function getFixture() external view returns (uint256 value, address owner) {
        FixtureStorage storage $ = _getFixtureStorage();
        return ($.value, $.owner);
    }

    function _getFixtureStorage() private pure returns (FixtureStorage storage $) {
        assembly {
            $.slot := FIXTURE_STORAGE_LOCATION
        }
    }
}

contract RegistryStorageCompatibilityV2 is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.RegistryStorageCompatibilityFixture
    struct FixtureStorage {
        uint256 value;
        address owner;
        bytes32 appendedEvidenceHash;
    }

    bytes32 private constant FIXTURE_STORAGE_LOCATION =
        0xeec37312ed1cd3f131330b6b072fdeab7ce5e0f90c42c1f9328e55d15b714000;

    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function getFixture() external view returns (uint256 value, address owner) {
        FixtureStorage storage $ = _getFixtureStorage();
        return ($.value, $.owner);
    }

    function _getFixtureStorage() private pure returns (FixtureStorage storage $) {
        assembly {
            $.slot := FIXTURE_STORAGE_LOCATION
        }
    }
}

contract RegistryStorageIncompatibleV2 is UUPSRegistryBase {
    /// @custom:storage-location erc7201:htp.storage.RegistryStorageCompatibilityFixture
    struct FixtureStorage {
        address owner;
        uint256 value;
    }

    bytes32 private constant FIXTURE_STORAGE_LOCATION =
        0xeec37312ed1cd3f131330b6b072fdeab7ce5e0f90c42c1f9328e55d15b714000;

    function initialize(address timelock, address pauser, address configurer) external initializer {
        _initializeRegistryBase(timelock, timelock, timelock, pauser, configurer);
    }

    function getFixture() external view returns (address owner, uint256 value) {
        FixtureStorage storage $ = _getFixtureStorage();
        return ($.owner, $.value);
    }

    function _getFixtureStorage() private pure returns (FixtureStorage storage $) {
        assembly {
            $.slot := FIXTURE_STORAGE_LOCATION
        }
    }
}
