// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract AdapterReachabilityTest is UsdySettlementFixture {
    function testIssuanceRedemptionBridgeAndArbitraryCallsAreUnreachable() public {
        bytes[] memory forbiddenCalls = new bytes[](5);
        forbiddenCalls[0] = abi.encodeWithSignature("instantManager()");
        forbiddenCalls[1] = abi.encodeWithSignature("mint(address,uint256)", address(this), 1);
        forbiddenCalls[2] = abi.encodeWithSignature("redeem(uint256)", 1);
        forbiddenCalls[3] = abi.encodeWithSignature("bridge(address,uint256,uint256)", address(this), 1, 1);
        forbiddenCalls[4] = abi.encodeWithSignature("call(address,bytes)", address(usdyToken), bytes("arbitrary"));

        for (uint256 i = 0; i < forbiddenCalls.length; ++i) {
            _assertUnreachable(address(dvp), forbiddenCalls[i]);
            _assertUnreachable(address(usdyAdapter), forbiddenCalls[i]);
        }
    }

    function _assertUnreachable(address target, bytes memory callData) private {
        (bool success, bytes memory returnData) = target.call(callData);
        assertFalse(success);
        assertEq(returnData.length, 0);
    }
}
