// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "../types/HTPErrors.sol";

/// @notice Semantic version strings for deployment identity hashing.
library DeploymentVersion {
    bytes32 internal constant DOMAIN = keccak256("HTP_DEPLOYMENT_VERSION");

    /// @notice True when version matches major.minor.patch with no leading-zero segments.
    function isCanonical(bytes memory version) internal pure returns (bool) {
        if (version.length < 5) {
            return false;
        }

        uint256 dotCount;
        uint256 segmentStart;
        for (uint256 index; index < version.length; ++index) {
            bytes1 character = version[index];

            if (character >= 0x30 && character <= 0x39) {
                continue;
            }

            if (character != 0x2e || dotCount == 2 || !_isCanonicalSegment(version, segmentStart, index)) {
                return false;
            }
            ++dotCount;
            segmentStart = index + 1;
        }

        return dotCount == 2 && _isCanonicalSegment(version, segmentStart, version.length);
    }

    /// @notice Major segment of a canonical version (e.g. "1" from "1.2.3").
    function domainVersion(bytes memory version) internal pure returns (string memory) {
        _requireCanonical(version);
        uint256 majorLength;
        while (version[majorLength] != 0x2e) {
            ++majorLength;
        }

        bytes memory major = new bytes(majorLength);
        for (uint256 index; index < majorLength; ++index) {
            major[index] = version[index];
        }
        return string(major);
    }

    /// @notice Domain-tagged hash of a canonical deployment version string.
    function hash(bytes memory version) internal pure returns (bytes32) {
        _requireCanonical(version);
        return keccak256(abi.encode(DOMAIN, keccak256(version)));
    }

    function _isCanonicalSegment(bytes memory version, uint256 start, uint256 end) private pure returns (bool) {
        return end > start && (end - start == 1 || version[start] != 0x30);
    }

    function _requireCanonical(bytes memory version) private pure {
        if (!isCanonical(version)) {
            revert HTPErrors.InvalidDeploymentVersion();
        }
    }
}
