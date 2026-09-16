// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {IDvPSignedPayloadValidator} from "src/interfaces/IDvPSignedPayloadValidator.sol";
import {IDvPCurrentStateValidator} from "src/interfaces/IDvPCurrentStateValidator.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    Decision,
    EligibilityRecord,
    NonceStatus,
    NonceType,
    ParticipantInput,
    ParticipantType,
    PermitData,
    SettlementParams,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract PostTransferViewFailureInjector is Test {
    function inject(address target, bytes calldata callData) external {
        vm.mockCallRevert(target, callData, bytes("POST_TRANSFER_VIEW_FAILURE"));
    }
}

contract FailureInjection1271Wallet is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }
}

contract DvPFailureInjectionTest is UsdySettlementFixture {
    bytes32 private constant SETTLEMENT_EXECUTED_TOPIC = IDvPSettlement.SettlementExecuted.selector;
    bytes32 private constant FEE_COLLECTED_TOPIC = 0xbc3cb3ef76421eeef50f0a68e293ddd9c094e8a104394fe59ca13c21c9ef778b;
    bytes4 private constant ALLOWANCE_SELECTOR = 0xdd62ed3e;
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;
    bytes4 private constant DECIMALS_SELECTOR = 0x313ce567;
    bytes4 private constant PERMIT_SELECTOR = 0xd505accf;
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd;

    address private signedPayloadValidator;
    address private currentStateValidator;
    PostTransferViewFailureInjector private postTransferInjector;

    struct AtomicSnapshot {
        bool quoteUsed;
        bool snapshotUsed;
        bool tradeUsed;
        NonceStatus makerNonce;
        NonceStatus requesterNonce;
        EligibilityRecord senderEligibility;
        EligibilityRecord receiverEligibility;
        uint256 assetSeller;
        uint256 assetBuyer;
        uint256 assetDvp;
        uint256 cashBuyer;
        uint256 cashSeller;
        uint256 cashCollector;
        uint256 cashDvp;
        uint256 assetAllowance;
        uint256 cashAllowance;
    }

    function setUp() public override {
        super.setUp();

        address currentStateValidatorFactory = coreDeployment.currentStateValidatorFactory;
        assertEq(address(dvp), coreDeployment.dvp);
        signedPayloadValidator = vm.computeCreateAddress(address(dvp), 1);
        assertGt(vm.computeCreateAddress(currentStateValidatorFactory, 1).code.length, 0);
        assertGt(vm.computeCreateAddress(currentStateValidatorFactory, 2).code.length, 0);
        currentStateValidator = vm.computeCreateAddress(currentStateValidatorFactory, 3);
        assertGt(signedPayloadValidator.code.length, 0);
        assertGt(currentStateValidator.code.length, 0);
        postTransferInjector = new PostTransferViewFailureInjector();
    }

    function testInjectedValidatorAndRegistryFailuresRollBackAtomically() public {
        SettlementParams memory params = _validUsdyBuyParams();

        _inject(
            signedPayloadValidator, abi.encodeCall(IDvPSignedPayloadValidator.validateForSettlement, (params)), params
        );
        _inject(
            currentStateValidator, abi.encodeCall(IDvPCurrentStateValidator.validateForSettlement, (params)), params
        );
        _inject(address(dvp), abi.encodeWithSignature("domainSeparatorV4()"), params);
        _inject(
            address(dvp),
            abi.encodeWithSignature(
                "getNonceStatus(address,uint8,uint256)",
                params.firmQuote.quotingMaker,
                uint8(NonceType.MAKER_QUOTE),
                params.firmQuote.quoteNonce
            ),
            params
        );
        _inject(
            address(dvp),
            abi.encodeWithSignature(
                "getNonceStatus(address,uint8,uint256)",
                params.tradeIntent.requester,
                uint8(NonceType.REQUESTER_TRADE),
                params.tradeIntent.tradeNonce
            ),
            params
        );
        _inject(address(dvp), abi.encodeWithSignature("participantRegistry()"), params);
        _inject(address(dvp), abi.encodeWithSignature("assetVersionRegistry()"), params);
        _inject(address(dvp), abi.encodeWithSignature("settlementTokenRegistry()"), params);
        _inject(address(dvp), abi.encodeWithSignature("adapterRegistry()"), params);
        _inject(address(dvp), abi.encodeWithSignature("principalCalculatorRegistry()"), params);
        _inject(address(dvp), abi.encodeWithSignature("feeRegistry()"), params);
        _inject(
            address(participantRegistry),
            abi.encodeCall(IParticipantRegistry.getParticipant, (params.firmQuote.quotingMaker)),
            params
        );
        _inject(
            address(participantRegistry),
            abi.encodeCall(IParticipantRegistry.getParticipant, (params.firmQuote.requester)),
            params
        );
        _inject(
            address(assetVersionRegistry),
            abi.encodeCall(IAssetVersionRegistry.getAssetVersion, (params.snapshot.assetVersionId)),
            params
        );
        _inject(
            address(settlementTokenRegistry),
            abi.encodeCall(ISettlementTokenRegistry.getSettlementToken, (params.snapshot.settlementTokenConfigId)),
            params
        );
        _inject(
            address(adapterRegistry),
            abi.encodeCall(IAdapterRegistry.getAdapter, (params.snapshot.adapterConfigId)),
            params
        );
        _inject(
            address(adapterRegistry),
            abi.encodeCall(IAdapterRegistry.getAdapter, (settlementTokenConfig.adapterConfigId)),
            params
        );
        _inject(
            address(calculatorRegistry),
            abi.encodeCall(
                IPrincipalCalculatorRegistry.getPrincipalCalculator, (params.snapshot.principalCalculatorConfigId)
            ),
            params
        );
        _inject(
            address(feeRegistry),
            abi.encodeCall(IFeeRegistry.getFeePolicyEpoch, (params.snapshot.feePolicyEpoch)),
            params
        );
        _inject(
            address(feeRegistry), abi.encodeCall(IFeeRegistry.getFeeVersion, (params.snapshot.feeVersionId)), params
        );
        _inject(
            address(feeRegistry),
            abi.encodeCall(
                IFeeRegistry.resolveApplicableFee, (params.snapshot.feePolicyEpoch, params.snapshot.assetVersionId)
            ),
            params
        );
    }

    function testInjectedPreCheckUnknownDoesNotConsumeAnySettlementState() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AtomicSnapshot memory beforeState = _snapshot(params);
        vm.mockCallRevert(
            address(assetVersionRegistry),
            abi.encodeCall(IAssetVersionRegistry.getAssetVersion, (params.snapshot.assetVersionId)),
            bytes("UNKNOWN_PRECHECK_STAGE")
        );

        vm.recordLogs();
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(vm.getRecordedLogs().length, 0);
        vm.clearMockedCalls();

        assertEq(keccak256(abi.encode(_snapshot(params))), keccak256(abi.encode(beforeState)));
    }

    function testInjectedEip1271SignatureStageRollsBackAtomically() public {
        FailureInjection1271Wallet wallet = new FailureInjection1271Wallet();
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: address(wallet),
                participantIdHash: bytes32(uint256(0x1271)),
                participantType: ParticipantType.INVESTOR,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
        usdyAllowlist.setAllowed(address(wallet), true);
        _setUsdyEligibility(address(wallet));

        SettlementParams memory params = _validUsdyBuyParams();
        params.firmQuote.requester = address(wallet);
        params.tradeIntent.requester = address(wallet);
        params.snapshot.requester = address(wallet);
        params.tradeIntent.buyer = address(wallet);
        params.snapshot.buyer = address(wallet);
        settlementToken.setBalance(address(wallet), 100_000_000);
        settlementToken.setAllowance(address(wallet), address(dvp), params.snapshot.buyerDebit);

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_KEY, quoteDigest);
        params.quotingMakerSignature = abi.encodePacked(r, s, v);
        params.requesterSignature = hex"1271cafe";
        bytes32 requesterDigest = HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent);

        _inject(
            address(wallet),
            abi.encodeCall(IERC1271.isValidSignature, (requesterDigest, params.requesterSignature)),
            params
        );
    }

    function testInjectedMetadataCalculatorAndAdapterFailuresRollBackAtomically() public {
        SettlementParams memory params = _validUsdyBuyParams();
        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);

        _inject(address(usdyToken), abi.encodeWithSelector(DECIMALS_SELECTOR), params);
        _inject(address(settlementToken), abi.encodeWithSelector(DECIMALS_SELECTOR), params);
        _inject(
            address(fundCalculator),
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            params
        );
        _inject(
            address(usdyAdapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    params.snapshot.assetToken,
                    params.snapshot.seller,
                    params.snapshot.buyer,
                    params.snapshot.executedQuantity,
                    TransferLeg.ASSET,
                    snapshotHash
                )
            ),
            params
        );
        _inject(
            address(unrestrictedAdapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    params.snapshot.settlementToken,
                    params.snapshot.buyer,
                    params.snapshot.seller,
                    params.snapshot.sellerCredit,
                    TransferLeg.SETTLEMENT_TO_SELLER,
                    snapshotHash
                )
            ),
            params
        );
        _inject(
            address(unrestrictedAdapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    params.snapshot.settlementToken,
                    params.snapshot.buyer,
                    params.snapshot.collector,
                    params.snapshot.collectorCredit,
                    TransferLeg.SETTLEMENT_TO_COLLECTOR,
                    snapshotHash
                )
            ),
            params
        );
    }

    function testInjectedWriteReadAndTransferFailuresRollBackAtomically() public {
        SettlementParams memory params = _validUsdyBuyParams();

        _inject(
            address(usdyToken), abi.encodeWithSelector(ALLOWANCE_SELECTOR, params.snapshot.seller, address(dvp)), params
        );
        _inject(
            address(settlementToken),
            abi.encodeWithSelector(ALLOWANCE_SELECTOR, params.snapshot.buyer, address(dvp)),
            params
        );

        _injectPreTransferBalanceReads(params);

        _inject(
            address(usdyToken),
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR, params.snapshot.seller, params.snapshot.buyer, params.snapshot.executedQuantity
            ),
            params
        );
        _inject(
            address(settlementToken),
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR, params.snapshot.buyer, params.snapshot.seller, params.snapshot.sellerCredit
            ),
            params
        );
        _inject(
            address(settlementToken),
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR,
                params.snapshot.buyer,
                params.snapshot.collector,
                params.snapshot.collectorCredit
            ),
            params
        );
    }

    function testInjectedPostTransferBalanceReadFailuresRollBackTransfersAndWrites() public {
        SettlementParams memory params = _validUsdyBuyParams();

        _injectPostTransferRead(
            address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.seller), params
        );
        _injectPostTransferRead(
            address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.buyer), params
        );
        _injectPostTransferRead(address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, address(dvp)), params);
        _injectPostTransferRead(
            address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.buyer), params
        );
        _injectPostTransferRead(
            address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.seller), params
        );
        _injectPostTransferRead(
            address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.collector), params
        );
        _injectPostTransferRead(
            address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, address(dvp)), params
        );
    }

    function testPermitFailuresAndSuccessfulPermitsBeforeLaterFailureAreAtomic() public {
        SettlementParams memory assetPermitParams = _validUsdyBuyParams();
        usdyToken.setAllowance(assetPermitParams.snapshot.seller, address(dvp), 0);
        assetPermitParams.assetPermit = _permit(
            assetPermitParams.snapshot.assetToken,
            assetPermitParams.snapshot.seller,
            assetPermitParams.snapshot.executedQuantity,
            assetPermitParams.snapshot.tradeDeadline
        );
        _inject(
            address(usdyToken),
            abi.encodeWithSelector(
                PERMIT_SELECTOR,
                assetPermitParams.assetPermit.owner,
                address(dvp),
                assetPermitParams.assetPermit.value,
                assetPermitParams.assetPermit.deadline,
                assetPermitParams.assetPermit.v,
                assetPermitParams.assetPermit.r,
                assetPermitParams.assetPermit.s
            ),
            assetPermitParams
        );
        usdyToken.setAllowance(assetPermitParams.snapshot.seller, address(dvp), 10 ether);

        SettlementParams memory cashPermitParams = _validUsdyBuyParams();
        settlementToken.setAllowance(cashPermitParams.snapshot.buyer, address(dvp), 0);
        cashPermitParams.settlementPermit = _permit(
            cashPermitParams.snapshot.settlementToken,
            cashPermitParams.snapshot.buyer,
            cashPermitParams.snapshot.buyerDebit,
            cashPermitParams.snapshot.tradeDeadline
        );
        _inject(
            address(settlementToken),
            abi.encodeWithSelector(
                PERMIT_SELECTOR,
                cashPermitParams.settlementPermit.owner,
                address(dvp),
                cashPermitParams.settlementPermit.value,
                cashPermitParams.settlementPermit.deadline,
                cashPermitParams.settlementPermit.v,
                cashPermitParams.settlementPermit.r,
                cashPermitParams.settlementPermit.s
            ),
            cashPermitParams
        );

        vm.mockCallRevert(
            address(usdyToken),
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR,
                cashPermitParams.snapshot.seller,
                cashPermitParams.snapshot.buyer,
                cashPermitParams.snapshot.executedQuantity
            ),
            bytes("LATER_TRANSFER_FAILURE")
        );
        _assertAtomicRevert(cashPermitParams);
        assertEq(
            settlementToken.allowance(cashPermitParams.snapshot.buyer, address(dvp)),
            0,
            "successful permit allowance must roll back"
        );
        vm.clearMockedCalls();

        usdyToken.setAllowance(cashPermitParams.snapshot.seller, address(dvp), 0);
        cashPermitParams.assetPermit = _permit(
            cashPermitParams.snapshot.assetToken,
            cashPermitParams.snapshot.seller,
            cashPermitParams.snapshot.executedQuantity,
            cashPermitParams.snapshot.tradeDeadline
        );
        vm.mockCallRevert(
            address(usdyToken),
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR,
                cashPermitParams.snapshot.seller,
                cashPermitParams.snapshot.buyer,
                cashPermitParams.snapshot.executedQuantity
            ),
            bytes("LATER_TRANSFER_FAILURE")
        );
        _assertAtomicRevert(cashPermitParams);
        assertEq(
            usdyToken.allowance(cashPermitParams.snapshot.seller, address(dvp)),
            0,
            "successful asset permit allowance must roll back"
        );
        assertEq(
            settlementToken.allowance(cashPermitParams.snapshot.buyer, address(dvp)),
            0,
            "successful settlement permit allowance must roll back"
        );
        vm.clearMockedCalls();
    }

    function _injectPreTransferBalanceReads(SettlementParams memory params) private {
        _inject(address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.seller), params);
        _inject(address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.buyer), params);
        _inject(address(usdyToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, address(dvp)), params);
        _inject(address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.buyer), params);
        _inject(address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.seller), params);
        _inject(
            address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, params.snapshot.collector), params
        );
        _inject(address(settlementToken), abi.encodeWithSelector(BALANCE_OF_SELECTOR, address(dvp)), params);
    }

    function _inject(address target, bytes memory callData, SettlementParams memory params) private {
        AtomicSnapshot memory beforeState = _snapshot(params);
        vm.mockCallRevert(target, callData, bytes("INJECTED_EXTERNAL_FAILURE"));
        _assertAtomicRevertFrom(params, beforeState);
        vm.clearMockedCalls();
    }

    function _injectPostTransferRead(address target, bytes memory callData, SettlementParams memory params) private {
        settlementToken.configureCallback(
            address(postTransferInjector), abi.encodeCall(PostTransferViewFailureInjector.inject, (target, callData))
        );
        _assertAtomicRevert(params);
        settlementToken.configureCallback(address(0), bytes(""));
        vm.clearMockedCalls();
    }

    function _assertAtomicRevert(SettlementParams memory params) private {
        AtomicSnapshot memory beforeState = _snapshot(params);
        _assertAtomicRevertFrom(params, beforeState);
    }

    function _assertAtomicRevertFrom(SettlementParams memory params, AtomicSnapshot memory beforeState) private {
        vm.recordLogs();
        vm.expectRevert();
        vm.prank(EXECUTOR);
        dvp.settle(params);
        _assertNoTerminalSettlementLogs(vm.getRecordedLogs());
        vm.clearMockedCalls();
        AtomicSnapshot memory afterState = _snapshot(params);
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)), "atomic state changed");
    }

    function _assertNoTerminalSettlementLogs(Vm.Log[] memory logs) private pure {
        // recordLogs observes LOG opcodes even in a reverted subcall. The EVM discards
        // all of them; additionally prove execution never reached either terminal event.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != SETTLEMENT_EXECUTED_TOPIC);
            assertTrue(logs[i].topics[0] != FEE_COLLECTED_TOPIC);
        }
    }

    function _snapshot(SettlementParams memory params) private view returns (AtomicSnapshot memory state) {
        state.quoteUsed = dvp.usedQuoteHash(params.tradeIntent.quoteHash);
        state.snapshotUsed = dvp.usedSnapshotHash(params.tradeIntent.snapshotHash);
        state.tradeUsed = dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash);
        state.makerNonce =
            dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce);
        state.requesterNonce =
            dvp.getNonceStatus(params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
        state.senderEligibility = eligibilityRegistry.getEligibility(_eligibilityKey(params.snapshot.seller));
        state.receiverEligibility = eligibilityRegistry.getEligibility(_eligibilityKey(params.snapshot.buyer));
        state.assetSeller = usdyToken.balanceOf(params.snapshot.seller);
        state.assetBuyer = usdyToken.balanceOf(params.snapshot.buyer);
        state.assetDvp = usdyToken.balanceOf(address(dvp));
        state.cashBuyer = settlementToken.balanceOf(params.snapshot.buyer);
        state.cashSeller = settlementToken.balanceOf(params.snapshot.seller);
        state.cashCollector = settlementToken.balanceOf(params.snapshot.collector);
        state.cashDvp = settlementToken.balanceOf(address(dvp));
        state.assetAllowance = usdyToken.allowance(params.snapshot.seller, address(dvp));
        state.cashAllowance = settlementToken.allowance(params.snapshot.buyer, address(dvp));
    }

    function _eligibilityKey(address wallet) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, wallet, usdyAssetVersionConfig.assetVersionId));
    }

    function _permit(address token, address owner, uint256 value, uint64 deadline)
        private
        pure
        returns (PermitData memory)
    {
        return PermitData({
            usePermit: true,
            owner: owner,
            token: token,
            value: value,
            deadline: deadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
    }
}
