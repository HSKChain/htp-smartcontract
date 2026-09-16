// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {Roles} from "src/libraries/Roles.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ParticipantType, PermitData, RequesterSide, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdyMultiPartyE2EFixture} from "test/helpers/UsdyMultiPartyE2EFixture.sol";

contract UsdyMultiPartyE2ETest is UsdyMultiPartyE2EFixture {
    address private constant OUTSIDER = address(0xBAD);
    uint256 private constant UNREGISTERED_KEY = 0xDEAD;
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

    function testFourPartyBuySellAndMakerToMakerLifecycleConservesBalancesAndFees() public {
        _settleObservedTrade(
            _buildTrade(MAKER_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 1), true
        );
        _settleObservedTrade(
            _buildTrade(MAKER2_KEY, INVESTOR2_KEY, ParticipantType.INVESTOR, RequesterSide.SELL, 2), false
        );
        _settleObservedTrade(_buildTrade(MAKER2_KEY, MAKER_KEY, ParticipantType.MAKER, RequesterSide.BUY, 3), false);
        _settleObservedTrade(_buildTrade(MAKER_KEY, MAKER2_KEY, ParticipantType.MAKER, RequesterSide.SELL, 4), false);

        assertEq(usdyToken.balanceOf(maker1), 110 ether);
        assertEq(usdyToken.balanceOf(maker2), 90 ether);
        assertEq(usdyToken.balanceOf(investor1), 10 ether);
        assertEq(usdyToken.balanceOf(investor2), 10 ether);
        assertEq(settlementToken.balanceOf(maker1), 88_548_700);
        assertEq(settlementToken.balanceOf(maker2), 111_348_700);
        assertEq(settlementToken.balanceOf(investor1), 88_571_500);
        assertEq(settlementToken.balanceOf(investor2), 111_371_500);
        assertEq(settlementToken.balanceOf(COLLECTOR), 159_600);
        assertEq(usdyToken.balanceOf(address(dvp)), 0);
        assertEq(settlementToken.balanceOf(address(dvp)), 0);

        assertEq(
            usdyToken.balanceOf(maker1) + usdyToken.balanceOf(maker2) + usdyToken.balanceOf(investor1)
                + usdyToken.balanceOf(investor2) + usdyToken.balanceOf(address(dvp)),
            220 ether
        );
        assertEq(
            settlementToken.balanceOf(maker1) + settlementToken.balanceOf(maker2) + settlementToken.balanceOf(investor1)
                + settlementToken.balanceOf(investor2) + settlementToken.balanceOf(COLLECTOR)
                + settlementToken.balanceOf(address(dvp)),
            400_000_000
        );
    }

    function testInvestorCannotActAsQuotingMaker() public {
        SettlementParams memory params =
            _buildTrade(INVESTOR2_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 91);
        _assertRejectedWithoutLocks(params, HTPErrors.ParticipantInactive.selector, params.firmQuote.quotingMaker);
    }

    function testInvestorToInvestorRelationshipIsRejected() public {
        SettlementParams memory params =
            _buildTrade(INVESTOR2_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.SELL, 92);
        _assertRejectedWithoutLocks(params, HTPErrors.ParticipantInactive.selector, params.firmQuote.quotingMaker);
    }

    function testUnregisteredWalletCannotSettle() public {
        SettlementParams memory params =
            _buildTrade(MAKER_KEY, UNREGISTERED_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 93);
        _assertRejectedWithoutLocks(params, HTPErrors.ParticipantInactive.selector, params.firmQuote.requester);
    }

    function testOnlyExecutorCanSettleValidTrade() public {
        SettlementParams memory params =
            _buildTrade(MAKER_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 94);
        _assertPreCheckPass(params);
        ObservableState memory beforeState = _observe();
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, Roles.EXECUTOR_ROLE
            )
        );
        vm.prank(OUTSIDER);
        dvp.settle(params);
        _assertUnchanged(beforeState);
        _assertUnused(params);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());
    }

    function testPreCheckPassDoesNotAuthorizeAfterUsdyRestrictionChanges() public {
        SettlementParams memory params =
            _buildTrade(MAKER_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 96);
        _assertPreCheckPass(params);

        usdyBlocklist.setBlocked(params.snapshot.seller, true);
        ObservableState memory beforeState = _observe();
        vm.recordLogs();
        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(beforeState);
        _assertUnused(params);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());

        usdyBlocklist.setBlocked(params.snapshot.seller, false);
        _settleObservedTrade(params, false);
    }

    function testUsdyPermitIsRejectedByUnsupportedAssetConfiguration() public {
        SettlementParams memory params =
            _buildTrade(MAKER_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 97);
        params.assetPermit = PermitData({
            usePermit: true,
            owner: params.snapshot.seller,
            token: params.snapshot.assetToken,
            value: params.snapshot.executedQuantity,
            deadline: params.snapshot.tradeDeadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        _assertPreCheckBlock(params, HTPErrors.InvalidSettlementParams.selector);
        uint256 sellerAllowanceBefore = usdyToken.allowance(params.snapshot.seller, address(dvp));
        ObservableState memory beforeState = _observe();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.PermitUnsupported.selector, params.snapshot.assetToken));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(beforeState);
        _assertUnused(params);
        assertEq(usdyToken.allowance(params.snapshot.seller, address(dvp)), sellerAllowanceBefore);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());

        _settleObservedTrade(
            _buildTrade(MAKER_KEY, REQUESTER_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 98), false
        );
    }

    function _settleObservedTrade(SettlementParams memory params, bool rejectOutsider) private {
        _assertPreCheckPass(params);
        if (rejectOutsider) {
            ObservableState memory beforeOutsider = _observe();
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, Roles.EXECUTOR_ROLE
                )
            );
            vm.prank(OUTSIDER);
            dvp.settle(params);
            _assertUnchanged(beforeOutsider);
            _assertUnused(params);
        }

        uint256 sellerAssetBefore = usdyToken.balanceOf(params.snapshot.seller);
        uint256 buyerAssetBefore = usdyToken.balanceOf(params.snapshot.buyer);
        uint256 buyerCashBefore = settlementToken.balanceOf(params.snapshot.buyer);
        uint256 sellerCashBefore = settlementToken.balanceOf(params.snapshot.seller);
        uint256 collectorBefore = settlementToken.balanceOf(COLLECTOR);

        vm.recordLogs();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(usdyToken.balanceOf(params.snapshot.seller), sellerAssetBefore - 10 ether);
        assertEq(usdyToken.balanceOf(params.snapshot.buyer), buyerAssetBefore + 10 ether);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), buyerCashBefore - params.snapshot.buyerDebit);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), sellerCashBefore + params.snapshot.sellerCredit);
        assertEq(settlementToken.balanceOf(COLLECTOR), collectorBefore + params.snapshot.collectorCredit);
        assertEq(usdyToken.balanceOf(address(dvp)), 0);
        assertEq(settlementToken.balanceOf(address(dvp)), 0);
        _assertConsumed(params);
        _assertSettlementEvents(params, vm.getRecordedLogs());
    }

    function _assertRejectedWithoutLocks(SettlementParams memory params, bytes4 selector, address wallet) private {
        _assertPreCheckBlock(params, selector);
        ObservableState memory beforeState = _observe();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(selector, wallet));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertUnchanged(beforeState);
        _assertUnused(params);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());
    }

    function _assertSettlementEvents(SettlementParams memory params, Vm.Log[] memory logs) private view {
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
        assertEq(settlementData.executedQuantity, 10 ether);
        assertEq(settlementData.cashPrincipal, CASH_PRINCIPAL);
        assertEq(settlementData.buyerFee, params.snapshot.buyerFee);
        assertEq(settlementData.sellerFee, params.snapshot.sellerFee);
        assertEq(settlementData.buyerDebit, params.snapshot.buyerDebit);
        assertEq(settlementData.sellerCredit, params.snapshot.sellerCredit);
        assertEq(settlementData.adapterConfigId, params.snapshot.adapterConfigId);
        assertEq(settlementData.adapterConfigHash, params.snapshot.adapterConfigHash);
        assertEq(settlementData.marketRuleConfigId, params.snapshot.marketRuleConfigId);
        assertEq(settlementData.marketRuleConfigHash, params.snapshot.marketRuleConfigHash);
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
        assertEq(feeData.feeVersionId, params.snapshot.feeVersionId);
        assertEq(feeData.matchedScopeHash, params.snapshot.matchedScopeHash);
        assertEq(feeData.deploymentVersionHash, dvp.deploymentVersionHash());
    }

    function _assertNoTerminalSettlementLogs(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0
                    || (logs[i].topics[0] != SETTLEMENT_EXECUTED_TOPIC && logs[i].topics[0] != FEE_COLLECTED_TOPIC)
            );
        }
    }

    function _find(Vm.Log[] memory logs, bytes32 topic) private pure returns (Vm.Log memory result) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return logs[i];
        }
        revert("EVENT_NOT_FOUND");
    }
}
