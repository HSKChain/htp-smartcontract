// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ParticipantType, PrecheckMethod, RequesterSide, RestrictionMode, TransferLeg} from "src/types/HTPTypes.sol";

contract ParticipantAndTransferEnumValuesTest is Test {
    function testParticipantTypeValues() public pure {
        assertEq(uint8(ParticipantType.NONE), 0);
        assertEq(uint8(ParticipantType.INVESTOR), 1);
        assertEq(uint8(ParticipantType.MAKER), 2);
    }

    function testRequesterSideValues() public pure {
        assertEq(uint8(RequesterSide.NONE), 0);
        assertEq(uint8(RequesterSide.BUY), 1);
        assertEq(uint8(RequesterSide.SELL), 2);
    }

    function testRestrictionModeValues() public pure {
        assertEq(uint8(RestrictionMode.NONE), 0);
        assertEq(uint8(RestrictionMode.UNRESTRICTED), 1);
        assertEq(uint8(RestrictionMode.PLATFORM), 2);
        assertEq(uint8(RestrictionMode.ISSUER_EXTERNAL), 3);
        assertEq(uint8(RestrictionMode.TOKEN_ENFORCED), 4);
    }

    function testPrecheckMethodValues() public pure {
        assertEq(uint8(PrecheckMethod.NONE), 0);
        assertEq(uint8(PrecheckMethod.NO_PRECHECK), 1);
        assertEq(uint8(PrecheckMethod.ERC1404_CHECK), 2);
        assertEq(uint8(PrecheckMethod.TOKEN_SPECIFIC_CHECK), 3);
    }

    function testTransferLegValues() public pure {
        assertEq(uint8(TransferLeg.NONE), 0);
        assertEq(uint8(TransferLeg.ASSET), 1);
        assertEq(uint8(TransferLeg.SETTLEMENT_TO_SELLER), 2);
        assertEq(uint8(TransferLeg.SETTLEMENT_TO_COLLECTOR), 3);
    }
}
