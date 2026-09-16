// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPSettlementEventsTest is DvPPreCheckTestBase {
    bytes32 private constant SETTLEMENT_EXECUTED_TOPIC = IDvPSettlement.SettlementExecuted.selector;
    bytes32 private constant FEE_COLLECTED_TOPIC = 0xbc3cb3ef76421eeef50f0a68e293ddd9c094e8a104394fe59ca13c21c9ef778b;

    struct SettlementEventData {
        uint256 chainId;
        bytes32 quoteHash;
        uint256 requesterType;
        uint256 requesterSide;
        address requester;
        address quotingMaker;
        address buyer;
        address seller;
        address assetToken;
        address settlementToken;
        uint256 executedQuantity;
        uint256 assetClass;
        bytes32 priceTermsHash;
        bytes32 principalCalculatorConfigId;
        bytes32 principalCalculatorConfigHash;
        bytes32 adapterConfigId;
        bytes32 adapterConfigHash;
        bytes32 settlementTokenConfigId;
        bytes32 settlementTokenConfigHash;
        bytes32 marketRuleConfigId;
        bytes32 marketRuleConfigHash;
        uint256 cashPrincipal;
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 buyerDebit;
        uint256 sellerCredit;
        uint256 feePolicyEpoch;
        bytes32 feeVersionId;
        bytes32 matchedScopeHash;
        uint256 makerQuoteNonce;
        uint256 requesterTradeNonce;
        bytes32 deploymentVersionHash;
    }

    struct FeeEventData {
        uint256 chainId;
        bytes32 snapshotHash;
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 collectorCredit;
        uint256 feePolicyEpoch;
        bytes32 feeVersionId;
        bytes32 matchedScopeHash;
        bytes32 deploymentVersionHash;
    }

    function testSuccessfulSettlementEmitsCompleteEventsAfterPostconditions() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.recordLogs();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory settlementLog = _find(logs, SETTLEMENT_EXECUTED_TOPIC);
        assertEq(settlementLog.emitter, address(dvp));
        assertEq(settlementLog.topics.length, 4);
        assertEq(settlementLog.topics[1], params.tradeIntent.tradeIdHash);
        assertEq(settlementLog.topics[2], params.tradeIntent.snapshotHash);
        assertEq(settlementLog.topics[3], params.snapshot.assetVersionId);
        assertEq(settlementLog.data.length, 0x400);
        SettlementEventData memory settlementData = abi.decode(settlementLog.data, (SettlementEventData));
        assertEq(settlementData.chainId, block.chainid);
        assertEq(settlementData.quoteHash, params.tradeIntent.quoteHash);
        assertEq(settlementData.requesterType, uint256(params.snapshot.requesterType));
        assertEq(settlementData.requesterSide, uint256(params.snapshot.requesterSide));
        assertEq(settlementData.requester, params.snapshot.requester);
        assertEq(settlementData.quotingMaker, params.snapshot.quotingMaker);
        assertEq(settlementData.buyer, params.snapshot.buyer);
        assertEq(settlementData.seller, params.snapshot.seller);
        assertEq(settlementData.assetToken, params.snapshot.assetToken);
        assertEq(settlementData.settlementToken, params.snapshot.settlementToken);
        assertEq(settlementData.executedQuantity, params.snapshot.executedQuantity);
        assertEq(settlementData.assetClass, uint256(params.snapshot.assetClass));
        assertEq(settlementData.priceTermsHash, params.snapshot.priceTermsHash);
        assertEq(settlementData.principalCalculatorConfigId, params.snapshot.principalCalculatorConfigId);
        assertEq(settlementData.principalCalculatorConfigHash, params.snapshot.principalCalculatorConfigHash);
        assertEq(settlementData.adapterConfigId, params.snapshot.adapterConfigId);
        assertEq(settlementData.adapterConfigHash, params.snapshot.adapterConfigHash);
        assertEq(settlementData.settlementTokenConfigId, params.snapshot.settlementTokenConfigId);
        assertEq(settlementData.settlementTokenConfigHash, params.snapshot.settlementTokenConfigHash);
        assertEq(settlementData.marketRuleConfigId, params.snapshot.marketRuleConfigId);
        assertEq(settlementData.marketRuleConfigHash, params.snapshot.marketRuleConfigHash);
        assertEq(settlementData.cashPrincipal, params.snapshot.cashPrincipal);
        assertEq(settlementData.buyerFee, params.snapshot.buyerFee);
        assertEq(settlementData.sellerFee, params.snapshot.sellerFee);
        assertEq(settlementData.buyerDebit, params.snapshot.buyerDebit);
        assertEq(settlementData.sellerCredit, params.snapshot.sellerCredit);
        assertEq(settlementData.feePolicyEpoch, params.snapshot.feePolicyEpoch);
        assertEq(settlementData.feeVersionId, params.snapshot.feeVersionId);
        assertEq(settlementData.matchedScopeHash, params.snapshot.matchedScopeHash);
        assertEq(settlementData.makerQuoteNonce, params.snapshot.makerQuoteNonce);
        assertEq(settlementData.requesterTradeNonce, params.snapshot.requesterTradeNonce);
        assertEq(settlementData.deploymentVersionHash, dvp.deploymentVersionHash());

        Vm.Log memory feeLog = _find(logs, FEE_COLLECTED_TOPIC);
        assertEq(feeLog.topics[1], params.tradeIntent.tradeIdHash);
        assertEq(feeLog.topics[2], bytes32(uint256(uint160(params.snapshot.collector))));
        assertEq(feeLog.topics[3], bytes32(uint256(uint160(params.snapshot.settlementToken))));
        assertEq(feeLog.data.length, 0x120);
        FeeEventData memory feeData = abi.decode(feeLog.data, (FeeEventData));
        assertEq(feeData.chainId, block.chainid);
        assertEq(feeData.snapshotHash, params.tradeIntent.snapshotHash);
        assertEq(feeData.buyerFee, params.snapshot.buyerFee);
        assertEq(feeData.sellerFee, params.snapshot.sellerFee);
        assertEq(feeData.collectorCredit, params.snapshot.collectorCredit);
        assertEq(feeData.feePolicyEpoch, params.snapshot.feePolicyEpoch);
        assertEq(feeData.feeVersionId, params.snapshot.feeVersionId);
        assertEq(feeData.matchedScopeHash, params.snapshot.matchedScopeHash);
        assertEq(feeData.deploymentVersionHash, dvp.deploymentVersionHash());
    }

    function testZeroFeeSettlementStillEmitsFeeCollected() public {
        SettlementParams memory params = _zeroCollectorParams();
        vm.recordLogs();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        FeeEventData memory feeData = abi.decode(_find(vm.getRecordedLogs(), FEE_COLLECTED_TOPIC).data, (FeeEventData));
        assertEq(feeData.buyerFee, 0);
        assertEq(feeData.sellerFee, 0);
        assertEq(feeData.collectorCredit, 0);
    }

    function _find(Vm.Log[] memory logs, bytes32 topic) private pure returns (Vm.Log memory result) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return logs[i];
        }
        revert("EVENT_NOT_FOUND");
    }
}
