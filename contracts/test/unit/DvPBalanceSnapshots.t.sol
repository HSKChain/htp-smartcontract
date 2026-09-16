// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPBalanceSnapshotsTest is DvPPreCheckTestBase {
    function testAllowanceAndBalanceViewsRequireCanonicalWordReturns() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(
            address(assetToken),
            abi.encodeWithSelector(bytes4(0xdd62ed3e), params.snapshot.seller, address(dvp)),
            hex"01"
        );

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(assetToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));

        vm.clearMockedCalls();
        params = _validPreCheckParams();
        vm.mockCall(
            address(settlementToken), abi.encodeWithSelector(bytes4(0x70a08231), params.snapshot.collector), hex"0102"
        );
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(settlementToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testInsufficientPreTransferBalanceRevertsWithExactObservedAmount() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setBalance(params.snapshot.seller, params.snapshot.executedQuantity - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.InsufficientBalance.selector,
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.executedQuantity,
                params.snapshot.executedQuantity - 1
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 0);
    }

    function testPreexistingDvPTokenBalancesRemainExactlyUnchanged() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setBalance(address(dvp), 7 ether);
        settlementToken.setBalance(address(dvp), 9_999);

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(address(dvp)), 7 ether);
        assertEq(settlementToken.balanceOf(address(dvp)), 9_999);
    }

    function testZeroCollectorLegSkipsTransferFrom() public {
        SettlementParams memory zeroCollector = _zeroCollectorParams();
        vm.mockCallRevert(
            address(settlementToken),
            abi.encodeWithSelector(
                bytes4(0x23b872dd), zeroCollector.snapshot.buyer, zeroCollector.snapshot.collector, uint256(0)
            ),
            bytes("ZERO_COLLECTOR_TRANSFER_FORBIDDEN")
        );
        vm.prank(EXECUTOR);
        dvp.settle(zeroCollector);
        assertEq(settlementToken.balanceOf(zeroCollector.snapshot.collector), 0);
    }

    // 卖方净收为零曾经可以配置出来（maker 档 100%），是「交割资产却一分钱不收」
    // 这个荒谬状态的唯一入口。聚合费率上限把它变成不可达，因此这里断言的是
    // 卖方净收恒为正，而不再是零额腿如何被跳过。
    function testSellerCreditIsAlwaysPositiveUnderRegistrableFees() public {
        SettlementParams memory params = _validPreCheckParams();
        assertGt(params.snapshot.sellerCredit, 0, "seller must receive cash for delivered assets");
        assertEq(
            params.snapshot.buyerDebit,
            params.snapshot.sellerCredit + params.snapshot.collectorCredit,
            "conservation still holds"
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), params.snapshot.sellerCredit);
    }
}
