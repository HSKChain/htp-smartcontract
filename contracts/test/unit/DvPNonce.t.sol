// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Vm} from "forge-std/Vm.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {NonceCancellation, NonceStatus, NonceType, ReasonCode} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract Valid1271CancellationWallet is IERC1271 {
    bytes32 private expectedDigest;
    bytes32 private expectedSignatureHash;

    function setExpected(bytes32 digest, bytes calldata signature) external {
        expectedDigest = digest;
        expectedSignatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        return digest == expectedDigest && keccak256(signature) == expectedSignatureHash
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

contract DvPNonceTest is DvPTestBase {
    bytes32 private constant NONCE_CANCELLED_TOPIC = 0x56dd9c0fade8d5511484e464d4f4ab8ebdb74119f4b1ed6d4695398ca395063c;

    function testUnwrittenMakerAndRequesterNoncesReturnUnused() public view {
        assertEq(uint8(dvp.getNonceStatus(address(0xA11CE), NonceType.MAKER_QUOTE, 0)), uint8(NonceStatus.UNUSED));
        assertEq(
            uint8(dvp.getNonceStatus(address(0xA11CE), NonceType.MAKER_QUOTE, type(uint256).max)),
            uint8(NonceStatus.UNUSED)
        );
        assertEq(uint8(dvp.getNonceStatus(address(0xA11CE), NonceType.REQUESTER_TRADE, 0)), uint8(NonceStatus.UNUSED));
    }

    function testSignerCancelsOnlyOwnValidNonceEvenWhilePausedOrRetired() public {
        address signer = address(0xA11CE);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidNonceType.selector, NonceType.NONE));
        vm.prank(signer);
        dvp.cancelNonce(NonceType.NONE, 1);

        vm.prank(signer);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, 1);
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.MAKER_QUOTE, 1)), uint8(NonceStatus.CANCELLED));
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.REQUESTER_TRADE, 1)), uint8(NonceStatus.UNUSED));
        assertEq(uint8(dvp.getNonceStatus(address(0xB0B), NonceType.MAKER_QUOTE, 1)), uint8(NonceStatus.UNUSED));

        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)));
        vm.prank(signer);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, 2);

        vm.prank(GOVERNANCE);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, bytes32(uint256(2)));
        vm.prank(signer);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, 3);

        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.REQUESTER_TRADE, 2)), uint8(NonceStatus.CANCELLED));
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.MAKER_QUOTE, 3)), uint8(NonceStatus.CANCELLED));
    }

    function testRelayerCancelsEoaAndEip1271NoncesByCurrentDomainSignature() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        address relayer = address(0xB0B);
        vm.warp(1_780_000_000);

        NonceCancellation memory eoaCancellation = NonceCancellation({
            signer: signer, nonceType: NonceType.MAKER_QUOTE, nonce: 11, deadline: uint64(block.timestamp + 1 hours)
        });
        bytes32 eoaDigest = HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), eoaCancellation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, eoaDigest);

        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)));
        vm.prank(relayer);
        dvp.cancelNonceBySig(eoaCancellation, abi.encodePacked(r, s, v));
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.MAKER_QUOTE, 11)), uint8(NonceStatus.CANCELLED));

        Valid1271CancellationWallet wallet = new Valid1271CancellationWallet();
        bytes memory contractSignature = hex"01020304";
        NonceCancellation memory contractCancellation = NonceCancellation({
            signer: address(wallet),
            nonceType: NonceType.REQUESTER_TRADE,
            nonce: 12,
            deadline: uint64(block.timestamp + 1 hours)
        });
        bytes32 contractDigest = HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), contractCancellation);
        wallet.setExpected(contractDigest, contractSignature);

        vm.prank(GOVERNANCE);
        dvp.retire(ReasonCode.PLANNED_MIGRATION, bytes32(uint256(2)));
        vm.prank(relayer);
        dvp.cancelNonceBySig(contractCancellation, contractSignature);
        assertEq(
            uint8(dvp.getNonceStatus(address(wallet), NonceType.REQUESTER_TRADE, 12)), uint8(NonceStatus.CANCELLED)
        );
    }

    function testCancellationBySigRejectsExpiredInvalidTypeOrWrongSigner() public {
        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        vm.warp(1_780_000_000);

        NonceCancellation memory cancellation = NonceCancellation({
            signer: signer, nonceType: NonceType.MAKER_QUOTE, nonce: 21, deadline: uint64(block.timestamp - 1)
        });
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.SignatureExpired.selector, cancellation.deadline));
        dvp.cancelNonceBySig(cancellation, bytes(""));

        cancellation.deadline = uint64(block.timestamp + 1 hours);
        cancellation.nonceType = NonceType.NONE;
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidNonceType.selector, NonceType.NONE));
        dvp.cancelNonceBySig(cancellation, bytes(""));

        cancellation.nonceType = NonceType.MAKER_QUOTE;
        bytes32 digest = HTPHashing.hashNonceCancellationDigest(dvp.domainSeparatorV4(), cancellation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey + 1, digest);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidSignature.selector, signer));
        dvp.cancelNonceBySig(cancellation, abi.encodePacked(r, s, v));
    }

    function testCancelledNonceCannotReturnToUnusedAndSpacesStayIsolated() public {
        address signer = address(0xA11CE);
        vm.prank(signer);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, 31);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.NonceUnavailable.selector, signer, NonceType.MAKER_QUOTE, 31, NonceStatus.CANCELLED
            )
        );
        vm.prank(signer);
        dvp.cancelNonce(NonceType.MAKER_QUOTE, 31);

        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.MAKER_QUOTE, 31)), uint8(NonceStatus.CANCELLED));
        assertEq(uint8(dvp.getNonceStatus(signer, NonceType.REQUESTER_TRADE, 31)), uint8(NonceStatus.UNUSED));
    }

    function testNonceCancelledEventContainsActualChainSignerTypeAndNonce() public {
        address signer = address(0xA11CE);
        vm.recordLogs();
        vm.prank(signer);
        dvp.cancelNonce(NonceType.REQUESTER_TRADE, 41);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[0], NONCE_CANCELLED_TOPIC);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(signer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint8(NonceType.REQUESTER_TRADE))));
        assertEq(logs[0].topics[3], bytes32(uint256(41)));
        assertEq(abi.decode(logs[0].data, (uint256)), DEPLOYED_CHAIN_ID);
    }
}
