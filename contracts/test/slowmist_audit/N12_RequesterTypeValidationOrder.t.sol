// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, NonceStatus, NonceType, ParticipantType, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

/// @notice SlowMist N12: invalid requester types are rejected before registry-state checks.
contract SlowMistN12RequesterTypeValidationOrderTest is DvPPreCheckTestBase {
    function test_N12_NoneRequesterTypeUsesRelationshipErrorOnPreCheckAndSettle() public {
        SettlementParams memory params = _validPreCheckParams();
        params.firmQuote.requesterType = ParticipantType.NONE;
        params.snapshot.requesterType = ParticipantType.NONE;
        params.tradeIntent.requesterType = ParticipantType.NONE;
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.ParticipantRelationshipInvalid.selector);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantRelationshipInvalid.selector, ParticipantType.NONE));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(vm.getRecordedLogs().length, 0);
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
}
