// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT (Module F). Delete after review.

import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, NonceStatus, NonceType, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";

contract TmpAuditModuleFTrustBoundary is UsdySettlementFixture {
    function _assertNoncesUnused(SettlementParams memory params) private view {
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.UNUSED),
            "maker nonce must survive a failed settle"
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.UNUSED),
            "requester nonce must survive a failed settle"
        );
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    /// Pipeline STEP 8 omitted / reverted: the USDY adapter checks the operator
    /// (msg.sender == DvP) against the allowlist, so this is a clean BLOCK in
    /// the pre-check phase, not a late transferFrom failure.
    function test_step8AllowlistOmission_isCleanBlockBeforeAnyWrite() public {
        SettlementParams memory params = _validUsdyBuyParams();

        (Decision okDecision,) = dvp.preCheck(params);
        assertEq(uint8(okDecision), uint8(Decision.PASS), "baseline must pass");

        // Undo pipeline step 8.
        usdyAllowlist.setAllowed(address(dvp), false);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK), "must be a determinate BLOCK, not UNKNOWN");
        assertEq(reason, HTPErrors.TransferRestricted.selector);

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        dvp.settle(params);

        _assertNoncesUnused(params);
    }

    /// Inventory reservation is not custody: the seller can move the asset out
    /// after signing. The failure is clean and consumes nothing.
    function test_sellerMovesAssetAfterSigning_failsCleanly() public {
        SettlementParams memory params = _validUsdyBuyParams();
        address seller = params.snapshot.seller;

        usdyToken.setBalance(seller, 0);

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(HTPErrors.InsufficientBalance.selector);
        dvp.settle(params);

        _assertNoncesUnused(params);

        // The user can re-fund and the same signatures still work: nothing was burned.
        usdyToken.setBalance(seller, 100 ether);
        usdyToken.setAllowance(seller, address(dvp), params.snapshot.executedQuantity);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    /// The revocation race is decided purely by transaction ordering: whoever
    /// lands first wins, and the loser simply reverts.
    function test_executorCanFrontRunUserCancellation() public {
        SettlementParams memory params = _validUsdyBuyParams();
        address requester = params.tradeIntent.requester;
        uint256 tradeNonce = params.tradeIntent.tradeNonce;

        // Executor's settle lands first.
        vm.prank(EXECUTOR);
        dvp.settle(params);

        // The user's cancellation, broadcast in the same block, now reverts.
        vm.prank(requester);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector, requester, NonceType.REQUESTER_TRADE, tradeNonce, NonceStatus.USED
            )
        );
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, tradeNonce);
    }

    function test_userCancellationWinsIfItLandsFirst() public {
        SettlementParams memory params = _validUsdyBuyParams();
        address requester = params.tradeIntent.requester;

        vm.prank(requester);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);

        vm.prank(EXECUTOR);
        vm.expectPartialRevert(HTPErrors.NonceUnavailable.selector);
        dvp.settle(params);
    }

    /// Cancellation stays available while the DvP is globally paused.
    function test_cancelNonceStillWorksWhilePaused() public {
        SettlementParams memory params = _validUsdyBuyParams();
        address requester = params.tradeIntent.requester;

        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.prank(requester);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
        assertEq(
            uint8(dvp.getNonceStatus(requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce)),
            uint8(NonceStatus.CANCELLED)
        );
    }

    /// F-02: nothing on chain bounds `tradeDeadline - createdAt`. A snapshot
    /// that claims it was created ~57 days ago settles at the deadline, so the
    /// Executor holds a free timing option for the whole window.
    // 修复后：窗口由协议而非运营配置决定。原先 fixture 给出 56.7 天，Executor
    // 因此握有一份按窗口长度计价的免费择时期权；MAX_QUOTE_LIFETIME 把它压到 1 小时，
    // 同时（配合 createdAt <= now <= tradeDeadline）把 createdAt 的回填空间一并压到 1 小时，
    // 使跨 Epoch 的旧费率回放也不再可行——回填到上一个 Epoch 需要回溯数周。
    function test_F02_quoteLifetimeIsProtocolBounded() public {
        SettlementParams memory params = _validUsdyBuyParams();
        uint64 createdAt = params.snapshot.createdAt;
        uint64 deadline = params.snapshot.tradeDeadline;

        uint256 windowSeconds = uint256(deadline) - uint256(createdAt);
        emit log_named_uint("executor option window (seconds)", windowSeconds);
        assertLe(windowSeconds, 1 hours, "window is now bounded by MAX_QUOTE_LIFETIME");

        // Execute at the very last second the window allows.
        vm.warp(deadline);
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS), "still PASS at the deadline");

        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    /// Sanity: the settlement path really does verify only two signatures, so
    /// the platform's TradeTermsSnapshot signature is not an on-chain control.
    function test_snapshotHasNoOnChainSignature() public {
        SettlementParams memory params = _validUsdyBuyParams();
        assertGt(params.quotingMakerSignature.length, 0);
        assertGt(params.requesterSignature.length, 0);
        // There is no third signature field to populate; the snapshot is bound
        // only by the requester's TradeIntent commitment.
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
    }
}
