// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPGovernanceView} from "src/interfaces/IDvPGovernanceView.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {MockDvP} from "test/fixtures/MockDvP.sol";

contract IDvPGovernanceViewTest is Test {
    bytes32 private constant DEPLOYMENT_VERSION_HASH =
        0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42;

    MockDvP private immutable MOCK_DVP = new MockDvP(DEPLOYMENT_VERSION_HASH);

    function testGovernanceViewSelectorsAndMockStateTransitions() public {
        assertEq(IDvPGovernanceView.globalPaused.selector, bytes4(0x61a552dc));
        assertEq(IDvPGovernanceView.retired.selector, bytes4(0x2eb38ae0));
        assertEq(IDvPGovernanceView.deploymentVersionHash.selector, bytes4(0x22a5a34f));

        assertFalse(MOCK_DVP.globalPaused());
        assertFalse(MOCK_DVP.retired());
        assertEq(MOCK_DVP.deploymentVersionHash(), DEPLOYMENT_VERSION_HASH);

        MOCK_DVP.setGlobalPaused(true);
        MOCK_DVP.setRetired(true);
        assertTrue(MOCK_DVP.globalPaused());
        assertTrue(MOCK_DVP.retired());
    }

    function testMockDoesNotExposeSettlementBehavior() public {
        SettlementParams memory params;
        (bool success,) = address(MOCK_DVP).call(abi.encodeCall(IDvPSettlement.settle, (params)));
        assertFalse(success);
    }
}
