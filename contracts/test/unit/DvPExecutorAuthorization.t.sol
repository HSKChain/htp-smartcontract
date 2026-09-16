// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {NonceStatus, NonceType, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPTestBase} from "test/helpers/DvPTestBase.sol";

contract ReentrantExecutorWallet {
    DvPSettlement private immutable DVP;
    bytes private settlementCall;

    constructor(DvPSettlement dvp) {
        DVP = dvp;
    }

    function setSettlementCall(bytes calldata callData) external {
        settlementCall = callData;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        (bool succeeded, bytes memory revertData) = address(DVP).staticcall(settlementCall);
        if (succeeded || revertData.length < 4) return 0xffffffff;

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
        return selector == bytes4(0x3ee5aeb5) ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract DvPExecutorAuthorizationTest is DvPTestBase {
    function testNonExecutorCannotSubmitSettlementWithValidSignatures() public {
        SettlementParams memory params = _validSignedParams();
        address outsider = address(0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Roles.EXECUTOR_ROLE
            )
        );
        vm.prank(outsider);
        dvp.settle(params);
    }

    function testExecutorPathEntersReentrancyGuardBeforeSignatureCallbacks() public {
        ReentrantExecutorWallet wallet = new ReentrantExecutorWallet(dvp);
        vm.prank(GOVERNANCE);
        dvp.grantRole(Roles.EXECUTOR_ROLE, address(wallet));

        SettlementParams memory params = _paramsForContractMaker(address(wallet));
        wallet.setSettlementCall(abi.encodeCall(dvp.settle, (params)));
        vm.warp(params.snapshot.createdAt);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ExternalCallFailed.selector, IParticipantRegistry.getParticipant.selector)
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testAuthorizationAndPausePrecedeAnySettlementStateWrite() public {
        SettlementParams memory params = _validSignedParams();
        address outsider = address(0xBAD);
        vm.prank(PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Roles.EXECUTOR_ROLE
            )
        );
        vm.prank(outsider);
        dvp.settle(params);

        vm.expectRevert(HTPErrors.ContractPaused.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);

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

    function _paramsForContractMaker(address maker) private view returns (SettlementParams memory params) {
        params = _validSignedParams();
        params.firmQuote.quotingMaker = maker;
        params.tradeIntent.quotingMaker = maker;
        params.snapshot.quotingMaker = maker;
        params.tradeIntent.seller = maker;
        params.snapshot.seller = maker;

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.quotingMakerSignature = hex"01";
        _resignRequester(params);
    }
}
