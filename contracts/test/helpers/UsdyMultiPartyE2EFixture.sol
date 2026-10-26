// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    Decision,
    NonceStatus,
    NonceType,
    ParticipantInput,
    ParticipantType,
    PermitCapability,
    RequesterSide,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {OfficialUsdyBehaviorMock} from "test/fixtures/OfficialUsdyBehaviorMock.sol";
import {IntegrationUpgradeableUsdyToken} from "test/fixtures/IntegrationTokens.sol";
import {UsdySettlementFixture} from "./UsdySettlementFixture.sol";

abstract contract UsdyMultiPartyE2EFixture is UsdySettlementFixture {
    uint256 internal constant MAKER2_KEY = 0xC0FFEE;
    uint256 internal constant INVESTOR2_KEY = 0xD00D;
    uint256 internal constant INITIAL_SETTLEMENT = 100_000_000;
    uint256 internal constant CASH_PRINCIPAL = 11_400_000;

    address internal maker1;
    address internal maker2;
    address internal investor1;
    address internal investor2;

    function _newUsdyImplementation() internal override returns (IntegrationUpgradeableUsdyToken) {
        return new OfficialUsdyBehaviorMock();
    }

    function _usdyPermitCapability() internal pure override returns (PermitCapability) {
        return PermitCapability.UNSUPPORTED;
    }

    function _fundUsdyBuy() internal override {}

    function setUp() public virtual override {
        super.setUp();
        maker1 = vm.addr(MAKER_KEY);
        maker2 = vm.addr(MAKER2_KEY);
        investor1 = vm.addr(REQUESTER_KEY);
        investor2 = vm.addr(INVESTOR2_KEY);
        _registerExtraParticipants();
        _allowExtraUsdyAccounts();
        _activateExtraEligibility();
        _fundAllParties();
    }

    function _registerExtraParticipants() private {
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: maker2,
                participantIdHash: bytes32(uint256(0xA003)),
                participantType: ParticipantType.MAKER,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: investor2,
                participantIdHash: bytes32(uint256(0xA004)),
                participantType: ParticipantType.INVESTOR,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _allowExtraUsdyAccounts() private {
        usdyAllowlist.setAllowed(maker2, true);
        usdyAllowlist.setAllowed(investor2, true);
    }

    function _activateExtraEligibility() private {
        _setUsdyEligibility(maker2);
        _setUsdyEligibility(investor2);
    }

    function _fundAllParties() private {
        OfficialUsdyBehaviorMock usdy = OfficialUsdyBehaviorMock(address(usdyToken));
        usdy.mint(maker1, 100 ether);
        usdy.mint(maker2, 100 ether);
        usdy.mint(investor2, 20 ether);

        settlementToken.setBalance(maker1, INITIAL_SETTLEMENT);
        settlementToken.setBalance(maker2, INITIAL_SETTLEMENT);
        settlementToken.setBalance(investor1, INITIAL_SETTLEMENT);
        settlementToken.setBalance(investor2, INITIAL_SETTLEMENT);

        vm.prank(maker1);
        usdyToken.approve(address(dvp), 100 ether);
        vm.prank(maker2);
        usdyToken.approve(address(dvp), 100 ether);
        vm.prank(investor2);
        usdyToken.approve(address(dvp), 20 ether);

        settlementToken.setAllowance(maker1, address(dvp), INITIAL_SETTLEMENT);
        settlementToken.setAllowance(maker2, address(dvp), INITIAL_SETTLEMENT);
        settlementToken.setAllowance(investor1, address(dvp), INITIAL_SETTLEMENT);
        settlementToken.setAllowance(investor2, address(dvp), INITIAL_SETTLEMENT);
    }

    function _buildTrade(
        uint256 quotingMakerKey,
        uint256 requesterKey,
        ParticipantType requesterType,
        RequesterSide side,
        uint256 sequence
    ) internal view returns (SettlementParams memory params) {
        params = _validUsdyBuyParams();
        address quotingMaker = vm.addr(quotingMakerKey);
        address requester = vm.addr(requesterKey);

        params.firmQuote.rfqIdHash = bytes32(uint256(params.firmQuote.rfqIdHash) + sequence);
        params.firmQuote.quoteIdHash = bytes32(uint256(params.firmQuote.quoteIdHash) + sequence);
        params.firmQuote.quoteNonce = params.firmQuote.quoteNonce + sequence;
        params.firmQuote.quotingMaker = quotingMaker;
        params.firmQuote.requester = requester;
        params.firmQuote.requesterType = requesterType;
        params.firmQuote.requesterSide = side;

        params.tradeIntent.tradeIdHash = bytes32(uint256(params.tradeIntent.tradeIdHash) + sequence);
        params.firmQuote.tradeIdHash = params.tradeIntent.tradeIdHash;
        params.tradeIntent.tradeNonce = params.tradeIntent.tradeNonce + sequence;
        params.tradeIntent.quotingMaker = quotingMaker;
        params.tradeIntent.requester = requester;
        params.tradeIntent.requesterType = requesterType;
        params.tradeIntent.requesterSide = side;

        params.snapshot.tradeIdHash = params.tradeIntent.tradeIdHash;
        params.snapshot.makerQuoteNonce = params.firmQuote.quoteNonce;
        params.snapshot.requesterTradeNonce = params.tradeIntent.tradeNonce;
        params.snapshot.quotingMaker = quotingMaker;
        params.snapshot.requester = requester;
        params.snapshot.requesterType = requesterType;
        params.snapshot.requesterSide = side;

        if (side == RequesterSide.BUY) {
            params.tradeIntent.buyer = requester;
            params.snapshot.buyer = requester;
            params.tradeIntent.seller = quotingMaker;
            params.snapshot.seller = quotingMaker;
        } else {
            params.tradeIntent.buyer = quotingMaker;
            params.snapshot.buyer = quotingMaker;
            params.tradeIntent.seller = requester;
            params.snapshot.seller = requester;
        }
        _applyIdentityFeeAmounts(params, usdyFeeConfig);

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.quotingMakerSignature = _signWith(quotingMakerKey, quoteDigest);
        params.requesterSignature =
            _signWith(requesterKey, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
    }

    function _signWith(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    struct ObservableState {
        uint256 maker1Asset;
        uint256 maker2Asset;
        uint256 investor1Asset;
        uint256 investor2Asset;
        uint256 dvpAsset;
        uint256 maker1Settlement;
        uint256 maker2Settlement;
        uint256 investor1Settlement;
        uint256 investor2Settlement;
        uint256 collectorSettlement;
        uint256 dvpSettlement;
        uint256 maker1AssetAllowance;
        uint256 maker2AssetAllowance;
        uint256 investor2AssetAllowance;
        uint256 maker1SettlementAllowance;
        uint256 maker2SettlementAllowance;
        uint256 investor1SettlementAllowance;
        uint256 investor2SettlementAllowance;
    }

    function _observe() internal view returns (ObservableState memory state) {
        state.maker1Asset = usdyToken.balanceOf(maker1);
        state.maker2Asset = usdyToken.balanceOf(maker2);
        state.investor1Asset = usdyToken.balanceOf(investor1);
        state.investor2Asset = usdyToken.balanceOf(investor2);
        state.dvpAsset = usdyToken.balanceOf(address(dvp));
        state.maker1Settlement = settlementToken.balanceOf(maker1);
        state.maker2Settlement = settlementToken.balanceOf(maker2);
        state.investor1Settlement = settlementToken.balanceOf(investor1);
        state.investor2Settlement = settlementToken.balanceOf(investor2);
        state.collectorSettlement = settlementToken.balanceOf(COLLECTOR);
        state.dvpSettlement = settlementToken.balanceOf(address(dvp));
        state.maker1AssetAllowance = usdyToken.allowance(maker1, address(dvp));
        state.maker2AssetAllowance = usdyToken.allowance(maker2, address(dvp));
        state.investor2AssetAllowance = usdyToken.allowance(investor2, address(dvp));
        state.maker1SettlementAllowance = settlementToken.allowance(maker1, address(dvp));
        state.maker2SettlementAllowance = settlementToken.allowance(maker2, address(dvp));
        state.investor1SettlementAllowance = settlementToken.allowance(investor1, address(dvp));
        state.investor2SettlementAllowance = settlementToken.allowance(investor2, address(dvp));
    }

    function _assertPreCheckPass(SettlementParams memory params) internal view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
    }

    function _assertPreCheckBlock(SettlementParams memory params, bytes4 expectedReason) internal view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, expectedReason);
    }

    function _assertUnchanged(ObservableState memory beforeState) internal view {
        ObservableState memory afterState = _observe();
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
    }

    function _assertUnused(SettlementParams memory params) internal view {
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
    }

    function _assertConsumed(SettlementParams memory params) internal view {
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
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
