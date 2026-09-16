// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {EligibilityRecord, NonceStatus, NonceType, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract UsdyBuySettlementTest is UsdySettlementFixture {
    function testUsdyBuySettlesFundNavAtomically() public {
        SettlementParams memory params = _validUsdyBuyParams();

        uint256 gasBefore = gasleft();
        _settleUsdy(params);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_usdy_buy_settle_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 1_250_000);

        assertEq(usdyToken.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(usdyToken.balanceOf(params.snapshot.buyer), 10 ether);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), 88_571_500);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), 11_382_900);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), 45_600);
        assertEq(usdyToken.balanceOf(address(dvp)), 0);
        assertEq(settlementToken.balanceOf(address(dvp)), 0);

        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
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

        EligibilityRecord memory sender =
            eligibilityRegistry.getEligibility(_usdyEligibilityKey(params.snapshot.seller));
        EligibilityRecord memory receiver =
            eligibilityRegistry.getEligibility(_usdyEligibilityKey(params.snapshot.buyer));
        assertEq(sender.recordVersion, 1);
        assertEq(receiver.recordVersion, 1);
    }

    function _usdyEligibilityKey(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, usdyAssetVersionConfig.assetVersionId));
    }
}
