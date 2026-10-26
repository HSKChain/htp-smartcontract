// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

/// @notice SlowMist N10: maker authorization binds the canonical trade ID.
contract SlowMistN10MakerTradeIdBindingTest is DvPPreCheckTestBase {
    function test_N10_RequesterCannotReplaceMakerBoundTradeIdHash() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 quoteDigest = params.tradeIntent.quoteHash;
        bytes32 replacementTradeIdHash = keccak256("N10 requester replacement");

        // N10 exploit attempt: keep the maker quote/signature, replace both requester-controlled copies.
        params.tradeIntent.tradeIdHash = replacementTradeIdHash;
        params.snapshot.tradeIdHash = replacementTradeIdHash;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.requesterSignature =
            _signRequester(HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));

        assertEq(HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote), quoteDigest);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSettlementParams.selector);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("tradeIdHash")));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(quoteDigest));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(replacementTradeIdHash));
    }

    function test_N10_ReplacingEveryTradeIdCopyInvalidatesMakerSignature() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 originalMakerSignatureHash = keccak256(params.quotingMakerSignature);
        bytes32 replacementTradeIdHash = keccak256("N10 coherent requester replacement");

        params.firmQuote.tradeIdHash = replacementTradeIdHash;
        params.tradeIntent.tradeIdHash = replacementTradeIdHash;
        params.snapshot.tradeIdHash = replacementTradeIdHash;
        bytes32 replacementQuoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = replacementQuoteDigest;
        params.snapshot.quoteHash = replacementQuoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.requesterSignature =
            _signRequester(HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));

        // N10: The requester can rebuild its own payload but cannot refresh the maker signature.
        assertEq(keccak256(params.quotingMakerSignature), originalMakerSignatureHash);
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSignature.selector);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, params.firmQuote.quotingMaker));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function test_N10_MakerBoundTradeIdHashStillSettles() public {
        SettlementParams memory params = _validPreCheckParams();
        assertEq(params.firmQuote.tradeIdHash, params.tradeIntent.tradeIdHash);
        assertEq(params.tradeIntent.tradeIdHash, params.snapshot.tradeIdHash);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));

        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertTrue(dvp.usedTradeIdHash(params.firmQuote.tradeIdHash));
    }

    function _signRequester(bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(REQUESTER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
