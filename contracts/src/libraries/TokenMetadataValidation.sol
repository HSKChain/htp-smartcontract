// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {BoundedStaticCall} from "./BoundedStaticCall.sol";
import {RegistryImplementationValidation} from "./RegistryImplementationValidation.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {TokenDeploymentKind} from "../types/HTPTypes.sol";

library TokenMetadataValidation {
    uint256 internal constant INVALID_DECIMALS = type(uint256).max;
    uint256 internal constant VALIDATION_GAS_LIMIT = 30_000;
    bytes4 private constant DECIMALS_SELECTOR = 0x313ce567;

    function readDecimals(address token) internal view returns (bool valid, uint256 actual) {
        (bool callSucceeded, bool returnWellFormed, bytes32 result) = BoundedStaticCall.staticCallWordStatus(
            token, abi.encodeWithSelector(DECIMALS_SELECTOR), VALIDATION_GAS_LIMIT
        );
        actual = uint256(result);
        valid = callSucceeded && returnWellFormed && actual <= type(uint8).max;
        if (!valid) actual = INVALID_DECIMALS;
    }

    /// @notice Reverts if on-chain decimals differ from the expected asset decimals.
    function requireAssetDecimals(address token, uint8 expected) internal view {
        (bool valid, uint256 actual) = readDecimals(token);

        if (!valid || actual != expected) revert HTPErrors.AssetDecimalsMismatch(token, expected, actual);
    }

    /// @notice Reverts if on-chain decimals differ from the expected settlement token decimals.
    function requireSettlementTokenDecimals(address token, uint8 expected) internal view {
        (bool valid, uint256 actual) = readDecimals(token);

        if (!valid || actual != expected) {
            revert HTPErrors.SettlementTokenDecimalsMismatch(token, expected, actual);
        }
    }

    /// @notice Validates token runtime code hash and deployment kind against registry baseline.
    function requireTokenDeployment(
        address token,
        TokenDeploymentKind kind,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash
    ) internal view {
        if (kind != TokenDeploymentKind.DIRECT && kind != TokenDeploymentKind.ERC1967_PROXY) {
            revert HTPErrors.InvalidTokenDeploymentKind(kind);
        }

        (bool hasCode, bytes32 actualCodeHash) = _runtimeCodeHash(token);

        if (!hasCode || tokenCodeHash != actualCodeHash) {
            revert HTPErrors.TokenCodeHashMismatch(token, tokenCodeHash, actualCodeHash);
        }

        if (!implementationBaselineMatches(kind, implementation, implementationCodeHash)) {
            revert HTPErrors.TokenImplementationBaselineInvalid(kind, implementation, implementationCodeHash);
        }

        if (kind == TokenDeploymentKind.DIRECT && RegistryImplementationValidation.hasProxyShape(token)) {
            revert HTPErrors.TokenDeploymentKindMismatch(token, kind);
        }
    }

    function deploymentBaselineMatches(
        address token,
        TokenDeploymentKind kind,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash
    ) internal view returns (bool) {
        (bool hasCode, bytes32 actualCodeHash) = _runtimeCodeHash(token);
        return hasCode && tokenCodeHash == actualCodeHash
            && implementationBaselineMatches(kind, implementation, implementationCodeHash);
    }

    function implementationBaselineMatches(
        TokenDeploymentKind kind,
        address implementation,
        bytes32 implementationCodeHash
    ) internal pure returns (bool) {
        if (kind == TokenDeploymentKind.DIRECT) {
            return implementation == address(0) && implementationCodeHash == bytes32(0);
        }
        if (kind == TokenDeploymentKind.ERC1967_PROXY) {
            return implementation != address(0) && implementationCodeHash != bytes32(0);
        }
        return false;
    }

    function _runtimeCodeHash(address token) private view returns (bool hasCode, bytes32 actualCodeHash) {
        hasCode = token.code.length > 0;
        actualCodeHash = token.codehash;
    }
}
