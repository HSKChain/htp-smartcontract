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
        // N10: Bootstrap literals include the maker-bound tradeIdHash field.
        assertEq(HARNESS.typeHash(), 0xf576cd55e29ca3b3f9054376d57902bbfd1c065cadbaadc855180836f3f06ee5);
        assertEq(HARNESS.hash(quote), 0x11c0b44a90d83e9368086d1a8b9ce5a8828ece1404f4c7d7dafef127b0eed170);
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, quote), 0xc2b38ad8616829b7dd6eb761130f83f955c460c5b93608bbea086c1aa7a17104
        );
    }

    function testDynamicPriceDataUsesItsBytesHash() public view {
        FirmQuote memory quote = SchemaFixtures.firmQuote();
        quote.priceData = bytes.concat(quote.priceData, hex"00");
        assertEq(
            HARNESS.digest(DOMAIN_SEPARATOR, quote), 0xb1a36694689dd3e0a35e60a3086bffe8208aff6d1820c58cb9192f801c8a14cf
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
