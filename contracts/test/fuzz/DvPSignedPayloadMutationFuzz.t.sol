// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DvPSettlement} from "src/DvPSettlement.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetClass,
    Decision,
    ParticipantType,
    RequesterSide,
    RoundingMode,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPSignedPayloadMutationFuzzTest is DvPPreCheckTestBase {
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function testFuzzSingleFieldMutationNeverReachesValidatedSettlementStage(uint8 fieldSeed, bytes32 mutationSeed)
        public
    {
        bytes32 mutation = mutationSeed == bytes32(0) ? bytes32(uint256(1)) : mutationSeed;
        uint256 field = bound(fieldSeed, 0, 108);
        _assertMutationRejected(field, mutation);
    }

    function testEverySignedFieldMutationIsRejected() public {
        for (uint256 field; field < 109; ++field) {
            _assertMutationRejected(field, bytes32(field + 1));
        }
    }

    function testFuzzConsistentDynamicBytesMutationInvalidatesSignedHashes(bytes calldata suffix) public view {
        vm.assume(suffix.length != 0 && suffix.length <= 256);
        SettlementParams memory params = _validPreCheckParams();
        params.firmQuote.priceData = bytes.concat(params.firmQuote.priceData, suffix);
        params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, suffix);
        params.snapshot.priceData = bytes.concat(params.snapshot.priceData, suffix);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.QuoteHashMismatch.selector);
    }

    function testFuzzArbitrarySignatureBytesFailClosed(bytes calldata signature, bool mutateMaker) public view {
        vm.assume(signature.length <= 256);
        SettlementParams memory params = _validPreCheckParams();
        bytes memory canonical = mutateMaker ? params.quotingMakerSignature : params.requesterSignature;
        vm.assume(keccak256(signature) != keccak256(canonical));
        if (mutateMaker) {
            params.quotingMakerSignature = signature;
        } else {
            params.requesterSignature = signature;
        }

        _assertSignatureRejected(params);
    }

    function testFuzzWrongDomainAndHighSMalleabilityFailClosed(uint64 domainDelta, bool useHighS) public view {
        SettlementParams memory params = _validPreCheckParams();
        if (useHighS) {
            params.quotingMakerSignature = _toHighS(params.quotingMakerSignature);
        } else {
            uint256 wrongChainId = block.chainid + bound(uint256(domainDelta), 1, type(uint64).max);
            bytes32 wrongDomain = HTPHashing.domainSeparator(bytes("1.2.3"), wrongChainId, address(dvp));
            bytes32 wrongDigest = HTPHashing.hashFirmQuoteDigest(wrongDomain, params.firmQuote);
            params.quotingMakerSignature = _signDigest(MAKER_KEY, wrongDigest);
        }

        _assertSignatureRejected(params);
    }

    function _assertMutationRejected(uint256 field, bytes32 mutation) private {
        SettlementParams memory params = _validPreCheckParams();
        if (field < 29) {
            _mutateFirmQuote(params, field, mutation);
        } else if (field < 66) {
            _mutateTradeIntent(params, field - 29, mutation);
        } else {
            _mutateSnapshot(params, field - 66, mutation);
        }

        vm.prank(EXECUTOR);
        (bool success, bytes memory revertData) = address(dvp).call(abi.encodeCall(DvPSettlement.settle, (params)));
        assertFalse(success);
        assertGe(revertData.length, 4);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
        assertTrue(
            selector == HTPErrors.QuoteHashMismatch.selector || selector == HTPErrors.SnapshotHashMismatch.selector
                || selector == HTPErrors.InvalidSettlementParams.selector
                || selector == HTPErrors.InvalidSignature.selector
                || selector == HTPErrors.InvalidChainOrContract.selector
        );
    }

    function _assertSignatureRejected(SettlementParams memory params) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSignature.selector);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function _signDigest(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _toHighS(bytes memory signature) private pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        return abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    function _mutateFirmQuote(SettlementParams memory params, uint256 field, bytes32 mutation) private pure {
        if (field == 0) {
            params.firmQuote.schemaVersion ^= _uint32Mutation(mutation);
        } else if (field == 1) {
            params.firmQuote.rfqIdHash ^= mutation;
        } else if (field == 2) {
            params.firmQuote.quoteIdHash ^= mutation;
        } else if (field == 3) {
            params.firmQuote.quoteVersion ^= _uint32Mutation(mutation);
        } else if (field == 4) {
            params.firmQuote.quotingMaker = _mutateAddress(params.firmQuote.quotingMaker, mutation);
        } else if (field == 5) {
            params.firmQuote.requester = _mutateAddress(params.firmQuote.requester, mutation);
        } else if (field == 6) {
            params.firmQuote.requesterType = ParticipantType.MAKER;
        } else if (field == 7) {
            params.firmQuote.assetVersionId ^= mutation;
        } else if (field == 8) {
            params.firmQuote.requesterSide = RequesterSide.SELL;
        } else if (field == 9) {
            params.firmQuote.assetToken = _mutateAddress(params.firmQuote.assetToken, mutation);
        } else if (field == 10) {
            params.firmQuote.settlementToken = _mutateAddress(params.firmQuote.settlementToken, mutation);
        } else if (field == 11) {
            params.firmQuote.assetClass = AssetClass.STOCK;
        } else if (field == 12) {
            params.firmQuote.priceTermsHash ^= mutation;
        } else if (field == 13) {
            params.firmQuote.priceData = bytes.concat(params.firmQuote.priceData, mutation);
        } else if (field == 14) {
            params.firmQuote.principalCalculatorConfigId ^= mutation;
        } else if (field == 15) {
            params.firmQuote.principalCalculatorConfigHash ^= mutation;
        } else if (field == 16) {
            params.firmQuote.adapterConfigId ^= mutation;
        } else if (field == 17) {
            params.firmQuote.adapterConfigHash ^= mutation;
        } else if (field == 18) {
            params.firmQuote.settlementTokenConfigId ^= mutation;
        } else if (field == 19) {
            params.firmQuote.settlementTokenConfigHash ^= mutation;
        } else if (field == 20) {
            params.firmQuote.minExecutableQuantity ^= uint256(mutation);
        } else if (field == 21) {
            params.firmQuote.maxExecutableQuantity ^= uint256(mutation);
        } else if (field == 22) {
            params.firmQuote.stepQuantity ^= uint256(mutation);
        } else if (field == 23) {
            params.firmQuote.feePolicyEpoch ^= _uint64Mutation(mutation);
        } else if (field == 24) {
            params.firmQuote.feeVersionId ^= mutation;
        } else if (field == 25) {
            params.firmQuote.matchedScopeHash ^= mutation;
        } else if (field == 26) {
            params.firmQuote.feeConstraintHash ^= mutation;
        } else if (field == 27) {
            params.firmQuote.quoteNonce ^= uint256(mutation);
        } else {
            params.firmQuote.expiresAt ^= _uint64Mutation(mutation);
        }
    }

    function _mutateTradeIntent(SettlementParams memory params, uint256 field, bytes32 mutation) private pure {
        if (field == 0) {
            params.tradeIntent.schemaVersion ^= _uint32Mutation(mutation);
        } else if (field == 1) {
            params.tradeIntent.tradeIdHash ^= mutation;
        } else if (field == 2) {
            params.tradeIntent.quoteHash ^= mutation;
        } else if (field == 3) {
            params.tradeIntent.snapshotHash ^= mutation;
        } else if (field == 4) {
            params.tradeIntent.requester = _mutateAddress(params.tradeIntent.requester, mutation);
        } else if (field == 5) {
            params.tradeIntent.requesterType = ParticipantType.MAKER;
        } else if (field == 6) {
            params.tradeIntent.quotingMaker = _mutateAddress(params.tradeIntent.quotingMaker, mutation);
        } else if (field == 7) {
            params.tradeIntent.assetVersionId ^= mutation;
        } else if (field == 8) {
            params.tradeIntent.requesterSide = RequesterSide.SELL;
        } else if (field == 9) {
            params.tradeIntent.buyer = _mutateAddress(params.tradeIntent.buyer, mutation);
        } else if (field == 10) {
            params.tradeIntent.seller = _mutateAddress(params.tradeIntent.seller, mutation);
        } else if (field == 11) {
            params.tradeIntent.assetToken = _mutateAddress(params.tradeIntent.assetToken, mutation);
        } else if (field == 12) {
            params.tradeIntent.settlementToken = _mutateAddress(params.tradeIntent.settlementToken, mutation);
        } else if (field == 13) {
            params.tradeIntent.executedQuantity ^= uint256(mutation);
        } else if (field == 14) {
            params.tradeIntent.assetClass = AssetClass.STOCK;
        } else if (field == 15) {
            params.tradeIntent.priceTermsHash ^= mutation;
        } else if (field == 16) {
            params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, mutation);
        } else if (field == 17) {
            params.tradeIntent.principalCalculatorConfigId ^= mutation;
        } else if (field == 18) {
            params.tradeIntent.principalCalculatorConfigHash ^= mutation;
        } else if (field == 19) {
            params.tradeIntent.adapterConfigId ^= mutation;
        } else if (field == 20) {
            params.tradeIntent.adapterConfigHash ^= mutation;
        } else if (field == 21) {
            params.tradeIntent.settlementTokenConfigId ^= mutation;
        } else if (field == 22) {
            params.tradeIntent.settlementTokenConfigHash ^= mutation;
        } else if (field == 23) {
            params.tradeIntent.cashPrincipal ^= uint256(mutation);
        } else if (field == 24) {
            params.tradeIntent.buyerFee ^= uint256(mutation);
        } else if (field == 25) {
            params.tradeIntent.sellerFee ^= uint256(mutation);
        } else if (field == 26) {
            params.tradeIntent.buyerDebit ^= uint256(mutation);
        } else if (field == 27) {
            params.tradeIntent.sellerCredit ^= uint256(mutation);
        } else if (field == 28) {
            params.tradeIntent.collectorCredit ^= uint256(mutation);
        } else if (field == 29) {
            params.tradeIntent.collector = _mutateAddress(params.tradeIntent.collector, mutation);
        } else if (field == 30) {
            params.tradeIntent.feePolicyEpoch ^= _uint64Mutation(mutation);
        } else if (field == 31) {
            params.tradeIntent.feeVersionId ^= mutation;
        } else if (field == 32) {
            params.tradeIntent.matchedScopeHash ^= mutation;
        } else if (field == 33) {
            params.tradeIntent.feeConstraintHash ^= mutation;
        } else if (field == 34) {
            params.tradeIntent.roundingMode = RoundingMode.NONE;
        } else if (field == 35) {
            params.tradeIntent.tradeNonce ^= uint256(mutation);
        } else {
            params.tradeIntent.deadline ^= _uint64Mutation(mutation);
        }
    }

    function _mutateSnapshot(SettlementParams memory params, uint256 field, bytes32 mutation) private pure {
        if (field == 0) {
            params.snapshot.schemaVersion ^= _uint32Mutation(mutation);
        } else if (field == 1) {
            params.snapshot.tradeIdHash ^= mutation;
        } else if (field == 2) {
            params.snapshot.quoteHash ^= mutation;
        } else if (field == 3) {
            params.snapshot.chainId ^= uint256(mutation);
        } else if (field == 4) {
            params.snapshot.dvpContract = _mutateAddress(params.snapshot.dvpContract, mutation);
        } else if (field == 5) {
            params.snapshot.requester = _mutateAddress(params.snapshot.requester, mutation);
        } else if (field == 6) {
            params.snapshot.requesterType = ParticipantType.MAKER;
        } else if (field == 7) {
            params.snapshot.quotingMaker = _mutateAddress(params.snapshot.quotingMaker, mutation);
        } else if (field == 8) {
            params.snapshot.requesterSide = RequesterSide.SELL;
        } else if (field == 9) {
            params.snapshot.buyer = _mutateAddress(params.snapshot.buyer, mutation);
        } else if (field == 10) {
            params.snapshot.seller = _mutateAddress(params.snapshot.seller, mutation);
        } else if (field == 11) {
            params.snapshot.assetVersionId ^= mutation;
        } else if (field == 12) {
            params.snapshot.assetToken = _mutateAddress(params.snapshot.assetToken, mutation);
        } else if (field == 13) {
            params.snapshot.settlementToken = _mutateAddress(params.snapshot.settlementToken, mutation);
        } else if (field == 14) {
            params.snapshot.assetDecimals ^= _uint8Mutation(mutation);
        } else if (field == 15) {
            params.snapshot.settlementTokenDecimals ^= _uint8Mutation(mutation);
        } else if (field == 16) {
            params.snapshot.executedQuantity ^= uint256(mutation);
        } else if (field == 17) {
            params.snapshot.assetClass = AssetClass.STOCK;
        } else if (field == 18) {
            params.snapshot.priceTermsHash ^= mutation;
        } else if (field == 19) {
            params.snapshot.priceData = bytes.concat(params.snapshot.priceData, mutation);
        } else if (field == 20) {
            params.snapshot.principalCalculatorConfigId ^= mutation;
        } else if (field == 21) {
            params.snapshot.principalCalculatorConfigHash ^= mutation;
        } else if (field == 22) {
            params.snapshot.adapterConfigId ^= mutation;
        } else if (field == 23) {
            params.snapshot.adapterConfigHash ^= mutation;
        } else if (field == 24) {
            params.snapshot.settlementTokenConfigId ^= mutation;
        } else if (field == 25) {
            params.snapshot.settlementTokenConfigHash ^= mutation;
        } else if (field == 26) {
            params.snapshot.cashPrincipal ^= uint256(mutation);
        } else if (field == 27) {
            params.snapshot.buyerFee ^= uint256(mutation);
        } else if (field == 28) {
            params.snapshot.sellerFee ^= uint256(mutation);
        } else if (field == 29) {
            params.snapshot.buyerDebit ^= uint256(mutation);
        } else if (field == 30) {
            params.snapshot.sellerCredit ^= uint256(mutation);
        } else if (field == 31) {
            params.snapshot.collectorCredit ^= uint256(mutation);
        } else if (field == 32) {
            params.snapshot.collector = _mutateAddress(params.snapshot.collector, mutation);
        } else if (field == 33) {
            params.snapshot.feePolicyEpoch ^= _uint64Mutation(mutation);
        } else if (field == 34) {
            params.snapshot.feeVersionId ^= mutation;
        } else if (field == 35) {
            params.snapshot.matchedScopeHash ^= mutation;
        } else if (field == 36) {
            params.snapshot.feeConstraintHash ^= mutation;
        } else if (field == 37) {
            params.snapshot.roundingMode = RoundingMode.NONE;
        } else if (field == 38) {
            params.snapshot.makerQuoteNonce ^= uint256(mutation);
        } else if (field == 39) {
            params.snapshot.requesterTradeNonce ^= uint256(mutation);
        } else if (field == 40) {
            params.snapshot.quoteExpiresAt ^= _uint64Mutation(mutation);
        } else if (field == 41) {
            params.snapshot.tradeDeadline ^= _uint64Mutation(mutation);
        } else {
            params.snapshot.createdAt ^= _uint64Mutation(mutation);
        }
    }

    function _mutateAddress(address value, bytes32 mutation) private pure returns (address) {
        return address(uint160(value) ^ (uint160(uint256(mutation)) | uint160(1)));
    }

    function _uint8Mutation(bytes32 mutation) private pure returns (uint8) {
        return uint8(uint256(mutation)) | uint8(1);
    }

    function _uint32Mutation(bytes32 mutation) private pure returns (uint32) {
        return uint32(uint256(mutation)) | uint32(1);
    }

    function _uint64Mutation(bytes32 mutation) private pure returns (uint64) {
        return uint64(uint256(mutation)) | uint64(1);
    }
}
