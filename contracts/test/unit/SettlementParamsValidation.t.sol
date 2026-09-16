// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetClass,
    Decision,
    ParticipantType,
    RequesterSide,
    RoundingMode,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {SettlementParamsValidationHarness} from "test/fixtures/SettlementParamsValidationHarness.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract SettlementParamsValidationTest is DvPTestBase {
    SettlementParamsValidationHarness private harness;

    function setUp() public override {
        super.setUp();
        harness = new SettlementParamsValidationHarness();
    }

    function testInspectAcceptsBuyAndDerivesRequesterAsBuyer() public view {
        (bytes32 invalidField, address buyer, address seller) = harness.inspect(_coherentParams());
        assertEq(invalidField, bytes32(0));
        assertEq(buyer, SchemaFixtures.firmQuote().requester);
        assertEq(seller, SchemaFixtures.firmQuote().quotingMaker);
    }

    function testInspectAcceptsSellAndSwapsDerivedParties() public view {
        SettlementParams memory params = _coherentParams();
        _applySell(params);

        (bytes32 invalidField, address buyer, address seller) = harness.inspect(params);
        assertEq(invalidField, bytes32(0));
        assertEq(buyer, params.firmQuote.quotingMaker);
        assertEq(seller, params.firmQuote.requester);
    }

    function testInspectRejectsMissingRequiredStructure() public view {
        SettlementParams memory params;
        (bytes32 invalidField, address buyer, address seller) = harness.inspect(params);
        assertEq(invalidField, bytes32("required"));
        assertEq(buyer, address(0));
        assertEq(seller, address(0));
        assertFalse(harness.hasRequiredStructure(params));
    }

    function testInspectRejectsNoneRequesterSide() public view {
        SettlementParams memory params = _coherentParams();
        params.firmQuote.requesterSide = RequesterSide.NONE;
        params.tradeIntent.requesterSide = RequesterSide.NONE;
        params.snapshot.requesterSide = RequesterSide.NONE;

        (bytes32 invalidField,,) = harness.inspect(params);
        assertEq(invalidField, bytes32("requesterSide"));
    }

    function testInspectIgnoresHashOnlyAndSignatureFields() public view {
        SettlementParams memory params = _coherentParams();
        params.tradeIntent.quoteHash = bytes32(uint256(0xBAD1));
        params.tradeIntent.snapshotHash = bytes32(uint256(0xBAD2));
        params.snapshot.quoteHash = bytes32(uint256(0xBAD3));
        params.snapshot.createdAt = params.snapshot.createdAt + 1;
        params.snapshot.assetDecimals = 8;
        params.quotingMakerSignature = hex"01";
        params.requesterSignature = hex"02";

        (bytes32 invalidField, address buyer, address seller) = harness.inspect(params);
        assertEq(invalidField, bytes32(0));
        assertEq(buyer, params.firmQuote.requester);
        assertEq(seller, params.firmQuote.quotingMaker);
    }

    function testInspectReportsEachCrossArtifactMismatch() public view {
        _assertInspectField(_withTradeIntentRequester(address(0xBEEF)), bytes32("requester"));
        _assertInspectField(_withTradeIntentRequesterType(ParticipantType.MAKER), bytes32("requesterType"));
        _assertInspectField(_withTradeIntentQuotingMaker(address(0xBEEF)), bytes32("quotingMaker"));
        _assertInspectField(_withTradeIntentRequesterSide(RequesterSide.SELL), bytes32("requesterSide"));
        _assertInspectField(_withTradeIntentBuyer(address(0xBEEF)), bytes32("buyer"));
        _assertInspectField(_withTradeIntentSeller(address(0xBEEF)), bytes32("seller"));
        _assertInspectField(_withTradeIntentAssetVersionId(bytes32(uint256(2))), bytes32("assetVersionId"));
        _assertInspectField(_withTradeIntentAssetToken(address(0xBEEF)), bytes32("assetToken"));
        _assertInspectField(_withTradeIntentSettlementToken(address(0xBEEF)), bytes32("settlementToken"));
        _assertInspectField(_withTradeIntentExecutedQuantity(1), bytes32("executedQuantity"));
        _assertInspectField(_withTradeIntentAssetClass(AssetClass.STOCK), bytes32("assetClass"));
        _assertInspectField(_withTradeIntentPriceTermsHash(bytes32(uint256(2))), bytes32("priceTermsHash"));
        _assertInspectField(_withAppendedTradeIntentPriceData(), bytes32("priceData"));
        _assertInspectField(_withTradeIntentCalculatorId(bytes32(uint256(2))), bytes32("principalCalculatorConfigId"));
        _assertInspectField(
            _withTradeIntentCalculatorHash(bytes32(uint256(2))), bytes32("principalCalculatorConfigHash")
        );
        _assertInspectField(_withTradeIntentAdapterId(bytes32(uint256(2))), bytes32("adapterConfigId"));
        _assertInspectField(_withTradeIntentAdapterHash(bytes32(uint256(2))), bytes32("adapterConfigHash"));
        _assertInspectField(_withTradeIntentSettlementTokenId(bytes32(uint256(2))), bytes32("settlementTokenConfigId"));
        _assertInspectField(
            _withTradeIntentSettlementTokenHash(bytes32(uint256(2))), bytes32("settlementTokenConfigHash")
        );
        _assertInspectField(_withTradeIntentCashPrincipal(1), bytes32("cashPrincipal"));
        _assertInspectField(_withTradeIntentBuyerFee(1), bytes32("buyerFee"));
        _assertInspectField(_withTradeIntentSellerFee(1), bytes32("sellerFee"));
        _assertInspectField(_withTradeIntentBuyerDebit(1), bytes32("buyerDebit"));
        _assertInspectField(_withTradeIntentSellerCredit(1), bytes32("sellerCredit"));
        _assertInspectField(_withTradeIntentCollectorCredit(1), bytes32("collectorCredit"));
        _assertInspectField(_withTradeIntentCollector(address(0xBEEF)), bytes32("collector"));
        _assertInspectField(_withTradeIntentFeePolicyEpoch(1), bytes32("feePolicyEpoch"));
        _assertInspectField(_withTradeIntentFeeVersionId(bytes32(uint256(2))), bytes32("feeVersionId"));
        _assertInspectField(_withTradeIntentMatchedScopeHash(bytes32(uint256(2))), bytes32("matchedScopeHash"));
        _assertInspectField(_withTradeIntentFeeConstraintHash(bytes32(uint256(2))), bytes32("feeConstraintHash"));
        _assertInspectField(_withTradeIntentRoundingMode(RoundingMode.NONE), bytes32("roundingMode"));
        _assertInspectField(_withTradeIntentTradeIdHash(bytes32(uint256(2))), bytes32("tradeIdHash"));
        _assertInspectField(_withTradeIntentTradeNonce(1), bytes32("tradeNonce"));
        _assertInspectField(_withFirmQuoteNonce(1), bytes32("quoteNonce"));
        _assertInspectField(_withSnapshotQuoteExpiresAt(1), bytes32("quoteExpiresAt"));
        _assertInspectField(_withSnapshotTradeDeadline(1), bytes32("tradeDeadline"));
    }

    function testDerivePartiesAcceptsBuyAndSellWithoutRecheckingArtifactEquality() public view {
        SettlementParams memory params = _coherentParams();
        params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, hex"00");

        (bytes32 invalidField, address buyer, address seller) = harness.deriveParties(params);
        assertEq(invalidField, bytes32(0));
        assertEq(buyer, params.firmQuote.requester);
        assertEq(seller, params.firmQuote.quotingMaker);

        (bytes32 inspectField,,) = harness.inspect(params);
        assertEq(inspectField, bytes32("priceData"));

        params = _coherentParams();
        _applySell(params);
        (invalidField, buyer, seller) = harness.deriveParties(params);
        assertEq(invalidField, bytes32(0));
        assertEq(buyer, params.firmQuote.quotingMaker);
        assertEq(seller, params.firmQuote.requester);
    }

    function testDerivePartiesRejectsNoneRequesterSideAndMismatchedParties() public view {
        SettlementParams memory params = _coherentParams();
        params.firmQuote.requesterSide = RequesterSide.NONE;
        (bytes32 invalidField,,) = harness.deriveParties(params);
        assertEq(invalidField, bytes32("requesterSide"));

        params = _coherentParams();
        params.tradeIntent.buyer = params.firmQuote.quotingMaker;
        params.snapshot.buyer = params.firmQuote.quotingMaker;
        (invalidField,,) = harness.deriveParties(params);
        assertEq(invalidField, bytes32("buyer"));
    }

    function testInspectRejectsBuyerSellerThatDoNotMatchDerivedParties() public view {
        SettlementParams memory params = _coherentParams();
        params.tradeIntent.buyer = params.firmQuote.quotingMaker;
        params.snapshot.buyer = params.firmQuote.quotingMaker;
        _assertInspectField(params, bytes32("buyer"));

        params = _coherentParams();
        params.tradeIntent.seller = params.firmQuote.requester;
        params.snapshot.seller = params.firmQuote.requester;
        _assertInspectField(params, bytes32("seller"));
    }

    function testInspectFieldMatchesSettleRevertAndPreCheckBlock() public {
        SettlementParams memory params = _validSignedParams();
        params.tradeIntent.requesterType = ParticipantType.MAKER;
        _assertPublicSeam(params, bytes32("requesterType"));

        params = _validSignedParams();
        params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, hex"00");
        _assertPublicSeam(params, bytes32("priceData"));

        params = _validSignedParams();
        ++params.tradeIntent.cashPrincipal;
        _assertPublicSeam(params, bytes32("cashPrincipal"));

        params = _validSignedParams();
        params.tradeIntent.principalCalculatorConfigHash = bytes32(uint256(0xBAD));
        _assertPublicSeam(params, bytes32("principalCalculatorConfigHash"));

        params = _validSignedParams();
        ++params.tradeIntent.tradeNonce;
        _assertPublicSeam(params, bytes32("tradeNonce"));

        params = _validSignedParams();
        ++params.snapshot.quoteExpiresAt;
        _assertPublicSeam(params, bytes32("quoteExpiresAt"));

        params = _validSignedParams();
        ++params.snapshot.tradeDeadline;
        _assertPublicSeam(params, bytes32("tradeDeadline"));

        params = _validSignedParams();
        params.firmQuote.requesterSide = RequesterSide.NONE;
        params.tradeIntent.requesterSide = RequesterSide.NONE;
        params.snapshot.requesterSide = RequesterSide.NONE;
        _assertPublicSeam(params, bytes32("requesterSide"));
    }

    function _assertPublicSeam(SettlementParams memory params, bytes32 expectedField) private {
        (bytes32 inspectField,,) = harness.inspect(params);
        assertEq(inspectField, expectedField);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, expectedField));
        _settleAsExecutor(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSettlementParams.selector);
    }

    function _assertInspectField(SettlementParams memory params, bytes32 expectedField) private view {
        (bytes32 invalidField,,) = harness.inspect(params);
        assertEq(invalidField, expectedField);
    }

    function _coherentParams() private pure returns (SettlementParams memory params) {
        params.firmQuote = SchemaFixtures.firmQuote();
        params.tradeIntent = SchemaFixtures.tradeIntent();
        params.snapshot = SchemaFixtures.snapshot();
    }

    function _applySell(SettlementParams memory params) private pure {
        params.firmQuote.requesterSide = RequesterSide.SELL;
        params.tradeIntent.requesterSide = RequesterSide.SELL;
        params.snapshot.requesterSide = RequesterSide.SELL;
        params.tradeIntent.buyer = params.firmQuote.quotingMaker;
        params.snapshot.buyer = params.firmQuote.quotingMaker;
        params.tradeIntent.seller = params.firmQuote.requester;
        params.snapshot.seller = params.firmQuote.requester;
    }

    function _withTradeIntentRequester(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.requester = value;
    }

    function _withTradeIntentRequesterType(ParticipantType value)
        private
        pure
        returns (SettlementParams memory params)
    {
        params = _coherentParams();
        params.tradeIntent.requesterType = value;
    }

    function _withTradeIntentQuotingMaker(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.quotingMaker = value;
    }

    function _withTradeIntentRequesterSide(RequesterSide value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.requesterSide = value;
    }

    function _withTradeIntentBuyer(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.buyer = value;
    }

    function _withTradeIntentSeller(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.seller = value;
    }

    function _withTradeIntentAssetVersionId(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.assetVersionId = value;
    }

    function _withTradeIntentAssetToken(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.assetToken = value;
    }

    function _withTradeIntentSettlementToken(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.settlementToken = value;
    }

    function _withTradeIntentExecutedQuantity(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.executedQuantity = value;
    }

    function _withTradeIntentAssetClass(AssetClass value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.assetClass = value;
    }

    function _withTradeIntentPriceTermsHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.priceTermsHash = value;
    }

    function _withAppendedTradeIntentPriceData() private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.priceData = bytes.concat(params.tradeIntent.priceData, hex"00");
    }

    function _withTradeIntentCalculatorId(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.principalCalculatorConfigId = value;
    }

    function _withTradeIntentCalculatorHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.principalCalculatorConfigHash = value;
    }

    function _withTradeIntentAdapterId(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.adapterConfigId = value;
    }

    function _withTradeIntentAdapterHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.adapterConfigHash = value;
    }

    function _withTradeIntentSettlementTokenId(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.settlementTokenConfigId = value;
    }

    function _withTradeIntentSettlementTokenHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.settlementTokenConfigHash = value;
    }

    function _withTradeIntentCashPrincipal(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.cashPrincipal = value;
    }

    function _withTradeIntentBuyerFee(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.buyerFee = value;
    }

    function _withTradeIntentSellerFee(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.sellerFee = value;
    }

    function _withTradeIntentBuyerDebit(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.buyerDebit = value;
    }

    function _withTradeIntentSellerCredit(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.sellerCredit = value;
    }

    function _withTradeIntentCollectorCredit(uint256 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.collectorCredit = value;
    }

    function _withTradeIntentCollector(address value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.collector = value;
    }

    function _withTradeIntentFeePolicyEpoch(uint64 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.feePolicyEpoch = value;
    }

    function _withTradeIntentFeeVersionId(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.feeVersionId = value;
    }

    function _withTradeIntentMatchedScopeHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.matchedScopeHash = value;
    }

    function _withTradeIntentFeeConstraintHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.feeConstraintHash = value;
    }

    function _withTradeIntentRoundingMode(RoundingMode value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.roundingMode = value;
    }

    function _withTradeIntentTradeIdHash(bytes32 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.tradeIdHash = value;
    }

    function _withTradeIntentTradeNonce(uint64 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.tradeIntent.tradeNonce = value;
    }

    function _withFirmQuoteNonce(uint64 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.firmQuote.quoteNonce = value;
    }

    function _withSnapshotQuoteExpiresAt(uint64 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.snapshot.quoteExpiresAt = params.snapshot.quoteExpiresAt + value;
    }

    function _withSnapshotTradeDeadline(uint64 value) private pure returns (SettlementParams memory params) {
        params = _coherentParams();
        params.snapshot.tradeDeadline = params.snapshot.tradeDeadline + value;
    }
}
