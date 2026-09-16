// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {EligibilityRecord, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract UsdySellSettlementTest is UsdySettlementFixture {
    function testUsdySellSettlesFundNavWithReversedAssetFlow() public {
        SettlementParams memory params = _validUsdySellParams();

        uint256 gasBefore = gasleft();
        _settleUsdy(params);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_usdy_sell_settle_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 1_250_000);

        assertEq(usdyToken.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(usdyToken.balanceOf(params.snapshot.buyer), 110 ether);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), 88_582_900);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), 111_371_500);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), 45_600);

        EligibilityRecord memory sender =
            eligibilityRegistry.getEligibility(_usdyEligibilityKey(params.snapshot.seller));
        EligibilityRecord memory receiver =
            eligibilityRegistry.getEligibility(_usdyEligibilityKey(params.snapshot.buyer));
        assertEq(sender.recordVersion, 1);
        assertEq(receiver.recordVersion, 1);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function _usdyEligibilityKey(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, usdyAssetVersionConfig.assetVersionId));
    }
}
