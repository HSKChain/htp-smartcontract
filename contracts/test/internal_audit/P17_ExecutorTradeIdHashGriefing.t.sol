// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

/*
 * P17：preCheck 漏查三张占用表 —— 已修复，断言已反转
 *
 * 原缺陷：
 * - settle 的 _validateReplayAvailability 查 usedQuoteHash / usedSnapshotHash /
 *   usedTradeIdHash 三张表加两个业务 nonce，共五道防重放闸
 * - preCheck 只经 DvPCurrentStateValidator._validateNonces 查两个 nonce
 * - 于是「新 nonce + 已消费的 tradeIdHash」preCheck PASS、settle 必定
 *   TradeAlreadyExecuted，Executor 白烧约 168k gas
 *
 * 三张表里只有 tradeIdHash 真的可达：quoteHash 由含 quoteNonce 的 FirmQuote 内容
 * 算出，snapshotHash 同理，所以「hash 已用而 nonce 未用」对它俩构造不出来——
 * 已用的 quote 必然伴随已用的 nonce，preCheck 的 nonce 检查早就挡住了。
 * tradeIdHash 是链下自由值，与 nonce 解耦，因此单它漏出来。
 *
 * 修复：
 * - 三张表的判定抽成 DvPSettlement._usedReplayHash，settle 与 preCheck 共用一份清单
 * - preCheck 在签名校验之后、现态校验之前调用它，位置与 _settle 第 2 步对齐，
 *   于是 preCheck 的 reason 精确预测 settle 的首个 revert
 *
 * 射程边界：本次修的是「preCheck 运行时状态已经不对、它只是没看」这一类。
 * 「preCheck 当时状态是对的、之后才变」（M-02 的 cancelNonce 抢跑、allowance 撤回、
 * 资格撤销等）是固有 TOCTOU，不受影响；详细设计 §9 的结论不变——
 * PASS 仍非广播的充分条件，eth_call(settle) 才是门禁。
 */
contract P17_ExecutorTradeIdHashGriefingTest is UsdySettlementFixture {
    /// @notice 已用 tradeIdHash + 新 nonce：preCheck 与 settle 现在给出一致的拒绝
    function test_preCheckBlocksOnUsedTradeIdHashWithFreshNonces() public {
        // --- 1) 先正常成交，消费 tradeIdHash（及原 quote/snapshot/nonce）---
        SettlementParams memory first = _validUsdyBuyParams();
        bytes32 consumedTradeIdHash = first.tradeIntent.tradeIdHash;

        (Decision beforeDecision,) = dvp.preCheck(first);
        assertEq(uint8(beforeDecision), uint8(Decision.PASS), unicode"首笔 preCheck 应 PASS");

        _settleUsdy(first);
        assertTrue(dvp.usedTradeIdHash(consumedTradeIdHash), unicode"首笔后 tradeIdHash 应已占用");

        // --- 2) 构造「新 nonce + 旧 tradeIdHash」的第二份已签 Payload ---
        // 补回余额/授权，否则 preCheck 会在 allowance 诊断项先 BLOCK，掩盖本缺陷
        _fundUsdyBuy();

        SettlementParams memory grief = _validUsdyBuyParams();
        // 换未使用的业务 nonce；quoteHash/snapshotHash 由 _resign 随 nonce 重算为新值
        grief.firmQuote.quoteNonce = first.firmQuote.quoteNonce + 1;
        grief.tradeIntent.tradeNonce = first.tradeIntent.tradeNonce + 1;
        grief.snapshot.makerQuoteNonce = grief.firmQuote.quoteNonce;
        grief.snapshot.requesterTradeNonce = grief.tradeIntent.tradeNonce;
        // 故意钉回已消费的 tradeIdHash（签名会覆盖该字段）
        grief.tradeIntent.tradeIdHash = consumedTradeIdHash;
        grief.snapshot.tradeIdHash = consumedTradeIdHash;
        // 略改 quote 身份字段，避免与已用 quote 内容完全重合（nonce 已不同，digest 本就会变）
        grief.firmQuote.quoteIdHash = bytes32(uint256(first.firmQuote.quoteIdHash) + 1);
        _resign(grief);

        assertTrue(
            dvp.usedTradeIdHash(grief.tradeIntent.tradeIdHash), unicode"复用的 tradeIdHash 仍应显示已用"
        );
        assertFalse(dvp.usedQuoteHash(grief.tradeIntent.quoteHash), unicode"新 quoteHash 应未用");
        assertFalse(dvp.usedSnapshotHash(grief.tradeIntent.snapshotHash), unicode"新 snapshotHash 应未用");

        // --- 3) 修复后：preCheck 查 usedTradeIdHash，Executor 在广播前就被拦下 ---
        (Decision griefDecision, bytes4 griefReason) = dvp.preCheck(grief);
        assertEq(uint8(griefDecision), uint8(Decision.BLOCK), unicode"已用 tradeIdHash 应判 BLOCK");
        assertEq(
            griefReason, HTPErrors.TradeAlreadyExecuted.selector, unicode"reason 应与 settle 的首个 revert 一致"
        );

        // --- 4) 两侧口径一致：真发出去也是同一个错，preCheck 没有说谎 ---
        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.TradeAlreadyExecuted.selector, consumedTradeIdHash));
        dvp.settle(grief);
    }
}
