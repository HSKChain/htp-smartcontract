// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPTokenTransfersTest is DvPPreCheckTestBase {
    function testTransferFromAcceptsNoReturnValueWhenDeltasAreExact() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setTransferMode(1);
        settlementToken.setTransferMode(1);

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), params.snapshot.sellerCredit);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), params.snapshot.collectorCredit);
    }

    function testTransferFromRejectsFalseAndMalformedReturns() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setTransferMode(2);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(assetToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));

        assetToken.setTransferMode(4);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(assetToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
    }

    function testFeeOnTransferIsRejectedByExactBalanceDeltaPostcondition() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setTransferMode(3);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.BalanceDeltaMismatch.selector,
                params.snapshot.assetToken,
                params.snapshot.buyer,
                params.snapshot.executedQuantity,
                params.snapshot.executedQuantity - 1
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 0);
    }

    function testReflectionIntoDvPBalanceIsRejectedAndRolledBack() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setTransferMode(5);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.BalanceDeltaMismatch.selector,
                params.snapshot.assetToken,
                address(dvp),
                uint256(0),
                uint256(1)
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(address(dvp)), 0);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testReverseDirectionRebaseIsRejectedAndRolledBack() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setTransferMode(6);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.BalanceDeltaMismatch.selector,
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.executedQuantity,
                params.snapshot.executedQuantity
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 0);
    }
}
