// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {TradeTermsSnapshot} from "src/types/HTPTypes.sol";

contract TradeTermsSnapshotHashHarness {
    function typeHash() external pure returns (bytes32) {
        return HTPHashing.TRADE_TERMS_SNAPSHOT_TYPEHASH;
    }

    function hash(TradeTermsSnapshot calldata snapshot) external pure returns (bytes32) {
        return HTPHashing.hashTradeTermsSnapshot(snapshot);
    }
}

contract TradeTermsSnapshotHashTest is Test {
    TradeTermsSnapshotHashHarness private immutable HARNESS = new TradeTermsSnapshotHashHarness();

    function testTypeHashAndSnapshotHashMatchBootstrapLiterals() public view {
        TradeTermsSnapshot memory snapshot = SchemaFixtures.snapshot();
        assertEq(HARNESS.typeHash(), 0xccbdc80b52327f570e3875de104245bc6d4532cdfb655431ec7f858d8bf2f920);
        assertEq(HARNESS.hash(snapshot), 0x3054e216b8a539459e5a24e6e2b037321c19817fe68ef060289332328b5050ad);
        assertNotEq(HARNESS.hash(snapshot), 0x21bdc075b114449465e5e28aafc2b111d6b0979cb661bfb95c4e4dd2760dbb95);
    }

    function testSnapshotHashesDynamicPriceDataWithoutDomainDigest() public view {
        TradeTermsSnapshot memory snapshot = SchemaFixtures.snapshot();
        snapshot.priceData = bytes.concat(snapshot.priceData, hex"00");
        bytes32 snapshotHash = HARNESS.hash(snapshot);
        assertEq(snapshotHash, 0xfbcb2b918d8c0bfa287719a214627d7a01026f2b308870cfa226751688eb2970);
    }
}
