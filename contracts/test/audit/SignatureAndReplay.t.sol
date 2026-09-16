// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT (Module B - signatures, hashing, replay). Safe to delete.

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FirmQuote,
    NonceCancellation,
    NonceStatus,
    NonceType,
    SettlementParams,
    TradeIntent,
    TradeTermsSnapshot
} from "src/types/HTPTypes.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

// ---------------------------------------------------------------------------
// Part 1: independent re-encoding of every signable EIP-712 object.
// The type strings below were transcribed by hand from the struct declarations
// in HTPTypes.sol, NOT copied from HTPHashing.sol, so any field/order/type
// drift between the two files surfaces as a hash mismatch.
// ---------------------------------------------------------------------------
library AuditReferenceHashing {
    string internal constant FIRM_QUOTE_TYPE = "FirmQuote("
        "uint32 schemaVersion,bytes32 rfqIdHash,bytes32 quoteIdHash,uint32 quoteVersion,"
        "address quotingMaker,address requester,uint8 requesterType,bytes32 assetVersionId,"
        "uint8 requesterSide,address assetToken,address settlementToken,uint8 assetClass,"
        "bytes32 priceTermsHash,bytes priceData,bytes32 principalCalculatorConfigId,"
        "bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,"
        "bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,"
        "bytes32 marketRuleConfigHash,uint256 minExecutableQuantity,uint256 maxExecutableQuantity,"
        "uint256 stepQuantity,uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,"
        "bytes32 feeConstraintHash,uint256 quoteNonce,uint64 expiresAt)";

    string internal constant TRADE_INTENT_TYPE = "TradeIntent("
        "uint32 schemaVersion,bytes32 tradeIdHash,bytes32 quoteHash,bytes32 snapshotHash,"
        "address requester,uint8 requesterType,address quotingMaker,bytes32 assetVersionId,"
        "uint8 requesterSide,address buyer,address seller,address assetToken,address settlementToken,"
        "uint256 executedQuantity,uint8 assetClass,bytes32 priceTermsHash,bytes priceData,"
        "bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,"
        "bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,"
        "bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,uint256 cashPrincipal,uint256 buyerFee,"
        "uint256 sellerFee,uint256 buyerDebit,uint256 sellerCredit,uint256 collectorCredit,address collector,"
        "uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,bytes32 feeConstraintHash,"
        "uint8 roundingMode,uint256 tradeNonce,uint64 deadline)";

    string internal constant SNAPSHOT_TYPE = "TradeTermsSnapshot("
        "uint32 schemaVersion,bytes32 tradeIdHash,bytes32 quoteHash,uint256 chainId,address dvpContract,"
        "address requester,uint8 requesterType,address quotingMaker,uint8 requesterSide,address buyer,"
        "address seller,bytes32 assetVersionId,address assetToken,address settlementToken,uint8 assetDecimals,"
        "uint8 settlementTokenDecimals,uint256 executedQuantity,uint8 assetClass,bytes32 priceTermsHash,"
        "bytes priceData,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,"
        "bytes32 adapterConfigId,bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,"
        "bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,"
        "uint256 cashPrincipal,uint256 buyerFee,uint256 sellerFee,uint256 buyerDebit,uint256 sellerCredit,"
        "uint256 collectorCredit,address collector,uint64 feePolicyEpoch,bytes32 feeVersionId,"
        "bytes32 matchedScopeHash,bytes32 feeConstraintHash,uint8 roundingMode,uint256 makerQuoteNonce,"
        "uint256 requesterTradeNonce,uint64 quoteExpiresAt,uint64 tradeDeadline,uint64 createdAt)";

    string internal constant NONCE_CANCELLATION_TYPE =
        "NonceCancellation(address signer,uint8 nonceType,uint256 nonce,uint64 deadline)";

    function firmQuote(FirmQuote memory q) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            keccak256(bytes(FIRM_QUOTE_TYPE)),
            q.schemaVersion,
            q.rfqIdHash,
            q.quoteIdHash,
            q.quoteVersion,
            q.quotingMaker,
            q.requester,
            q.requesterType
        );
        bytes memory mid = abi.encode(
            q.assetVersionId,
            q.requesterSide,
            q.assetToken,
            q.settlementToken,
            q.assetClass,
            q.priceTermsHash,
            keccak256(q.priceData),
            q.principalCalculatorConfigId
        );
        bytes memory mid2 = abi.encode(
            q.principalCalculatorConfigHash,
            q.adapterConfigId,
            q.adapterConfigHash,
            q.settlementTokenConfigId,
            q.settlementTokenConfigHash,
            q.marketRuleConfigId,
            q.marketRuleConfigHash,
            q.minExecutableQuantity
        );
        bytes memory tail = abi.encode(
            q.maxExecutableQuantity,
            q.stepQuantity,
            q.feePolicyEpoch,
            q.feeVersionId,
            q.matchedScopeHash,
            q.feeConstraintHash,
            q.quoteNonce,
            q.expiresAt
        );
        return keccak256(bytes.concat(head, mid, mid2, tail));
    }

    function tradeIntent(TradeIntent memory i) internal pure returns (bytes32) {
        bytes memory a = abi.encode(
            keccak256(bytes(TRADE_INTENT_TYPE)),
            i.schemaVersion,
            i.tradeIdHash,
            i.quoteHash,
            i.snapshotHash,
            i.requester,
            i.requesterType,
            i.quotingMaker
        );
        bytes memory b = abi.encode(
            i.assetVersionId,
            i.requesterSide,
            i.buyer,
            i.seller,
            i.assetToken,
            i.settlementToken,
            i.executedQuantity,
            i.assetClass
        );
        bytes memory c = abi.encode(
            i.priceTermsHash,
            keccak256(i.priceData),
            i.principalCalculatorConfigId,
            i.principalCalculatorConfigHash,
            i.adapterConfigId,
            i.adapterConfigHash,
            i.settlementTokenConfigId,
            i.settlementTokenConfigHash
        );
        bytes memory d = abi.encode(
            i.marketRuleConfigId,
            i.marketRuleConfigHash,
            i.cashPrincipal,
            i.buyerFee,
            i.sellerFee,
            i.buyerDebit,
            i.sellerCredit,
            i.collectorCredit
        );
        bytes memory e = abi.encode(
            i.collector,
            i.feePolicyEpoch,
            i.feeVersionId,
            i.matchedScopeHash,
            i.feeConstraintHash,
            i.roundingMode,
            i.tradeNonce,
            i.deadline
        );
        return keccak256(bytes.concat(a, b, c, d, e));
    }

    function snapshot(TradeTermsSnapshot memory s) internal pure returns (bytes32) {
        bytes memory a = abi.encode(
            keccak256(bytes(SNAPSHOT_TYPE)),
            s.schemaVersion,
            s.tradeIdHash,
            s.quoteHash,
            s.chainId,
            s.dvpContract,
            s.requester,
            s.requesterType
        );
        bytes memory b = abi.encode(
            s.quotingMaker,
            s.requesterSide,
            s.buyer,
            s.seller,
            s.assetVersionId,
            s.assetToken,
            s.settlementToken,
            s.assetDecimals
        );
        bytes memory c = abi.encode(
            s.settlementTokenDecimals,
            s.executedQuantity,
            s.assetClass,
            s.priceTermsHash,
            keccak256(s.priceData),
            s.principalCalculatorConfigId,
            s.principalCalculatorConfigHash,
            s.adapterConfigId
        );
        bytes memory d = abi.encode(
            s.adapterConfigHash,
            s.settlementTokenConfigId,
            s.settlementTokenConfigHash,
            s.marketRuleConfigId,
            s.marketRuleConfigHash,
            s.cashPrincipal,
            s.buyerFee,
            s.sellerFee
        );
        bytes memory e = abi.encode(
            s.buyerDebit,
            s.sellerCredit,
            s.collectorCredit,
            s.collector,
            s.feePolicyEpoch,
            s.feeVersionId,
            s.matchedScopeHash,
            s.feeConstraintHash
        );
        bytes memory f = abi.encode(
            s.roundingMode, s.makerQuoteNonce, s.requesterTradeNonce, s.quoteExpiresAt, s.tradeDeadline, s.createdAt
        );
        return keccak256(bytes.concat(a, b, c, d, e, f));
    }

    function nonceCancellation(NonceCancellation memory c) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(keccak256(bytes(NONCE_CANCELLATION_TYPE)), c.signer, c.nonceType, c.nonce, c.deadline));
    }
}

contract AuditHashHarness {
    function firmQuote(FirmQuote calldata q) external pure returns (bytes32 libValue, bytes32 refValue) {
        FirmQuote memory copy = q;
        return (HTPHashing.hashFirmQuote(copy), AuditReferenceHashing.firmQuote(copy));
    }

    function tradeIntent(TradeIntent calldata i) external pure returns (bytes32 libValue, bytes32 refValue) {
        TradeIntent memory copy = i;
        return (HTPHashing.hashTradeIntent(copy), AuditReferenceHashing.tradeIntent(copy));
    }

    function snapshot(TradeTermsSnapshot calldata s) external pure returns (bytes32 libValue, bytes32 refValue) {
        TradeTermsSnapshot memory copy = s;
        return (HTPHashing.hashTradeTermsSnapshot(copy), AuditReferenceHashing.snapshot(copy));
    }

    function nonceCancellation(NonceCancellation calldata c)
        external
        pure
        returns (bytes32 libValue, bytes32 refValue)
    {
        NonceCancellation memory copy = c;
        return (HTPHashing.hashNonceCancellation(copy), AuditReferenceHashing.nonceCancellation(copy));
    }

    function typeHashes() external pure returns (bytes32[4] memory) {
        return [
            HTPHashing.FIRM_QUOTE_TYPEHASH,
            HTPHashing.TRADE_INTENT_TYPEHASH,
            HTPHashing.TRADE_TERMS_SNAPSHOT_TYPEHASH,
            HTPHashing.NONCE_CANCELLATION_TYPEHASH
        ];
    }
}

contract TmpAuditTypehashTest is Test {
    AuditHashHarness private immutable HARNESS = new AuditHashHarness();

    function testAllSignableTypehashStringsMatchStructDeclarations() public view {
        bytes32[4] memory actual = HARNESS.typeHashes();
        assertEq(actual[0], keccak256(bytes(AuditReferenceHashing.FIRM_QUOTE_TYPE)), "FirmQuote typehash");
        assertEq(actual[1], keccak256(bytes(AuditReferenceHashing.TRADE_INTENT_TYPE)), "TradeIntent typehash");
        assertEq(actual[2], keccak256(bytes(AuditReferenceHashing.SNAPSHOT_TYPE)), "Snapshot typehash");
        assertEq(
            actual[3], keccak256(bytes(AuditReferenceHashing.NONCE_CANCELLATION_TYPE)), "NonceCancellation typehash"
        );
    }

    function testStructHashesMatchIndependentAbiEncodeReference() public view {
        (bytes32 libQuote, bytes32 refQuote) = HARNESS.firmQuote(SchemaFixtures.firmQuote());
        assertEq(libQuote, refQuote, "FirmQuote struct hash");
        (bytes32 libIntent, bytes32 refIntent) = HARNESS.tradeIntent(SchemaFixtures.tradeIntent());
        assertEq(libIntent, refIntent, "TradeIntent struct hash");
        (bytes32 libSnap, bytes32 refSnap) = HARNESS.snapshot(SchemaFixtures.snapshot());
        assertEq(libSnap, refSnap, "Snapshot struct hash");
        (bytes32 libCancel, bytes32 refCancel) = HARNESS.nonceCancellation(
            NonceCancellation({signer: address(0xBEEF), nonceType: NonceType.MAKER_QUOTE, nonce: 7, deadline: 99})
        );
        assertEq(libCancel, refCancel, "NonceCancellation struct hash");
    }

    function testDomainSeparatorMatchesEip712Reference() public pure {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HTP DvP Settlement"),
                keccak256("1"),
                uint256(31_337),
                address(0xd001)
            )
        );
        assertEq(HTPHashing.domainSeparator(bytes("1.2.3"), 31_337, address(0xd001)), expected);
    }
}

// ---------------------------------------------------------------------------
// Part 2: behavioural PoCs against a fully wired DvP.
// ---------------------------------------------------------------------------

// Consumes every unit of gas it is handed, then answers "valid".
contract GasBurning1271Wallet is IERC1271 {
    uint256 public sink;

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        uint256 acc = sink;
        while (gasleft() > 30_000) {
            acc = uint256(keccak256(abi.encode(acc)));
        }
        if (acc == type(uint256).max) return bytes4(0);
        return IERC1271.isValidSignature.selector;
    }
}

contract Honest1271Wallet is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }
}

contract TmpAuditModuleBTest is DvPPreCheckTestBase {
    function testSettlePathIsHealthyBaseline() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.USED)
        );
    }

    // B-01: the maker can renege on a firm quote at any moment before settle
    // lands, by front-running the Executor with a permissionless cancelNonce.
    function testMakerCanFrontRunSettleAndKillAFirmQuote() public {
        SettlementParams memory params = _validPreCheckParams();
        address maker = params.firmQuote.quotingMaker;
        assertEq(
            uint8(dvp.getNonceStatus(maker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)),
            uint8(NonceStatus.UNUSED)
        );

        vm.prank(maker);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                maker,
                NonceType.MAKER_QUOTE,
                params.firmQuote.quoteNonce,
                NonceStatus.CANCELLED
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.UNUSED)
        );
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testRequesterCanFrontRunSettleToo() public {
        SettlementParams memory params = _validPreCheckParams();
        address requester = params.tradeIntent.requester;
        vm.prank(requester);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                requester,
                NonceType.REQUESTER_TRADE,
                params.tradeIntent.tradeNonce,
                NonceStatus.CANCELLED
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    // B-02: the EIP-1271 branch forwards gasleft(), so the counterparty wallet
    // decides how much gas the Executor's transaction burns.
    // 修复后：EIP-1271 验签受 ERC1271_CALL_GAS 约束，钱包烧不动 Executor 的整笔 gas。
    // 修复前同一场景消耗 19,464,637，诚实钱包只要 188,691，放大 103 倍且不留链上证据。
    function testEip1271WalletCannotBurnUnboundedExecutorGas() public {
        GasBurning1271Wallet wallet = new GasBurning1271Wallet();
        SettlementParams memory params = _makerIsContractWallet(address(wallet));

        uint256 before = gasleft();
        vm.prank(EXECUTOR);
        (bool ok,) = address(dvp).call{gas: 20_000_000}(abi.encodeCall(DvPSettlement.settle, (params)));
        uint256 spent = before - gasleft();
        assertFalse(ok, "malformed 1271 response is still fail-closed");
        emit log_named_uint("gas consumed by one failed settle (malicious wallet)", spent);
        // 上界取诚实路径的若干倍：预算 2 × 200k 加上流水线本身的开销，
        // 与修复前的 19.46M 相比杠杆已被消除。
        assertLt(spent, 1_000_000, "gas burn is now bounded by the 1271 budget");
    }

    function testHonestWalletKeepsSettleGasNormal() public {
        Honest1271Wallet wallet = new Honest1271Wallet();
        SettlementParams memory params = _makerIsContractWallet(address(wallet));
        uint256 before = gasleft();
        vm.prank(EXECUTOR);
        (bool ok,) = address(dvp).call{gas: 20_000_000}(abi.encodeCall(DvPSettlement.settle, (params)));
        ok;
        uint256 spent = before - gasleft();
        emit log_named_uint("gas consumed with honest wallet", spent);
        assertLt(spent, 1_000_000);
    }

    // B-03: an EOA that acquires code (EIP-7702 delegation) silently
    // invalidates every outstanding ECDSA signature it already produced.
    function testEoaThatGainsCodeInvalidatesItsOwnOutstandingSignatures() public {
        SettlementParams memory params = _validPreCheckParams();
        address maker = params.firmQuote.quotingMaker;
        // 0xef0100 || delegate address: the designator EIP-7702 installs.
        vm.etch(maker, hex"ef01000000000000000000000000000000000000001234");
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, maker));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    // Cross-check on the domainSeparatorV4 recompute branch.
    function testCancelNonceBySigStaysLiveOnAForkedChainWhileSettleIsDead() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.chainId(block.chainid + 1);

        vm.expectRevert();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        address signer = vm.addr(MAKER_KEY);
        NonceCancellation memory cancellation = NonceCancellation({
            signer: signer, nonceType: NonceType.MAKER_QUOTE, nonce: 4242, deadline: uint64(block.timestamp + 1 hours)
        });
        bytes32 digest = HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), cancellation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_KEY, digest);
        dvp.cancelNonceBySig(cancellation, abi.encodePacked(r, s, v));
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.MAKER_QUOTE, 4242)), uint8(NonceStatus.CANCELLED));

        // A cancellation signed for the forked chain is not valid back home.
        vm.chainId(31_337);
        assertNotEq(HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), cancellation), digest);
    }

    // Replay locks cannot be burned without a fully successful settlement.
    function testRevertedSettleLeavesEveryReplayLockUntouched() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setBalance(params.snapshot.seller, 0);
        vm.prank(EXECUTOR);
        (bool ok,) = address(dvp).call(abi.encodeCall(DvPSettlement.settle, (params)));
        assertFalse(ok);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    // tradeIdHash is a free off-chain value: burning it blocks any future trade
    // that reuses it, and nothing on-chain constrains how it is generated.
    function testTradeIdHashIsAFreeOffChainValueAndBurningItBlocksReuse() public {
        SettlementParams memory first = _validPreCheckParams();
        bytes32 chosenTradeId = keccak256("attacker chosen trade id");
        first.tradeIntent.tradeIdHash = chosenTradeId;
        first.snapshot.tradeIdHash = chosenTradeId;
        _resign(first);
        vm.prank(EXECUTOR);
        dvp.settle(first);
        assertTrue(dvp.usedTradeIdHash(chosenTradeId));

        // A later, economically unrelated trade that happens to carry the same
        // off-chain trade id is permanently unsettleable.
        SettlementParams memory second = _validPreCheckParams();
        second.tradeIntent.tradeIdHash = chosenTradeId;
        second.snapshot.tradeIdHash = chosenTradeId;
        second.firmQuote.quoteNonce = first.firmQuote.quoteNonce + 1;
        second.snapshot.makerQuoteNonce = second.firmQuote.quoteNonce;
        second.tradeIntent.tradeNonce = first.tradeIntent.tradeNonce + 1;
        second.snapshot.requesterTradeNonce = second.tradeIntent.tradeNonce;
        _resign(second);
        assetToken.setAllowance(second.snapshot.seller, address(dvp), 10 ether);
        settlementToken.setAllowance(second.snapshot.buyer, address(dvp), 11_428_500);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.TradeAlreadyExecuted.selector, chosenTradeId));
        vm.prank(EXECUTOR);
        dvp.settle(second);
    }

    function _makerIsContractWallet(address wallet) private view returns (SettlementParams memory params) {
        params = _validPreCheckParams();
        params.firmQuote.quotingMaker = wallet;
        params.tradeIntent.quotingMaker = wallet;
        params.snapshot.quotingMaker = wallet;
        params.tradeIntent.seller = wallet;
        params.snapshot.seller = wallet;
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.quotingMakerSignature = hex"cafe";
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
        params.requesterSignature = abi.encodePacked(r, s, v);
    }
}
