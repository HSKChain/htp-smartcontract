// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {FirmQuote} from "src/types/HTPTypes.sol";

contract FirmQuoteHashHarness {
    function typeHash() external pure returns (bytes32) {
        return HTPHashing.FIRM_QUOTE_TYPEHASH;
    }

    function domainSeparator(bytes calldata deploymentVersion, uint256 chainId, address verifyingContract)
        external
        pure
        returns (bytes32)
    {
        return HTPHashing.domainSeparator(deploymentVersion, chainId, verifyingContract);
    }

    function hash(FirmQuote calldata quote) external pure returns (bytes32) {
        return HTPHashing.hashFirmQuote(quote);
    }

    function digest(bytes32 separator, FirmQuote calldata quote) external pure returns (bytes32) {
        return HTPHashing.hashFirmQuoteDigest(separator, quote);
    }
}

contract FirmQuoteHashTest is Test {
    bytes32 private constant DOMAIN_SEPARATOR = 0xc0f20d1f3e9bd185d5fe9e24b1822d7657e7c83dd337727af1fad04d7c26cac3;
    FirmQuoteHashHarness private immutable HARNESS = new FirmQuoteHashHarness();

    function testTypeHashStructHashAndQuoteDigestMatchBootstrapLiterals() public view {
        FirmQuote memory quote = SchemaFixtures.firmQuote();
        assertEq(HARNESS.typeHash(), 0x79db216dea763a9d67ad7df5570a388d4055c6ac896752086982d5db82bb597b);
        assertEq(HARNESS.hash(quote), 0xa653341502027d21f3a0b7fbb97d8244eee201852dfc31025e0d1dcf2975a787);
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, quote), 0xca1cdab2f6412c367f4fb06ca8f52a5b73092e4ddc20a798d4e9e3f0ede0d1f9
        );
    }

    function testDynamicPriceDataUsesItsBytesHash() public view {
        FirmQuote memory quote = SchemaFixtures.firmQuote();
        quote.priceData = bytes.concat(quote.priceData, hex"00");
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, quote), 0x75e4303ae7c80d99ba938dc05eceaecfeb56997d1063001f129c053b24204b44
        );
    }

    function testValidDomainMutationsChangeFullDigest() public view {
        FirmQuote memory quote = SchemaFixtures.firmQuote();
        bytes32 baseline = HARNESS.digest(DOMAIN_SEPARATOR, quote);
        assertNotEq(HARNESS.digest(HARNESS.domainSeparator(bytes("2.2.3"), 31_337, address(0xd001)), quote), baseline);
        assertNotEq(HARNESS.digest(HARNESS.domainSeparator(bytes("1.2.3"), 31_338, address(0xd001)), quote), baseline);
        assertNotEq(HARNESS.digest(HARNESS.domainSeparator(bytes("1.2.3"), 31_337, address(0xd002)), quote), baseline);
    }
}
