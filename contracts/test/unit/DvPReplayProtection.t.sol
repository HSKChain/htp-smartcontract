// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {EligibilityRecord, NonceStatus, NonceType, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPReplayProtectionTest is DvPPreCheckTestBase {
    function testSuccessfulSettlementWritesReplayLocksKeepsEligibilityAndTransfersExactAmounts() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 senderKey = _eligibilityKey(params.snapshot.seller);
        bytes32 receiverKey = _eligibilityKey(params.snapshot.buyer);

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertTrue(_used("usedQuoteHash(bytes32)", params.tradeIntent.quoteHash));
        assertTrue(_used("usedSnapshotHash(bytes32)", params.tradeIntent.snapshotHash));
        assertTrue(_used("usedTradeIdHash(bytes32)", params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.USED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.USED)
        );

        EligibilityRecord memory sender = eligibilityRegistry.getEligibility(senderKey);
        EligibilityRecord memory receiver = eligibilityRegistry.getEligibility(receiverKey);
        assertEq(sender.recordVersion, 1);
        assertEq(receiver.recordVersion, 1);

        assertEq(assetToken.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 10 ether);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), 88_571_500);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), 11_382_900);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), 45_600);
        assertEq(assetToken.balanceOf(address(dvp)), 0);
        assertEq(settlementToken.balanceOf(address(dvp)), 0);
    }

    function testExactSettlementCanSucceedOnlyOnce() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(params);
        uint256 buyerAssetAfter = assetToken.balanceOf(params.snapshot.buyer);
        uint256 buyerSettlementAfter = settlementToken.balanceOf(params.snapshot.buyer);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.QuoteAlreadyExecuted.selector, params.tradeIntent.quoteHash));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(params.snapshot.buyer), buyerAssetAfter);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), buyerSettlementAfter);
    }

    function testTradeIdCannotBeReusedWithFreshQuoteSnapshotAndNonces() public {
        SettlementParams memory first = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(first);

        SettlementParams memory second = _validPreCheckParams();
        second.firmQuote.quoteNonce += 100;
        second.snapshot.makerQuoteNonce = second.firmQuote.quoteNonce;
        second.tradeIntent.tradeNonce += 100;
        second.snapshot.requesterTradeNonce = second.tradeIntent.tradeNonce;
        _resign(second);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.TradeAlreadyExecuted.selector, second.tradeIntent.tradeIdHash));
        vm.prank(EXECUTOR);
        dvp.settle(second);
    }

    function testCancelledMakerQuoteNoncePermanentlyBlocksSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(params.firmQuote.quotingMaker);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                params.firmQuote.quotingMaker,
                NonceType.MAKER_QUOTE,
                params.firmQuote.quoteNonce,
                NonceStatus.CANCELLED
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testUsedBusinessNoncesCannotBeCancelledOrRolledBack() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                params.firmQuote.quotingMaker,
                NonceType.MAKER_QUOTE,
                params.firmQuote.quoteNonce,
                NonceStatus.USED
            )
        );
        vm.prank(params.firmQuote.quotingMaker);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                params.tradeIntent.requester,
                NonceType.REQUESTER_TRADE,
                params.tradeIntent.tradeNonce,
                NonceStatus.USED
            )
        );
        vm.prank(params.tradeIntent.requester);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);

        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.USED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.USED)
        );
    }

    function testUsedMakerQuoteNonceBlocksFreshQuoteSnapshotAndTrade() public {
        SettlementParams memory first = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(first);

        SettlementParams memory second = _freshTradeKeepingNonces(true, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                second.firmQuote.quotingMaker,
                NonceType.MAKER_QUOTE,
                second.firmQuote.quoteNonce,
                NonceStatus.USED
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(second);
    }

    function testUsedRequesterTradeNonceBlocksFreshQuoteSnapshotAndTrade() public {
        SettlementParams memory first = _validPreCheckParams();
        vm.prank(EXECUTOR);
        dvp.settle(first);

        SettlementParams memory second = _freshTradeKeepingNonces(false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector,
                second.tradeIntent.requester,
                NonceType.REQUESTER_TRADE,
                second.tradeIntent.tradeNonce,
                NonceStatus.USED
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(second);
    }

    function _eligibilityKey(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, assetVersionConfig.assetVersionId));
    }

    function _freshTradeKeepingNonces(bool keepMakerNonce, bool keepRequesterNonce)
        private
        view
        returns (SettlementParams memory params)
    {
        params = _validPreCheckParams();
        params.firmQuote.rfqIdHash = bytes32(uint256(0xF001));
        params.firmQuote.quoteIdHash = bytes32(uint256(0xF002));
        params.tradeIntent.tradeIdHash = bytes32(uint256(0xF003));
        params.snapshot.tradeIdHash = params.tradeIntent.tradeIdHash;
        if (!keepMakerNonce) {
            params.firmQuote.quoteNonce += 100;
            params.snapshot.makerQuoteNonce = params.firmQuote.quoteNonce;
        }
        if (!keepRequesterNonce) {
            params.tradeIntent.tradeNonce += 100;
            params.snapshot.requesterTradeNonce = params.tradeIntent.tradeNonce;
        }
        _resign(params);
    }

    function _used(string memory signature, bytes32 hash) private view returns (bool value) {
        (bool success, bytes memory returnData) = address(dvp).staticcall(abi.encodeWithSignature(signature, hash));
        assertTrue(success);
        assertEq(returnData.length, 32);
        value = abi.decode(returnData, (bool));
    }
}
