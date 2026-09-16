// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";
import {Roles} from "src/libraries/Roles.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";

contract DvPGovernanceTest is DvPTestBase {
    bytes32 private constant GLOBAL_PAUSED_TOPIC = 0x05cbcd4aa0f9ab63e2d15d59e5680bb5c39daed0e9144192f33ef387e5538e3a;
    bytes32 private constant GLOBAL_UNPAUSED_TOPIC = 0x9f7c8dbf3e1af0fde48b3f4920a5b35dbb367792f7406cd588de9b0c7e5bd395;
    bytes32 private constant RETIRED_TOPIC = 0x69838c30c8194db09771e579ce69ae2e9e45e0721a25ff26ad686f0f153fab5f;
    address private constant OUTSIDER = address(0x4001);
    bytes32 private constant EVIDENCE = bytes32(uint256(0xA11CE));

    function testOnlyIndependentPauserCanPauseOnceWithReasonEvidenceAndAuditEvent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, Roles.PAUSER_ROLE
            )
        );
        vm.prank(OUTSIDER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ReasonCodeRequired.selector, ReasonCode.NONE));
        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.NONE, EVIDENCE);

        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, bytes32(0));

        vm.recordLogs();
        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE);

        assertTrue(dvp.globalPaused());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], GLOBAL_PAUSED_TOPIC);
        (uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor) =
            abi.decode(logs[0].data, (uint256, ReasonCode, bytes32, address));
        assertEq(chainId, DEPLOYED_CHAIN_ID);
        assertEq(uint8(reason), uint8(ReasonCode.SECURITY_INCIDENT));
        assertEq(evidenceHash, EVIDENCE);
        assertEq(actor, PAUSER);

        vm.expectRevert(HTPErrors.ContractPaused.selector);
        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE);
    }

    function testOnlyGovernanceCanUnpausePausedContractWithApprovedEvidence() public {
        vm.expectRevert(HTPErrors.ContractNotPaused.selector);
        vm.prank(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(PAUSER);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ReasonCodeRequired.selector, ReasonCode.NONE));
        vm.prank(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.NONE, EVIDENCE);

        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, bytes32(0));

        vm.recordLogs();
        vm.prank(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        assertFalse(dvp.globalPaused());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], GLOBAL_UNPAUSED_TOPIC);
        (uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor) =
            abi.decode(logs[0].data, (uint256, ReasonCode, bytes32, address));
        assertEq(chainId, DEPLOYED_CHAIN_ID);
        assertEq(uint8(reason), uint8(ReasonCode.GOVERNANCE_ACTION));
        assertEq(evidenceHash, EVIDENCE);
        assertEq(actor, GOVERNANCE);
    }

    function testRetireIsGovernedPausedSingleTerminalState() public {
        vm.expectRevert(HTPErrors.ContractNotPaused.selector);
        vm.prank(GOVERNANCE);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE);

        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(OUTSIDER);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE);

        vm.recordLogs();
        vm.prank(GOVERNANCE);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE);

        assertTrue(dvp.globalPaused());
        assertTrue(dvp.retired());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], RETIRED_TOPIC);
        (uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor) =
            abi.decode(logs[0].data, (uint256, ReasonCode, bytes32, address));
        assertEq(chainId, DEPLOYED_CHAIN_ID);
        assertEq(uint8(reason), uint8(ReasonCode.PLANNED_MIGRATION));
        assertEq(evidenceHash, EVIDENCE);
        assertEq(actor, GOVERNANCE);

        vm.expectRevert(HTPErrors.RetiredContract.selector);
        vm.prank(GOVERNANCE);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE);

        vm.expectRevert(HTPErrors.RetiredContract.selector);
        vm.prank(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE);

        SettlementParams memory params;
        params.firmQuote = SchemaFixtures.firmQuote();
        params.tradeIntent = SchemaFixtures.tradeIntent();
        params.snapshot = SchemaFixtures.snapshot();
        params.snapshot.chainId = DEPLOYED_CHAIN_ID;
        params.snapshot.dvpContract = address(dvp);
        vm.expectRevert(HTPErrors.RetiredContract.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }
}
