// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";

contract Eip712DomainHarness {
    function domainSeparator(bytes calldata deploymentVersion, uint256 chainId, address verifyingContract)
        external
        pure
        returns (bytes32)
    {
        return HTPHashing.domainSeparator(deploymentVersion, chainId, verifyingContract);
    }
}

contract Eip712DomainTest is Test {
    Eip712DomainHarness private immutable HARNESS = new Eip712DomainHarness();

    function testDomainSeparatorMatchesReviewedBootstrapLiteral() public view {
        assertEq(
            HARNESS.domainSeparator(bytes("1.2.3"), 31_337, address(0xd001)),
            0xc0f20d1f3e9bd185d5fe9e24b1822d7657e7c83dd337727af1fad04d7c26cac3
        );
    }

    function testDomainBindsMajorChainAndVerifyingContract() public view {
        bytes32 expected = 0xc0f20d1f3e9bd185d5fe9e24b1822d7657e7c83dd337727af1fad04d7c26cac3;
        assertNotEq(expected, HARNESS.domainSeparator(bytes("2.2.3"), 31_337, address(0xd001)));
        assertNotEq(expected, HARNESS.domainSeparator(bytes("1.2.3"), 31_338, address(0xd001)));
        assertNotEq(expected, HARNESS.domainSeparator(bytes("1.2.3"), 31_337, address(0xd002)));
    }
}
