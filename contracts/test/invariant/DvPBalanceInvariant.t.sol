// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {
    Decision,
    EligibilityRecord,
    NonceStatus,
    NonceType,
    ReasonCode,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DeployFixture} from "test/helpers/DeployFixture.sol";
import {DvPPreCheckToken} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPSettlementStateHandler is Test {
    bytes32 private constant SETTLEMENT_EXECUTED_TOPIC = IDvPSettlement.SettlementExecuted.selector;
    bytes32 private constant FEE_COLLECTED_TOPIC = 0xbc3cb3ef76421eeef50f0a68e293ddd9c094e8a104394fe59ca13c21c9ef778b;
    uint256 private constant CANCEL_NONCE_BASE = 1_000_000;
    uint256 private constant MAKER_KEY = 0xA11CE;
    uint256 private constant REQUESTER_KEY = 0xB0B;
    address private immutable dvpAdmin;
    address private constant DVP_PAUSER = address(0x2001);
    address private constant EXECUTOR = address(0x3001);
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0xE313));

    DvPSettlement private immutable dvp;
    EligibilityRegistry private immutable eligibilityRegistry;
    DvPPreCheckToken private immutable assetToken;
    DvPPreCheckToken private immutable settlementToken;

    SettlementParams private baseParams;
    uint256[] private successfulTradeIndexes;

    uint256 public nextTradeIndex;
    uint256 public preCheckCalls;
    uint256 public externalUnknownHits;
    uint256 public externalUnknownSkips;
    uint256 public successfulSettlements;
    uint256 public successfulExecutedQuantity;
    uint256 public successfulBuyerDebit;
    uint256 public successfulSellerCredit;
    uint256 public successfulCollectorCredit;
    uint256 public settlementEventCount;
    uint256 public settlementEventQuantity;
    bool public successfulIdentityCollision;

    mapping(bytes32 identity => uint256 count) public quoteSuccessCount;
    mapping(bytes32 identity => uint256 count) public snapshotSuccessCount;
    mapping(bytes32 identity => uint256 count) public tradeSuccessCount;
    mapping(bytes32 identity => uint256 count) public makerNonceSuccessCount;
    mapping(bytes32 identity => uint256 count) public requesterNonceSuccessCount;

    struct SettlementMutationState {
        uint256 successfulCount;
        bool quoteUsed;
        bool snapshotUsed;
        bool tradeUsed;
        NonceStatus makerNonce;
        NonceStatus requesterNonce;
        EligibilityRecord senderEligibility;
        EligibilityRecord receiverEligibility;
        uint256 assetSeller;
        uint256 assetBuyer;
        uint256 cashBuyer;
        uint256 cashSeller;
        uint256 cashCollector;
        uint256 dvpAsset;
        uint256 dvpCash;
    }

    constructor(
        DvPSettlement dvp_,
        EligibilityRegistry eligibilityRegistry_,
        DvPPreCheckToken assetToken_,
        DvPPreCheckToken settlementToken_,
        SettlementParams memory baseParams_,
        address dvpAdmin_
    ) {
        dvp = dvp_;
        eligibilityRegistry = eligibilityRegistry_;
        assetToken = assetToken_;
        settlementToken = settlementToken_;
        baseParams = baseParams_;
        dvpAdmin = dvpAdmin_;
    }

    function preCheck(uint256 seed) external {
        ++preCheckCalls;
        SettlementParams memory params = _freshParams(seed % 1_000_000);
        bool quoteBefore = dvp.usedQuoteHash(params.tradeIntent.quoteHash);
        bool snapshotBefore = dvp.usedSnapshotHash(params.tradeIntent.snapshotHash);
        bool tradeBefore = dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash);
        EligibilityRecord memory senderBefore = _senderEligibility();
        EligibilityRecord memory receiverBefore = _receiverEligibility();

        dvp.preCheck(params);

        assertEq(dvp.usedQuoteHash(params.tradeIntent.quoteHash), quoteBefore);
        assertEq(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash), snapshotBefore);
        assertEq(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash), tradeBefore);
        _assertEligibilityEqual(senderBefore, _senderEligibility());
        _assertEligibilityEqual(receiverBefore, _receiverEligibility());
    }

    function settle(uint256) external {
        _attemptSettlement(_freshParams(nextTradeIndex++));
    }

    function replay(uint256 seed) external {
        uint256 length = successfulTradeIndexes.length;
        if (length == 0) return;
        SettlementParams memory params = _freshParams(successfulTradeIndexes[seed % length]);
        _assertFailedWithoutSettlementMutation(params);
    }

    function externalUnknown(uint256 seed) external {
        if (dvp.retired() || dvp.globalPaused()) {
            ++externalUnknownSkips;
            return;
        }

        SettlementParams memory params = _freshParams(nextTradeIndex++);
        address target;
        bytes memory callData;
        uint256 stage = seed % 3;
        if (stage == 0) {
            target = address(dvp.assetVersionRegistry());
            callData = abi.encodeCall(IAssetVersionRegistry.getAssetVersion, (params.snapshot.assetVersionId));
        } else if (stage == 1) {
            target = address(dvp.adapterRegistry());
            callData = abi.encodeCall(IAdapterRegistry.getAdapter, (params.snapshot.adapterConfigId));
        } else {
            target = address(dvp.principalCalculatorRegistry());
            callData = abi.encodeCall(
                IPrincipalCalculatorRegistry.getPrincipalCalculator, (params.snapshot.principalCalculatorConfigId)
            );
        }

        vm.mockCallRevert(target, callData, bytes("INVARIANT_EXTERNAL_UNKNOWN"));
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        ++externalUnknownHits;
        _assertFailedWithoutSettlementMutation(params);
        vm.clearMockedCalls();
    }

    function cancelAndRejectSettlement(uint256 seed) external {
        uint256 index = nextTradeIndex++;
        SettlementParams memory params = _freshParams(index);
        NonceType nonceType = seed % 2 == 0 ? NonceType.MAKER_QUOTE : NonceType.REQUESTER_TRADE;
        address signer;
        uint256 nonce = CANCEL_NONCE_BASE + (seed % 256);
        if (nonceType == NonceType.MAKER_QUOTE) {
            signer = params.firmQuote.quotingMaker;
            params.firmQuote.quoteNonce = nonce;
            params.snapshot.makerQuoteNonce = nonce;
        } else {
            signer = params.tradeIntent.requester;
            params.tradeIntent.tradeNonce = nonce;
            params.snapshot.requesterTradeNonce = nonce;
        }
        _resignFresh(params);

        if (dvp.getNonceStatus(signer, nonceType, nonce) == NonceStatus.UNUSED) {
            vm.prank(signer);
            dvp.cancelNonce(nonceType, nonce);
        }
        assertEq(uint8(dvp.getNonceStatus(signer, nonceType, nonce)), uint8(NonceStatus.CANCELLED));
        _assertFailedWithoutSettlementMutation(params);
    }

    function pauseAndRejectSettlement(uint256) external {
        if (dvp.retired()) return;
        if (!dvp.globalPaused()) {
            vm.prank(DVP_PAUSER);
            dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        }
        _assertFailedWithoutSettlementMutation(_freshParams(nextTradeIndex++));
    }

    function unpause(uint256) external {
        if (dvp.retired() || !dvp.globalPaused()) return;
        vm.prank(dvpAdmin);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
    }

    function retireAndRejectSettlement(uint256) external {
        if (dvp.retired()) {
            _assertFailedWithoutSettlementMutation(_freshParams(nextTradeIndex++));
            return;
        }
        if (!dvp.globalPaused()) {
            vm.prank(DVP_PAUSER);
            dvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        }
        vm.prank(dvpAdmin);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        _assertFailedWithoutSettlementMutation(_freshParams(nextTradeIndex++));
    }

    function settleWithReentrantCancellation(uint256 seed) external {
        if (dvp.retired() || dvp.globalPaused()) return;
        uint256 callbackNonce = CANCEL_NONCE_BASE + 1_000 + (seed % 256);
        assetToken.configureCallback(
            address(dvp), abi.encodeCall(dvp.cancelNonce, (NonceType.MAKER_QUOTE, callbackNonce))
        );
        _attemptSettlement(_freshParams(nextTradeIndex++));
        assetToken.configureCallback(address(0), bytes(""));
        assertEq(
            uint8(dvp.getNonceStatus(address(assetToken), NonceType.MAKER_QUOTE, callbackNonce)),
            uint8(NonceStatus.UNUSED)
        );
    }

    function successfulTradeIndex(uint256 index) external view returns (uint256) {
        return successfulTradeIndexes[index];
    }

    function successfulTradeIndexCount() external view returns (uint256) {
        return successfulTradeIndexes.length;
    }

    function paramsForSuccessfulIndex(uint256 arrayIndex) external view returns (SettlementParams memory) {
        return _freshParams(successfulTradeIndexes[arrayIndex]);
    }

    function _attemptSettlement(SettlementParams memory params) private {
        vm.recordLogs();
        vm.prank(EXECUTOR);
        (bool success,) = address(dvp).call(abi.encodeCall(dvp.settle, (params)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!success) {
            _assertNoSettlementEvent(logs);
            return;
        }

        ++successfulSettlements;
        successfulExecutedQuantity += params.snapshot.executedQuantity;
        successfulBuyerDebit += params.snapshot.buyerDebit;
        successfulSellerCredit += params.snapshot.sellerCredit;
        successfulCollectorCredit += params.snapshot.collectorCredit;
        successfulTradeIndexes.push(_tradeIndex(params));
        _recordSuccessfulIdentities(params);
        _recordSettlementEvent(logs, params);
    }

    function _assertFailedWithoutSettlementMutation(SettlementParams memory params) private {
        SettlementMutationState memory beforeState = _settlementMutationState(params);

        vm.recordLogs();
        vm.prank(EXECUTOR);
        (bool success,) = address(dvp).call(abi.encodeCall(dvp.settle, (params)));
        assertFalse(success);
        _assertNoSettlementEvent(vm.getRecordedLogs());
        SettlementMutationState memory afterState = _settlementMutationState(params);
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
    }

    function _settlementMutationState(SettlementParams memory params)
        private
        view
        returns (SettlementMutationState memory state)
    {
        state.successfulCount = successfulSettlements;
        state.quoteUsed = dvp.usedQuoteHash(params.tradeIntent.quoteHash);
        state.snapshotUsed = dvp.usedSnapshotHash(params.tradeIntent.snapshotHash);
        state.tradeUsed = dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash);
        state.makerNonce =
            dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);
        state.requesterNonce =
            dvp.getNonceStatus(params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
        state.senderEligibility = _senderEligibility();
        state.receiverEligibility = _receiverEligibility();
        state.assetSeller = assetToken.balanceOf(params.snapshot.seller);
        state.assetBuyer = assetToken.balanceOf(params.snapshot.buyer);
        state.cashBuyer = settlementToken.balanceOf(params.snapshot.buyer);
        state.cashSeller = settlementToken.balanceOf(params.snapshot.seller);
        state.cashCollector = settlementToken.balanceOf(params.snapshot.collector);
        state.dvpAsset = assetToken.balanceOf(address(dvp));
        state.dvpCash = settlementToken.balanceOf(address(dvp));
    }

    function _freshParams(uint256 index) private view returns (SettlementParams memory params) {
        params = baseParams;
        uint256 identity = index + 1;
        params.firmQuote.rfqIdHash = keccak256(abi.encode("invariant-rfq", identity));
        params.firmQuote.quoteIdHash = keccak256(abi.encode("invariant-quote", identity));
        params.firmQuote.quoteNonce = identity;
        params.tradeIntent.tradeIdHash = keccak256(abi.encode("invariant-trade", identity));
        params.firmQuote.tradeIdHash = params.tradeIntent.tradeIdHash;
        params.tradeIntent.tradeNonce = identity;
        params.snapshot.tradeIdHash = params.tradeIntent.tradeIdHash;
        params.snapshot.makerQuoteNonce = identity;
        params.snapshot.requesterTradeNonce = identity;
        _resignFresh(params);
    }

    function _resignFresh(SettlementParams memory params) private view {
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.snapshotHash = snapshotHash;
        (uint8 makerV, bytes32 makerR, bytes32 makerS) = vm.sign(MAKER_KEY, quoteDigest);
        params.quotingMakerSignature = abi.encodePacked(makerR, makerS, makerV);
        bytes32 tradeDigest = HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent);
        (uint8 requesterV, bytes32 requesterR, bytes32 requesterS) = vm.sign(REQUESTER_KEY, tradeDigest);
        params.requesterSignature = abi.encodePacked(requesterR, requesterS, requesterV);
    }

    function _recordSuccessfulIdentities(SettlementParams memory params) private {
        bytes32 makerNonceKey = keccak256(abi.encode(params.firmQuote.quotingMaker, params.firmQuote.quoteNonce));
        bytes32 requesterNonceKey = keccak256(abi.encode(params.tradeIntent.requester, params.tradeIntent.tradeNonce));
        if (
            ++quoteSuccessCount[params.tradeIntent.quoteHash] > 1
                || ++snapshotSuccessCount[params.tradeIntent.snapshotHash] > 1
                || ++tradeSuccessCount[params.tradeIntent.tradeIdHash] > 1
                || ++makerNonceSuccessCount[makerNonceKey] > 1 || ++requesterNonceSuccessCount[requesterNonceKey] > 1
        ) successfulIdentityCollision = true;
    }

    function _recordSettlementEvent(Vm.Log[] memory logs, SettlementParams memory params) private {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(dvp) && logs[i].topics.length == 4
                    && logs[i].topics[0] == SETTLEMENT_EXECUTED_TOPIC
            ) {
                ++found;
                assertEq(logs[i].topics[1], params.tradeIntent.tradeIdHash);
                assertEq(logs[i].topics[2], params.tradeIntent.snapshotHash);
                assertEq(logs[i].topics[3], params.snapshot.assetVersionId);
                uint256 eventQuantity;
                bytes memory data = logs[i].data;
                assembly ("memory-safe") {
                    eventQuantity := mload(add(data, 0x160))
                }
                assertEq(eventQuantity, params.snapshot.executedQuantity);
                settlementEventQuantity += eventQuantity;
            }
        }
        assertEq(found, 1);
        settlementEventCount += found;
    }

    function _assertNoSettlementEvent(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0
                    || (logs[i].topics[0] != SETTLEMENT_EXECUTED_TOPIC && logs[i].topics[0] != FEE_COLLECTED_TOPIC)
            );
        }
    }

    function _senderEligibility() private view returns (EligibilityRecord memory) {
        return eligibilityRegistry.getEligibility(_eligibilityKey(baseParams.snapshot.seller));
    }

    function _receiverEligibility() private view returns (EligibilityRecord memory) {
        return eligibilityRegistry.getEligibility(_eligibilityKey(baseParams.snapshot.buyer));
    }

    function _eligibilityKey(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, baseParams.snapshot.assetVersionId));
    }

    function _assertEligibilityEqual(EligibilityRecord memory expected, EligibilityRecord memory actual) private pure {
        assertEq(actual.recordVersion, expected.recordVersion);
        assertEq(actual.paused, expected.paused);
    }

    function _tradeIndex(SettlementParams memory params) private pure returns (uint256) {
        return params.firmQuote.quoteNonce - 1;
    }
}

contract DvPBalanceInvariantTest is DeployFixture {
    uint256 private constant INITIAL_ASSET_SELLER = 1_000 ether;
    uint256 private constant INITIAL_ASSET_BUYER = 0;
    uint256 private constant INITIAL_CASH_BUYER = 2_000_000_000;
    uint256 private constant INITIAL_CASH_SELLER = 0;
    uint256 private constant INITIAL_CASH_COLLECTOR = 0;
    uint256 private constant INITIAL_DVP_ASSET = 7 ether;
    uint256 private constant INITIAL_DVP_CASH = 9_999;

    DvPSettlementStateHandler private handler;
    SettlementParams private baseParams;
    bytes32 private senderEligibilityKey;
    bytes32 private receiverEligibilityKey;

    function setUp() public override {
        super.setUp();
        baseParams = _validPreCheckParams();
        assetToken.setBalance(baseParams.snapshot.seller, INITIAL_ASSET_SELLER);
        assetToken.setBalance(baseParams.snapshot.buyer, INITIAL_ASSET_BUYER);
        assetToken.setBalance(address(dvp), INITIAL_DVP_ASSET);
        assetToken.setAllowance(baseParams.snapshot.seller, address(dvp), INITIAL_ASSET_SELLER);
        settlementToken.setBalance(baseParams.snapshot.buyer, INITIAL_CASH_BUYER);
        settlementToken.setBalance(baseParams.snapshot.seller, INITIAL_CASH_SELLER);
        settlementToken.setBalance(baseParams.snapshot.collector, INITIAL_CASH_COLLECTOR);
        settlementToken.setBalance(address(dvp), INITIAL_DVP_CASH);
        settlementToken.setAllowance(baseParams.snapshot.buyer, address(dvp), INITIAL_CASH_BUYER);

        senderEligibilityKey =
            keccak256(abi.encode(block.chainid, baseParams.snapshot.seller, assetVersionConfig.assetVersionId));
        receiverEligibilityKey =
            keccak256(abi.encode(block.chainid, baseParams.snapshot.buyer, assetVersionConfig.assetVersionId));

        handler = new DvPSettlementStateHandler(
            dvp, eligibilityRegistry, assetToken, settlementToken, baseParams, address(timelock)
        );
        handler.settle(0);
        handler.externalUnknown(0);
        targetContract(address(handler));
    }

    function invariantSuccessfulSettlementAggregateDeltasAreConserved() public view {
        uint256 quantity = handler.successfulExecutedQuantity();
        uint256 buyerDebit = handler.successfulBuyerDebit();
        uint256 sellerCredit = handler.successfulSellerCredit();
        uint256 collectorCredit = handler.successfulCollectorCredit();

        assertEq(assetToken.balanceOf(baseParams.snapshot.seller), INITIAL_ASSET_SELLER - quantity);
        assertEq(assetToken.balanceOf(baseParams.snapshot.buyer), INITIAL_ASSET_BUYER + quantity);
        assertEq(
            assetToken.balanceOf(baseParams.snapshot.seller) + assetToken.balanceOf(baseParams.snapshot.buyer),
            INITIAL_ASSET_SELLER + INITIAL_ASSET_BUYER
        );
        assertEq(settlementToken.balanceOf(baseParams.snapshot.buyer), INITIAL_CASH_BUYER - buyerDebit);
        assertEq(settlementToken.balanceOf(baseParams.snapshot.seller), INITIAL_CASH_SELLER + sellerCredit);
        assertEq(settlementToken.balanceOf(baseParams.snapshot.collector), INITIAL_CASH_COLLECTOR + collectorCredit);
        assertEq(buyerDebit, sellerCredit + collectorCredit);
        assertEq(
            settlementToken.balanceOf(baseParams.snapshot.buyer) + settlementToken.balanceOf(baseParams.snapshot.seller)
                + settlementToken.balanceOf(baseParams.snapshot.collector),
            INITIAL_CASH_BUYER + INITIAL_CASH_SELLER + INITIAL_CASH_COLLECTOR
        );
    }

    function invariantDvpNetTokenBalancesNeverChange() public view {
        assertEq(assetToken.balanceOf(address(dvp)), INITIAL_DVP_ASSET);
        assertEq(settlementToken.balanceOf(address(dvp)), INITIAL_DVP_CASH);
    }

    function invariantIdentifiersAndBothNonceTypesSucceedAtMostOnce() public view {
        assertFalse(handler.successfulIdentityCollision());
        uint256 count = handler.successfulTradeIndexCount();
        for (uint256 i; i < count; ++i) {
            SettlementParams memory params = handler.paramsForSuccessfulIndex(i);
            assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
            assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
            assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
            assertEq(
                uint8(
                    dvp.getNonceStatus(
                        params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce
                    )
                ),
                uint8(NonceStatus.USED)
            );
            assertEq(
                uint8(
                    dvp.getNonceStatus(
                        params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                    )
                ),
                uint8(NonceStatus.USED)
            );
        }
    }

    function invariantEligibilityIsNotConsumedAndSettlementEventsAreBacked() public view {
        EligibilityRecord memory sender = eligibilityRegistry.getEligibility(senderEligibilityKey);
        EligibilityRecord memory receiver = eligibilityRegistry.getEligibility(receiverEligibilityKey);
        uint256 quantity = handler.successfulExecutedQuantity();
        uint256 successes = handler.successfulSettlements();

        assertEq(sender.recordVersion, 1);
        assertEq(receiver.recordVersion, 1);
        assertEq(handler.settlementEventCount(), successes);
        assertEq(handler.settlementEventQuantity(), quantity);
    }

    function invariantExternalUnknownWasActuallyReachedWithoutConsumption() public view {
        assertGt(handler.externalUnknownHits(), 0);
    }
}
