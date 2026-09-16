// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Roles} from "src/libraries/Roles.sol";
import {NonceStatus, NonceType, PermitData, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract DvPReentrancyTest is DvPPreCheckTestBase {
    bytes4 private constant REENTRANCY_SELECTOR = 0x3ee5aeb5;

    function testTokenCallbackCannotReenterSettle() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(address(timelock));
        dvp.grantRole(Roles.EXECUTOR_ROLE, address(assetToken));
        assetToken.configureCallback(address(dvp), abi.encodeCall(dvp.settle, (params)));

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(assetToken.callbackSucceeded());
        assertEq(assetToken.callbackRevertSelector(), REENTRANCY_SELECTOR);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    function testTokenCallbackCannotReenterCancellation() public {
        SettlementParams memory params = _validPreCheckParams();
        uint256 callbackNonce = 999;
        assetToken.configureCallback(
            address(dvp), abi.encodeCall(dvp.cancelNonce, (NonceType.MAKER_QUOTE, callbackNonce))
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(assetToken.callbackSucceeded());
        assertEq(assetToken.callbackRevertSelector(), REENTRANCY_SELECTOR);
        assertEq(
            uint8(dvp.getNonceStatus(address(assetToken), NonceType.MAKER_QUOTE, callbackNonce)),
            uint8(NonceStatus.UNUSED)
        );
    }

    function testPermitCallbackCannotReenterCancellation() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
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
        assetToken.configureCallback(
            address(dvp), abi.encodeCall(dvp.cancelNonce, (NonceType.REQUESTER_TRADE, uint256(777)))
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(assetToken.callbackSucceeded());
        assertEq(assetToken.callbackRevertSelector(), REENTRANCY_SELECTOR);
        assertEq(assetToken.permitCalls(), 1);
    }

    function testAuthorizedPauserCallbackCannotMutateGovernanceState() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(address(timelock));
        dvp.grantRole(Roles.PAUSER_ROLE, address(assetToken));
        assetToken.configureCallback(
            address(dvp), abi.encodeCall(dvp.pauseGlobal, (ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xA11CE))))
        );

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(assetToken.callbackSucceeded());
        assertEq(assetToken.callbackRevertSelector(), REENTRANCY_SELECTOR);
        assertFalse(dvp.globalPaused());
    }
}
