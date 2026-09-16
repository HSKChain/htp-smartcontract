// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {NonceStatus, NonceType, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract UsdyRestrictionSettlementTest is UsdySettlementFixture {
    struct ObservableState {
        uint256 sellerAsset;
        uint256 buyerAsset;
        uint256 buyerSettlement;
        uint256 sellerSettlement;
        uint256 collectorSettlement;
    }

    function testFromRestrictionsRollbackBuyAndSellForEveryList() public {
        _assertEveryRestriction(_validUsdyBuyParams(), 0);
        _assertEveryRestriction(_validUsdySellParams(), 0);
    }

    function testToRestrictionsRollbackBuyAndSellForEveryList() public {
        _assertEveryRestriction(_validUsdyBuyParams(), 1);
        _assertEveryRestriction(_validUsdySellParams(), 1);
    }

    function testDvpOperatorRestrictionsRollbackBuyAndSellForEveryList() public {
        _assertEveryRestriction(_validUsdyBuyParams(), 2);
        _assertEveryRestriction(_validUsdySellParams(), 2);
    }

    function _assertEveryRestriction(SettlementParams memory params, uint8 targetKind) private {
        address target =
            targetKind == 0 ? params.snapshot.seller : targetKind == 1 ? params.snapshot.buyer : address(dvp);

        for (uint8 restrictionKind = 0; restrictionKind < 3; ++restrictionKind) {
            _setRestriction(target, restrictionKind, true);
            _assertRestrictedAndRolledBack(params);
            _setRestriction(target, restrictionKind, false);
        }
    }

    function _setRestriction(address target, uint8 restrictionKind, bool restricted) private {
        if (restrictionKind == 0) {
            usdyBlocklist.setBlocked(target, restricted);
        } else if (restrictionKind == 1) {
            usdyAllowlist.setAllowed(target, !restricted);
        } else {
            usdySanctions.setSanctioned(target, restricted);
        }
    }

    function _assertRestrictedAndRolledBack(SettlementParams memory params) private {
        ObservableState memory beforeState = _observe(params);
        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);

        ObservableState memory afterState = _observe(params);
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.UNUSED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.UNUSED)
        );
    }

    function _observe(SettlementParams memory params) private view returns (ObservableState memory state) {
        state.sellerAsset = usdyToken.balanceOf(params.snapshot.seller);
        state.buyerAsset = usdyToken.balanceOf(params.snapshot.buyer);
        state.buyerSettlement = settlementToken.balanceOf(params.snapshot.buyer);
        state.sellerSettlement = settlementToken.balanceOf(params.snapshot.seller);
        state.collectorSettlement = settlementToken.balanceOf(params.snapshot.collector);
    }
}
