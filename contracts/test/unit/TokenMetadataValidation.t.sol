// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenMetadataValidation} from "src/libraries/TokenMetadataValidation.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {TokenDeploymentKind} from "src/types/HTPTypes.sol";

contract CanonicalDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MalformedDecimalsToken {
    enum Mode {
        REVERTS,
        SHORT,
        LONG,
        HIGH_BITS
    }

    Mode private immutable MODE;

    constructor(Mode mode) {
        MODE = mode;
    }

    fallback() external {
        if (MODE == Mode.REVERTS) revert();
        if (MODE == Mode.SHORT) {
            assembly ("memory-safe") {
                mstore(0, 6)
                return(0, 0x1f)
            }
        }
        if (MODE == Mode.LONG) {
            assembly ("memory-safe") {
                mstore(0, 6)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        assembly ("memory-safe") {
            mstore(0, 0x0100)
            return(0, 0x20)
        }
    }
}

contract TokenMetadataValidationHarness {
    function readDecimals(address token) external view returns (bool valid, uint256 actual) {
        return TokenMetadataValidation.readDecimals(token);
    }

    function requireAssetDecimals(address token, uint8 expected) external view {
        TokenMetadataValidation.requireAssetDecimals(token, expected);
    }

    function requireSettlementTokenDecimals(address token, uint8 expected) external view {
        TokenMetadataValidation.requireSettlementTokenDecimals(token, expected);
    }

    function deploymentBaselineMatches(
        address token,
        TokenDeploymentKind kind,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash
    ) external view returns (bool) {
        return TokenMetadataValidation.deploymentBaselineMatches(
            token, kind, tokenCodeHash, implementation, implementationCodeHash
        );
    }

    function requireTokenDeployment(
        address token,
        TokenDeploymentKind kind,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash
    ) external view {
        TokenMetadataValidation.requireTokenDeployment(
            token, kind, tokenCodeHash, implementation, implementationCodeHash
        );
    }
}

contract TokenMetadataValidationTest is Test {
    TokenMetadataValidationHarness internal harness = new TokenMetadataValidationHarness();

    function testReadsCanonicalUint8Decimals() public {
        (bool valid, uint256 actual) = harness.readDecimals(address(new CanonicalDecimalsToken()));
        assertTrue(valid);
        assertEq(actual, 6);
    }

    function testAssetDecimalsMismatchAndMalformedReturnsUseStructuredError() public {
        CanonicalDecimalsToken token = new CanonicalDecimalsToken();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AssetDecimalsMismatch.selector, address(token), uint8(18), uint256(6))
        );
        harness.requireAssetDecimals(address(token), 18);

        for (uint256 mode; mode < 4; ++mode) {
            MalformedDecimalsToken malformed = new MalformedDecimalsToken(MalformedDecimalsToken.Mode(mode));
            vm.expectRevert(
                abi.encodeWithSelector(
                    HTPErrors.AssetDecimalsMismatch.selector, address(malformed), uint8(6), type(uint256).max
                )
            );
            harness.requireAssetDecimals(address(malformed), 6);
        }
    }

    function testSettlementDecimalsMismatchUsesSettlementSpecificError() public {
        CanonicalDecimalsToken token = new CanonicalDecimalsToken();
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.SettlementTokenDecimalsMismatch.selector, address(token), uint8(18), uint256(6)
            )
        );
        harness.requireSettlementTokenDecimals(address(token), 18);
    }

    function testDirectDeploymentRequiresRuntimeHashAndEmptyImplementationBaseline() public {
        CanonicalDecimalsToken token = new CanonicalDecimalsToken();
        harness.requireTokenDeployment(
            address(token), TokenDeploymentKind.DIRECT, address(token).codehash, address(0), bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidTokenDeploymentKind.selector, TokenDeploymentKind.NONE));
        harness.requireTokenDeployment(
            address(token), TokenDeploymentKind.NONE, address(token).codehash, address(0), bytes32(0)
        );

        bytes32 wrongCodeHash = bytes32(uint256(address(token).codehash) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TokenCodeHashMismatch.selector, address(token), wrongCodeHash, address(token).codehash
            )
        );
        harness.requireTokenDeployment(
            address(token), TokenDeploymentKind.DIRECT, wrongCodeHash, address(0), bytes32(0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TokenImplementationBaselineInvalid.selector,
                TokenDeploymentKind.DIRECT,
                address(0xCA1C),
                bytes32(uint256(1))
            )
        );
        harness.requireTokenDeployment(
            address(token), TokenDeploymentKind.DIRECT, address(token).codehash, address(0xCA1C), bytes32(uint256(1))
        );
    }

    function testProxyDeploymentRequiresNonzeroMonitoringBaselineWithoutReadingImplementationSlot() public {
        CanonicalDecimalsToken token = new CanonicalDecimalsToken();
        address reviewedImplementation = address(0xCA1C);
        bytes32 reviewedImplementationCodeHash = bytes32(uint256(0xBEEF));
        harness.requireTokenDeployment(
            address(token),
            TokenDeploymentKind.ERC1967_PROXY,
            address(token).codehash,
            reviewedImplementation,
            reviewedImplementationCodeHash
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TokenImplementationBaselineInvalid.selector,
                TokenDeploymentKind.ERC1967_PROXY,
                address(0),
                bytes32(0)
            )
        );
        harness.requireTokenDeployment(
            address(token), TokenDeploymentKind.ERC1967_PROXY, address(token).codehash, address(0), bytes32(0)
        );
    }

    function testDeploymentBaselinePredicateMatchesReviewedDirectAndProxyMatrices() public {
        CanonicalDecimalsToken token = new CanonicalDecimalsToken();
        bytes32 codeHash = address(token).codehash;
        address implementation = address(0xCA1C);
        bytes32 implementationCodeHash = bytes32(uint256(0xBEEF));

        assertTrue(
            harness.deploymentBaselineMatches(
                address(token), TokenDeploymentKind.DIRECT, codeHash, address(0), bytes32(0)
            )
        );
        assertTrue(
            harness.deploymentBaselineMatches(
                address(token), TokenDeploymentKind.ERC1967_PROXY, codeHash, implementation, implementationCodeHash
            )
        );
        assertFalse(
            harness.deploymentBaselineMatches(
                address(token), TokenDeploymentKind.NONE, codeHash, address(0), bytes32(0)
            )
        );
        assertFalse(
            harness.deploymentBaselineMatches(
                address(token), TokenDeploymentKind.DIRECT, codeHash, implementation, implementationCodeHash
            )
        );
        assertFalse(
            harness.deploymentBaselineMatches(
                address(token),
                TokenDeploymentKind.ERC1967_PROXY,
                bytes32(uint256(codeHash) ^ 1),
                implementation,
                implementationCodeHash
            )
        );
    }
}
