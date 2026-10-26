// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {MarketRuleStatus, ReasonCode} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

/// @notice SlowMist N8: close emits the independently replayed pause-state transition.
contract SlowMistN8CloseClearsPausedEventTest is DvPPreCheckTestBase {
    bytes32 private constant PAUSE_CHANGED_TOPIC = 0x5c61658f68be70d812cca534901aaeee8d6dc591bdf2dd5b6275cd4c57d90cb3;
    bytes32 private constant CLOSE_EVIDENCE = bytes32(uint256(0xA801));

    function test_N8_CloseWhilePausedEmitsPauseClearedEvent() public {
        vm.prank(REGISTRY_PAUSER);
        marketRuleRegistry.pauseMarketRule(
            marketRuleConfig.marketRuleConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        vm.warp(marketRuleConfig.settlementValidUntil + 1);
        vm.recordLogs();
        vm.prank(address(timelock));
        marketRuleRegistry.closeMarketRule(marketRuleConfig.marketRuleConfigId, CLOSE_EVIDENCE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 pauseEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(marketRuleRegistry) || logs[i].topics[0] != PAUSE_CHANGED_TOPIC) continue;
            ++pauseEvents;
            assertEq(logs[i].topics[1], marketRuleConfig.marketRuleConfigId);
            (uint256 chainId, bool paused, ReasonCode reason, bytes32 evidenceHash, address actor) =
                abi.decode(logs[i].data, (uint256, bool, ReasonCode, bytes32, address));
            assertEq(chainId, block.chainid);
            assertFalse(paused);
            assertEq(uint8(reason), uint8(ReasonCode.GOVERNANCE_ACTION));
            assertEq(evidenceHash, CLOSE_EVIDENCE);
            assertEq(actor, address(timelock));
        }
        assertEq(pauseEvents, 1);

        assertFalse(marketRuleRegistry.getMarketRule(marketRuleConfig.marketRuleConfigId).paused);
        assertEq(
            uint8(marketRuleRegistry.getMarketRule(marketRuleConfig.marketRuleConfigId).status),
            uint8(MarketRuleStatus.CLOSED)
        );
    }

    function test_N8_CloseWhileUnpausedDoesNotEmitPauseChanged() public {
        vm.warp(marketRuleConfig.settlementValidUntil + 1);
        vm.recordLogs();
        vm.prank(address(timelock));
        marketRuleRegistry.closeMarketRule(marketRuleConfig.marketRuleConfigId, CLOSE_EVIDENCE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(marketRuleRegistry) || logs[i].topics[0] != PAUSE_CHANGED_TOPIC);
        }
        assertFalse(marketRuleRegistry.getMarketRule(marketRuleConfig.marketRuleConfigId).paused);
    }
}
