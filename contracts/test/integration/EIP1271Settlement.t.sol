// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {ParticipantInput, ParticipantType, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract Settlement1271Wallet is IERC1271 {
    bytes32 private expectedDigest;
    bytes32 private expectedSignatureHash;

    function configure(bytes32 digest, bytes calldata signature) external {
        expectedDigest = digest;
        expectedSignatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        return digest == expectedDigest && keccak256(signature) == expectedSignatureHash
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

contract EIP1271SettlementTest is UsdySettlementFixture {
    function testContractWalletUsesSameAddressForSignatureAndSettlementFunds() public {
        Settlement1271Wallet wallet = new Settlement1271Wallet();
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
        bytes memory walletSignature = hex"1271cafe";
        bytes32 requesterDigest = HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent);
        wallet.configure(requesterDigest, walletSignature);
        params.requesterSignature = walletSignature;

        _settleUsdy(params);

        assertEq(usdyToken.balanceOf(address(wallet)), params.snapshot.executedQuantity);
        assertEq(settlementToken.balanceOf(address(wallet)), 100_000_000 - params.snapshot.buyerDebit);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testTwoContractWalletSignaturesSettleInOneTransaction() public {
        Settlement1271Wallet makerWallet = new Settlement1271Wallet();
        Settlement1271Wallet requesterWallet = new Settlement1271Wallet();
        _registerWallet(address(makerWallet), ParticipantType.MAKER, bytes32(uint256(0x1271A)));
        _registerWallet(address(requesterWallet), ParticipantType.INVESTOR, bytes32(uint256(0x1271B)));
        usdyAllowlist.setAllowed(address(makerWallet), true);
        usdyAllowlist.setAllowed(address(requesterWallet), true);
        _setUsdyEligibility(address(makerWallet));
        _setUsdyEligibility(address(requesterWallet));

        SettlementParams memory params = _validUsdyBuyParams();
        params.firmQuote.quotingMaker = address(makerWallet);
        params.firmQuote.requester = address(requesterWallet);
        params.tradeIntent.requester = address(requesterWallet);
        params.tradeIntent.quotingMaker = address(makerWallet);
        params.tradeIntent.buyer = address(requesterWallet);
        params.tradeIntent.seller = address(makerWallet);
        params.snapshot.requester = address(requesterWallet);
        params.snapshot.quotingMaker = address(makerWallet);
        params.snapshot.buyer = address(requesterWallet);
        params.snapshot.seller = address(makerWallet);
        usdyToken.setBalance(address(makerWallet), 100 ether);
        usdyToken.setAllowance(address(makerWallet), address(dvp), params.snapshot.executedQuantity);
        settlementToken.setBalance(address(requesterWallet), 100_000_000);
        settlementToken.setAllowance(address(requesterWallet), address(dvp), params.snapshot.buyerDebit);

        bytes memory makerSignature = hex"1271aaaa";
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.quoteHash = quoteDigest;
        makerWallet.configure(quoteDigest, makerSignature);
        params.quotingMakerSignature = makerSignature;

        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        bytes memory requesterSignature = hex"1271bbbb";
        requesterWallet.configure(
            HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent), requesterSignature
        );
        params.requesterSignature = requesterSignature;

        uint256 gasBefore = gasleft();
        _settleUsdy(params);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("phase19_dual_eip1271_settle_gas", gasUsed);
        if (!vm.envOr("PHASE19_COVERAGE", false)) assertLe(gasUsed, 1_150_000);

        assertEq(usdyToken.balanceOf(address(requesterWallet)), params.snapshot.executedQuantity);
        assertEq(settlementToken.balanceOf(address(requesterWallet)), 100_000_000 - params.snapshot.buyerDebit);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function _registerWallet(address wallet, ParticipantType participantType, bytes32 participantIdHash) private {
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: wallet,
                participantIdHash: participantIdHash,
                participantType: participantType,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }
}
