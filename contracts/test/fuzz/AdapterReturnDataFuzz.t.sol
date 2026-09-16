// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1404Adapter, IERC1404Restriction} from "src/adapters/ERC1404Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {Decision, SettlementParams, TransferLeg} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract FuzzERC1404Token {
    function detectTransferRestriction(address, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract AdapterReturnDataFuzzTest is Test {
    address private constant DVP = address(0xD0);
    address private constant FROM = address(0x2000);
    address private constant TO = address(0x3000);
    bytes32 private constant CONTEXT = bytes32(uint256(0x4000));

    FuzzERC1404Token private immutable TOKEN = new FuzzERC1404Token();
    IAssetAdapter private immutable ADAPTER =
        IAssetAdapter(address(new ERC1404Adapter(DVP, address(TOKEN), address(TOKEN).codehash, 50_000)));

    function testFuzzMalformedReturnDataNeverPasses(bytes calldata returnData) public {
        bool canonical;
        if (returnData.length == 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(returnData.offset)
            }
            canonical = word <= type(uint8).max;
        }
        vm.assume(!canonical);

        bytes memory callData = abi.encodeCall(IERC1404Restriction.detectTransferRestriction, (FROM, TO, 100 ether));
        vm.mockCall(address(TOKEN), callData, returnData);

        (Decision decision,,) = _preCheck(TransferLeg.ASSET, CONTEXT);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
    }

    function testFuzzNoneUnsupportedLegOrZeroContextNeverPasses(uint8 legValue, bytes32 contextHash) public {
        legValue = uint8(bound(legValue, uint8(TransferLeg.NONE), uint8(TransferLeg.SETTLEMENT_TO_COLLECTOR)));
        vm.assume(legValue != uint8(TransferLeg.ASSET) || contextHash == bytes32(0));

        (Decision decision,,) = _preCheck(TransferLeg(legValue), contextHash);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
    }

    function testFuzzProviderDriftNeverPasses(address token) public {
        vm.assume(token != address(TOKEN));
        vm.prank(DVP);
        (Decision decision,,) = ADAPTER.preCheck(token, FROM, TO, 100 ether, TransferLeg.ASSET, CONTEXT);
        assertNotEq(uint8(decision), uint8(Decision.PASS));
    }

    function _preCheck(TransferLeg leg, bytes32 contextHash)
        private
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        vm.prank(DVP);
        return ADAPTER.preCheck(address(TOKEN), FROM, TO, 100 ether, leg, contextHash);
    }
}

contract DvPAdapterReturnDataFuzzTest is DvPPreCheckTestBase {
    function testFuzzNonPassAdapterReturnDataNeverSettles(bytes calldata returnData) public {
        vm.assume(returnData.length <= 4096);
        vm.assume(!_isCanonicalPass(returnData));
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(address(adapter), _assetCall(params), returnData);

        (Decision decision,) = dvp.preCheck(params);
        assertNotEq(uint8(decision), uint8(Decision.PASS));

        vm.prank(EXECUTOR);
        (bool success,) = address(dvp).call(abi.encodeCall(dvp.settle, (params)));
        assertFalse(success);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function testBoundaryLengthsAndNoneUnknownNeverPass() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes[] memory returnCases = new bytes[](5);
        returnCases[0] = new bytes(95);
        returnCases[1] = new bytes(96);
        returnCases[2] = new bytes(97);
        returnCases[3] = abi.encode(Decision.NONE, uint256(0), bytes32(0));
        returnCases[4] = abi.encode(Decision.UNKNOWN, uint256(0), bytes32(0));

        for (uint256 i; i < returnCases.length; ++i) {
            vm.mockCall(address(adapter), _assetCall(params), returnCases[i]);
            (Decision decision,) = dvp.preCheck(params);
            assertNotEq(uint8(decision), uint8(Decision.PASS));
            vm.clearMockedCalls();
        }
    }

    function testOversizedAdapterReturnDataNeverPasses() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(address(adapter), _assetCall(params), new bytes(65_536));

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(reason, HTPErrors.ExternalCallFailed.selector);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function _assetCall(SettlementParams memory params) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAssetAdapter.preCheck.selector,
            params.snapshot.assetToken,
            params.snapshot.seller,
            params.snapshot.buyer,
            params.snapshot.executedQuantity,
            TransferLeg.ASSET,
            params.tradeIntent.snapshotHash
        );
    }

    function _isCanonicalPass(bytes calldata returnData) private pure returns (bool) {
        if (returnData.length != 96) return false;
        uint256 decision;
        uint256 restrictionCode;
        bytes32 reasonHash;
        assembly ("memory-safe") {
            decision := calldataload(returnData.offset)
            restrictionCode := calldataload(add(returnData.offset, 0x20))
            reasonHash := calldataload(add(returnData.offset, 0x40))
        }
        return decision == uint256(Decision.PASS) && restrictionCode == 0 && reasonHash == bytes32(0);
    }
}
