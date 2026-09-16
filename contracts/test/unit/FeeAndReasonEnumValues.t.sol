// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ReasonCode, ScopeType} from "src/types/HTPTypes.sol";

contract FeeAndReasonEnumValuesTest is Test {
    function testScopeTypeValuesDoNotEncodeResolverPriority() public pure {
        assertEq(uint8(ScopeType.NONE), 0);
        assertEq(uint8(ScopeType.GLOBAL), 1);
        assertEq(uint8(ScopeType.CHAIN), 2);
        assertEq(uint8(ScopeType.ASSET_CLASS), 3);
        assertEq(uint8(ScopeType.INSTRUMENT), 4);
        assertEq(uint8(ScopeType.ASSET_VERSION), 5);
    }

    function testReasonCodeValues() public pure {
        assertEq(uint8(ReasonCode.NONE), 0);
        assertEq(uint8(ReasonCode.SECURITY_INCIDENT), 1);
        assertEq(uint8(ReasonCode.CONFIG_MISMATCH), 2);
        assertEq(uint8(ReasonCode.TOKEN_BEHAVIOR_CHANGED), 3);
        assertEq(uint8(ReasonCode.IMPLEMENTATION_CHANGED), 4);
        assertEq(uint8(ReasonCode.ELIGIBILITY_INCIDENT), 5);
        assertEq(uint8(ReasonCode.RECONCILIATION_EXCEPTION), 6);
        assertEq(uint8(ReasonCode.RPC_OR_FINALITY_INCIDENT), 7);
        assertEq(uint8(ReasonCode.PLANNED_MIGRATION), 8);
        assertEq(uint8(ReasonCode.GOVERNANCE_ACTION), 9);
    }
}
