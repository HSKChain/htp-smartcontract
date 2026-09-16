// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {MaliciousAdapterShape} from "./MaliciousAssetAdapters.sol";
import {Decision, TransferLeg} from "../../src/types/HTPTypes.sol";

contract MixedStaticcallAdapter is MaliciousAdapterShape {
    function preCheck(address token, address from, address to, uint256 amount, TransferLeg, bytes32 contextHash)
        external
        view
        returns (Decision, uint256, bytes32)
    {
        (bool approvedCall,) = token.staticcall(abi.encodeWithSelector(bytes4(0xd4ce1415), from, to, amount));
        (bool arbitraryCall,) = to.staticcall(abi.encodePacked(contextHash));
        return (approvedCall && arbitraryCall ? Decision.PASS : Decision.UNKNOWN, 0, bytes32(0));
    }
}
