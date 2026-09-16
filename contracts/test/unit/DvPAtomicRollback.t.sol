// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    Decision,
    EligibilityRecord,
    NonceStatus,
    NonceType,
    ReasonCode,
    SettlementParams,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPAtomicRollbackTest is DvPPreCheckTestBase {
    bytes32 private constant SETTLEMENT_EXECUTED_TOPIC = IDvPSettlement.SettlementExecuted.selector;
    bytes32 private constant FEE_COLLECTED_TOPIC = 0xbc3cb3ef76421eeef50f0a68e293ddd9c094e8a104394fe59ca13c21c9ef778b;

    function testCalculatorFailureOccursBeforeEverySettlementWrite() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(calculator),
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            bytes("CALCULATOR_FAILURE")
        );

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ExternalCallFailed.selector, IPrincipalCalculator.calculate.selector)
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(params);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testAdapterFailureOccursBeforeEverySettlementWrite() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(
                IAssetAdapter.preCheck.selector,
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.buyer,
                params.snapshot.executedQuantity,
                TransferLeg.ASSET,
                params.tradeIntent.snapshotHash
            ),
            abi.encode(Decision.BLOCK, uint256(77), bytes32(uint256(0xBAD)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TransferRestricted.selector,
                params.snapshot.adapterConfigId,
                uint256(77),
                bytes32(uint256(0xBAD))
            )
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(params);
    }

    function testEligibilityFailureRollsBackPreviouslyWrittenReplayLocks() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 senderKey = _key(params.snapshot.seller);
        vm.prank(REGISTRY_PAUSER);
        eligibilityRegistry.pauseEligibility(senderKey, 1, ReasonCode.ELIGIBILITY_INCIDENT, EVIDENCE_HASH);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.EligibilityPausedOrRevoked.selector, senderKey));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        _assertUnchanged(params);
        EligibilityRecord memory sender = eligibilityRegistry.getEligibility(senderKey);
        assertTrue(sender.paused);
        assertEq(sender.recordVersion, 2);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());
    }

    function testSecondTransferFailureRollsBackAssetTransferEligibilityAndLocks() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(settlementToken),
            abi.encodeWithSelector(
                bytes4(0x23b872dd), params.snapshot.buyer, params.snapshot.seller, params.snapshot.sellerCredit
            ),
            bytes("SETTLEMENT_TRANSFER_FAILURE")
        );

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, params.snapshot.settlementToken)
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(params);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());
    }

    function _assertUnchanged(SettlementParams memory params) private view {
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
        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 0);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), 100_000_000);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), 0);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), 0);
    }

    function _key(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, assetVersionConfig.assetVersionId));
    }

    function _assertNoTerminalSettlementLogs(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0
                    || (logs[i].topics[0] != SETTLEMENT_EXECUTED_TOPIC && logs[i].topics[0] != FEE_COLLECTED_TOPIC)
            );
        }
    }
}
