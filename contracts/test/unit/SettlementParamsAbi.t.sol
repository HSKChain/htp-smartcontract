// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract SettlementParamsAbiTest is Test {
    function testSettlementParamsIsOnlySettlementEntryPayload() public pure {
        SettlementParams memory params;
        params.quotingMakerSignature = hex"0102";
        params.requesterSignature = hex"0304";
        params.assetPermit.usePermit = true;
        params.settlementPermit.usePermit = false;

        bytes memory encoded = abi.encode(params);
        bytes memory settleCallData = abi.encodeCall(IDvPSettlement.settle, (params));
        bytes memory preCheckCallData = abi.encodeCall(IDvPSettlement.preCheck, (params));
        assertGt(encoded.length, 0);
        assertEq(abiSelector(settleCallData), IDvPSettlement.settle.selector);
        assertEq(abiSelector(preCheckCallData), IDvPSettlement.preCheck.selector);
        assertEq(settleCallData.length, 4 + encoded.length);
        assertEq(preCheckCallData.length, 4 + encoded.length);
        assertEq(params.quotingMakerSignature, hex"0102");
        assertEq(params.requesterSignature, hex"0304");
        assertTrue(params.assetPermit.usePermit);
        assertFalse(params.settlementPermit.usePermit);
        assertTrue(IDvPSettlement.settle.selector != IDvPSettlement.preCheck.selector);
    }
}
