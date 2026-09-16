// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ParticipantInput, ParticipantType, RequesterSide, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract MakerToMakerSettlementTest is UsdySettlementFixture {
    uint256 private constant SECOND_MAKER_KEY = 0xC0FFEE;

    function testSameParticipantIdDifferentMakerWalletsSettleBuy() public {
        address secondMaker = _registerSecondMaker();

        SettlementParams memory buyParams = _makerParams(secondMaker, RequesterSide.BUY);
        _settleUsdy(buyParams);
        assertEq(usdyToken.balanceOf(secondMaker), 10 ether);
    }

    function testSameParticipantIdDifferentMakerWalletsSettleSell() public {
        address secondMaker = _registerSecondMaker();
        SettlementParams memory sellParams = _makerParams(secondMaker, RequesterSide.SELL);
        _settleUsdy(sellParams);
        assertEq(usdyToken.balanceOf(secondMaker), 90 ether);
    }

    function testSameMakerWalletIsRejected() public {
        SettlementParams memory params = _validUsdyBuyParams();
        address maker = params.firmQuote.quotingMaker;
        params.firmQuote.requester = maker;
        params.firmQuote.requesterType = ParticipantType.MAKER;
        params.tradeIntent.requester = maker;
        params.tradeIntent.requesterType = ParticipantType.MAKER;
        params.snapshot.requester = maker;
        params.snapshot.requesterType = ParticipantType.MAKER;
        params.tradeIntent.buyer = maker;
        params.snapshot.buyer = maker;
        _signParams(params, MAKER_KEY);

        vm.expectPartialRevert(HTPErrors.InvalidSettlementParams.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function _registerSecondMaker() private returns (address secondMaker) {
        secondMaker = vm.addr(SECOND_MAKER_KEY);
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: secondMaker,
                participantIdHash: bytes32(uint256(0xA001)),
                participantType: ParticipantType.MAKER,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
        usdyAllowlist.setAllowed(secondMaker, true);
        _setUsdyEligibility(secondMaker);
    }

    function _makerParams(address secondMaker, RequesterSide side) private returns (SettlementParams memory params) {
        params = _validUsdyBuyParams();
        address quotingMaker = params.firmQuote.quotingMaker;
        params.firmQuote.requester = secondMaker;
        params.firmQuote.requesterType = ParticipantType.MAKER;
        params.firmQuote.requesterSide = side;
        params.tradeIntent.requester = secondMaker;
        params.tradeIntent.requesterType = ParticipantType.MAKER;
        params.tradeIntent.requesterSide = side;
        params.snapshot.requester = secondMaker;
        params.snapshot.requesterType = ParticipantType.MAKER;
        params.snapshot.requesterSide = side;

        if (side == RequesterSide.BUY) {
            params.tradeIntent.buyer = secondMaker;
            params.snapshot.buyer = secondMaker;
            params.tradeIntent.seller = quotingMaker;
            params.snapshot.seller = quotingMaker;
            settlementToken.setBalance(secondMaker, 100_000_000);
        } else {
            params.tradeIntent.buyer = quotingMaker;
            params.snapshot.buyer = quotingMaker;
            params.tradeIntent.seller = secondMaker;
            params.snapshot.seller = secondMaker;
            usdyToken.setBalance(secondMaker, 100 ether);
            usdyToken.setAllowance(secondMaker, address(dvp), params.snapshot.executedQuantity);
            settlementToken.setBalance(quotingMaker, 100_000_000);
        }
        _applyIdentityFeeAmounts(params, usdyFeeConfig);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), params.snapshot.buyerDebit);
        _signParams(params, SECOND_MAKER_KEY);
    }

    function _signParams(SettlementParams memory params, uint256 requesterKey) private view {
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        (uint8 makerV, bytes32 makerR, bytes32 makerS) = vm.sign(MAKER_KEY, quoteDigest);
        params.quotingMakerSignature = abi.encodePacked(makerR, makerS, makerV);
        bytes32 requesterDigest = HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent);
        (uint8 requesterV, bytes32 requesterR, bytes32 requesterS) = vm.sign(requesterKey, requesterDigest);
        params.requesterSignature = abi.encodePacked(requesterR, requesterS, requesterV);
    }
}
