// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {NonceStatus, NonceType, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPSettlementValidationTest is DvPPreCheckTestBase {
    function testSettleReusesCurrentParticipantValidationAndRevertsExactError() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(REGISTRY_PAUSER);
        participantRegistry.pauseParticipant(
            params.firmQuote.quotingMaker, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantInactive.selector, params.firmQuote.quotingMaker));
        vm.prank(EXECUTOR);
        dvp.settle(params);

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
