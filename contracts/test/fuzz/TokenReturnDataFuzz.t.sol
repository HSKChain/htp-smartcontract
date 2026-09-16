// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, PermitData, SettlementParams} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract TokenReturnDataFuzzTest is DvPPreCheckTestBase {
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;
    bytes4 private constant ALLOWANCE_SELECTOR = 0xdd62ed3e;
    bytes4 private constant DECIMALS_SELECTOR = 0x313ce567;
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd;
    bytes4 private constant PERMIT_SELECTOR = 0xd505accf;

    function testFuzzDecimalsReturnDataMustBeExactCanonicalWord(bytes calldata returnData, bool useAsset) public {
        vm.assume(returnData.length <= 1024);
        uint256 expected = useAsset ? 18 : 6;
        vm.assume(!_isExactWord(returnData, expected));
        SettlementParams memory params = _validPreCheckParams();
        address token = useAsset ? address(assetToken) : address(settlementToken);
        vm.mockCall(token, abi.encodeWithSelector(DECIMALS_SELECTOR), returnData);

        (Decision decision,) = dvp.preCheck(params);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testFuzzAllowanceReturnDataLengthsOtherThanWordAreUnknown(bytes calldata returnData, bool useAsset)
        public
    {
        vm.assume(returnData.length <= 1024 && returnData.length != 32);
        SettlementParams memory params = _validPreCheckParams();
        address token = useAsset ? params.snapshot.assetToken : params.snapshot.settlementToken;
        address owner = useAsset ? params.snapshot.seller : params.snapshot.buyer;
        vm.mockCall(token, abi.encodeWithSelector(ALLOWANCE_SELECTOR, owner, address(dvp)), returnData);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(reason, HTPErrors.ExternalCallFailed.selector);
    }

    function testFuzzBalanceReturnDataLengthsOtherThanWordRollback(bytes calldata returnData, bool useAsset) public {
        vm.assume(returnData.length <= 1024 && returnData.length != 32);
        SettlementParams memory params = _validPreCheckParams();
        address token = useAsset ? params.snapshot.assetToken : params.snapshot.settlementToken;
        address account = useAsset ? params.snapshot.seller : params.snapshot.buyer;
        uint256 sellerAssetBefore = assetToken.balanceOf(params.snapshot.seller);
        uint256 buyerCashBefore = settlementToken.balanceOf(params.snapshot.buyer);
        vm.mockCall(token, abi.encodeWithSelector(BALANCE_OF_SELECTOR, account), returnData);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, token));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        vm.clearMockedCalls();
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(assetToken.balanceOf(params.snapshot.seller), sellerAssetBefore);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), buyerCashBefore);
    }

    function testFuzzTransferFromRejectsEveryNonCanonicalReturn(bytes calldata returnData) public {
        vm.assume(returnData.length <= 1024);
        vm.assume(returnData.length != 0 && !_isExactWord(returnData, 1));
        SettlementParams memory params = _validPreCheckParams();
        bytes memory callData = abi.encodeWithSelector(
            TRANSFER_FROM_SELECTOR, params.snapshot.seller, params.snapshot.buyer, params.snapshot.executedQuantity
        );
        vm.mockCall(params.snapshot.assetToken, callData, returnData);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, params.snapshot.assetToken));
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(assetToken.balanceOf(params.snapshot.seller), 100 ether);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), 0);
    }

    function testFuzzPermitReturnDataAndRevertDoNotAuthorizeWithoutFinalAllowanceCheck(
        bytes calldata returnData,
        bool shouldRevert
    ) public {
        vm.assume(returnData.length <= 1024);
        SettlementParams memory params = _validPreCheckParams();
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
        bytes memory callData = abi.encodeWithSelector(
            PERMIT_SELECTOR,
            params.assetPermit.owner,
            address(dvp),
            params.assetPermit.value,
            params.assetPermit.deadline,
            params.assetPermit.v,
            params.assetPermit.r,
            params.assetPermit.s
        );
        if (shouldRevert) {
            vm.mockCallRevert(params.snapshot.assetToken, callData, returnData);
        } else {
            vm.mockCall(params.snapshot.assetToken, callData, returnData);
        }

        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testTokenViewAndTransferRevertsFailClosed() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            params.snapshot.assetToken, abi.encodeWithSelector(DECIMALS_SELECTOR), bytes("DECIMALS_REVERT")
        );
        (Decision decimalsDecision,) = dvp.preCheck(params);
        assertEq(uint8(decimalsDecision), uint8(Decision.UNKNOWN));
        vm.clearMockedCalls();

        vm.mockCallRevert(
            params.snapshot.assetToken,
            abi.encodeWithSelector(ALLOWANCE_SELECTOR, params.snapshot.seller, address(dvp)),
            bytes("ALLOWANCE_REVERT")
        );
        (Decision allowanceDecision,) = dvp.preCheck(params);
        assertEq(uint8(allowanceDecision), uint8(Decision.UNKNOWN));
        vm.clearMockedCalls();

        vm.mockCallRevert(
            params.snapshot.assetToken,
            abi.encodeWithSelector(
                TRANSFER_FROM_SELECTOR, params.snapshot.seller, params.snapshot.buyer, params.snapshot.executedQuantity
            ),
            bytes("TRANSFER_REVERT")
        );
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, params.snapshot.assetToken));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testMalformedDecimalsSettlementUsesTokenSpecificMismatch() public {
        for (uint256 tokenIndex; tokenIndex < 2; ++tokenIndex) {
            bool useAsset = tokenIndex == 0;
            _assertMalformedDecimals(useAsset, bytes("DECIMALS_REVERT"), true);
            _assertMalformedDecimals(useAsset, hex"00", false);
            _assertMalformedDecimals(useAsset, bytes.concat(abi.encode(uint256(0)), hex"00"), false);
            _assertMalformedDecimals(useAsset, abi.encode(uint256(256)), false);
        }
    }

    function _assertMalformedDecimals(bool useAsset, bytes memory returnData, bool shouldRevert) private {
        SettlementParams memory params = _validPreCheckParams();
        address token = useAsset ? params.snapshot.assetToken : params.snapshot.settlementToken;
        bytes memory callData = abi.encodeWithSelector(DECIMALS_SELECTOR);
        if (shouldRevert) {
            vm.mockCallRevert(token, callData, returnData);
        } else {
            vm.mockCall(token, callData, returnData);
        }

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(reason, HTPErrors.ExternalCallFailed.selector);

        if (useAsset) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    HTPErrors.AssetDecimalsMismatch.selector, token, params.snapshot.assetDecimals, type(uint256).max
                )
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    HTPErrors.SettlementTokenDecimalsMismatch.selector,
                    token,
                    params.snapshot.settlementTokenDecimals,
                    type(uint256).max
                )
            );
        }
        vm.prank(EXECUTOR);
        dvp.settle(params);

        vm.clearMockedCalls();
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function _isExactWord(bytes calldata returnData, uint256 expected) private pure returns (bool) {
        if (returnData.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := calldataload(returnData.offset)
        }
        return word == expected;
    }
}
