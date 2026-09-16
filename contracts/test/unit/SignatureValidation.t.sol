// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract Configurable1271Wallet is IERC1271 {
    enum Mode {
        VALID,
        WRONG_MAGIC,
        REVERT,
        SHORT_RETURN
    }

    bytes32 private expectedDigest;
    bytes32 private expectedSignatureHash;
    Mode private mode;

    function configure(bytes32 digest, bytes calldata signature, Mode mode_) external {
        expectedDigest = digest;
        expectedSignatureHash = keccak256(signature);
        mode = mode_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        if (mode == Mode.REVERT) revert();
        if (mode == Mode.SHORT_RETURN) {
            bytes4 magic = IERC1271.isValidSignature.selector;
            assembly ("memory-safe") {
                mstore(0, magic)
                return(0, 4)
            }
        }
        if (mode == Mode.VALID && digest == expectedDigest && keccak256(signature) == expectedSignatureHash) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }
}

contract SignatureValidationTest is DvPTestBase {
    uint256 private constant WRONG_KEY = 0xBAD;
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function testCanonicalLowSEoaSignaturesReachNextSettlementStage() public {
        SettlementParams memory params = _validSignedParams();
        vm.warp(params.snapshot.createdAt);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ExternalCallFailed.selector, IParticipantRegistry.getParticipant.selector)
        );
        _settleAsExecutor(params);
    }

    function testEoaSignatureRejectsWrongSignerDigestDomainVAndHighS() public {
        SettlementParams memory params = _validSignedParams();
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);

        params.quotingMakerSignature = _sign(WRONG_KEY, quoteDigest);
        _expectInvalid(params, params.firmQuote.quotingMaker);

        params = _validSignedParams();
        params.quotingMakerSignature = _sign(MAKER_KEY, bytes32(uint256(0xBAD)));
        _expectInvalid(params, params.firmQuote.quotingMaker);

        params = _validSignedParams();
        bytes32 wrongDomain = HTPHashing.domainSeparator(bytes("1.2.3"), DEPLOYED_CHAIN_ID + 1, address(dvp));
        params.quotingMakerSignature = _sign(MAKER_KEY, HTPHashing.hashFirmQuoteDigest(wrongDomain, params.firmQuote));
        _expectInvalid(params, params.firmQuote.quotingMaker);

        params = _validSignedParams();
        params.quotingMakerSignature[64] = bytes1(uint8(0));
        _expectInvalid(params, params.firmQuote.quotingMaker);

        params = _validSignedParams();
        params.quotingMakerSignature = _toHighS(params.quotingMakerSignature);
        _expectInvalid(params, params.firmQuote.quotingMaker);
    }

    function testEip1271UsesStaticcallMagicAndFailsClosedOnBadReturns() public {
        Configurable1271Wallet wallet = new Configurable1271Wallet();
        bytes memory walletSignature = hex"0102030405";
        SettlementParams memory params = _validSignedParams();
        params.firmQuote.quotingMaker = address(wallet);
        params.snapshot.quotingMaker = address(wallet);
        params.snapshot.seller = address(wallet);

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.quotingMaker = address(wallet);
        params.tradeIntent.seller = address(wallet);
        params.quotingMakerSignature = walletSignature;
        params.requesterSignature =
            _sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));

        wallet.configure(quoteDigest, walletSignature, Configurable1271Wallet.Mode.VALID);
        vm.warp(params.snapshot.createdAt);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ExternalCallFailed.selector, IParticipantRegistry.getParticipant.selector)
        );
        _settleAsExecutor(params);

        wallet.configure(quoteDigest, walletSignature, Configurable1271Wallet.Mode.WRONG_MAGIC);
        _expectInvalid(params, address(wallet));

        wallet.configure(quoteDigest, walletSignature, Configurable1271Wallet.Mode.REVERT);
        _expectInvalid(params, address(wallet));

        wallet.configure(quoteDigest, walletSignature, Configurable1271Wallet.Mode.SHORT_RETURN);
        _expectInvalid(params, address(wallet));
    }

    function testSigningAccountsMustBeTheActualSettlementWallets() public {
        SettlementParams memory params = _validSignedParams();
        address delegatedSeller = address(0xDE1E6A7E);
        params.tradeIntent.seller = delegatedSeller;
        params.snapshot.seller = delegatedSeller;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.requesterSignature =
            _sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("seller")));
        _settleAsExecutor(params);

        params = _validSignedParams();
        address delegatedBuyer = address(0xB0B0);
        params.tradeIntent.buyer = delegatedBuyer;
        params.snapshot.buyer = delegatedBuyer;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.requesterSignature =
            _sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSettlementParams.selector, bytes32("buyer")));
        _settleAsExecutor(params);
    }

    function _toHighS(bytes memory signature) private pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        return abi.encodePacked(r, highS, flippedV);
    }

    function _expectInvalid(SettlementParams memory params, address signer) private {
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, signer));
        _settleAsExecutor(params);
    }
}
