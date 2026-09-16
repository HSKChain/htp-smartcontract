// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeploymentVersion} from "src/libraries/DeploymentVersion.sol";

contract DeploymentVersionHarness {
    function isCanonical(string calldata deploymentVersion) external pure returns (bool) {
        return DeploymentVersion.isCanonical(bytes(deploymentVersion));
    }

    function domainVersion(string calldata deploymentVersion) external pure returns (string memory) {
        return DeploymentVersion.domainVersion(bytes(deploymentVersion));
    }

    function hash(string calldata deploymentVersion) external pure returns (bytes32) {
        return DeploymentVersion.hash(bytes(deploymentVersion));
    }
}

contract DeploymentVersionTest is Test {
    DeploymentVersionHarness private immutable HARNESS = new DeploymentVersionHarness();

    function testAcceptsCanonicalSemVerAndReturnsOnlyMajor() public view {
        assertTrue(HARNESS.isCanonical("0.0.0"));
        assertTrue(HARNESS.isCanonical("12.34.56"));
        assertEq(HARNESS.domainVersion("12.34.56"), "12");
    }

    function testRejectsNonCanonicalDeploymentVersions() public view {
        assertFalse(HARNESS.isCanonical("v1.2.3"));
        assertFalse(HARNESS.isCanonical("01.2.3"));
        assertFalse(HARNESS.isCanonical("1.02.3"));
        assertFalse(HARNESS.isCanonical("1.2.03"));
        assertFalse(HARNESS.isCanonical("1.2"));
        assertFalse(HARNESS.isCanonical("1.2.3.4"));
        assertFalse(HARNESS.isCanonical("1.2.3-rc.1"));
        assertFalse(HARNESS.isCanonical("1.2.3+build"));
        assertFalse(HARNESS.isCanonical("1.a.3"));
    }

    function testInvalidVersionUsesStructuredError() public {
        vm.expectRevert(bytes4(0xa9a3e469));
        HARNESS.domainVersion("v1.2.3");
    }

    function testDeploymentVersionHashMatchesReviewedLiteral() public view {
        assertEq(HARNESS.hash("1.2.3"), 0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42);
    }
}
