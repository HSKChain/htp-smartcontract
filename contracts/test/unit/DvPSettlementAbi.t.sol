// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IDvPSettlement} from "src/interfaces/IDvPSettlement.sol";

contract DvPSettlementAbiTest is Test {
    function testCompletePublicBehaviorSelectorsMatchReviewedLiterals() public pure {
        _assertSelector(IDvPSettlement.settle.selector, 0x8ad987e6);
        _assertSelector(IDvPSettlement.preCheck.selector, 0xc196d265);
        _assertSelector(IDvPSettlement.cancelNonce.selector, 0x03c7e1f2);
        _assertSelector(IDvPSettlement.cancelNonceBySig.selector, 0xaddb767e);
        _assertSelector(IDvPSettlement.getNonceStatus.selector, 0x0e5d841a);
        _assertSelector(IDvPSettlement.pauseGlobal.selector, 0x9fd6ebc6);
        _assertSelector(IDvPSettlement.unpauseGlobal.selector, 0x466faf1e);
        _assertSelector(IDvPSettlement.retire.selector, 0x2214b054);
        _assertSelector(IDvPSettlement.domainSeparatorV4.selector, 0x78e890ba);
        _assertSelector(IDvPSettlement.deploymentVersionHash.selector, 0x22a5a34f);
        _assertSelector(IDvPSettlement.globalPaused.selector, 0x61a552dc);
        _assertSelector(IDvPSettlement.retired.selector, 0x2eb38ae0);
        _assertSelector(IDvPSettlement.participantRegistry.selector, 0x9e9ca591);
        _assertSelector(IDvPSettlement.assetVersionRegistry.selector, 0x81c419ef);
        _assertSelector(IDvPSettlement.eligibilityRegistry.selector, 0x7a3ab42a);
        _assertSelector(IDvPSettlement.feeRegistry.selector, 0xb3a408b8);
        _assertSelector(IDvPSettlement.marketRuleRegistry.selector, 0x1c321ff0);
        _assertSelector(IDvPSettlement.settlementTokenRegistry.selector, 0xf741fa39);
        _assertSelector(IDvPSettlement.adapterRegistry.selector, 0x50b5c16a);
        _assertSelector(IDvPSettlement.principalCalculatorRegistry.selector, 0x1271ab19);
    }

    function testNonceEventTopicsMatchReviewedLiterals() public pure {
        assertEq(
            IDvPSettlement.NonceConsumed.selector, 0x253572b7b25b7d1befe55ca30e0018e6b2ca7b2af47ffca61b96e12bab481154
        );
        assertEq(
            IDvPSettlement.NonceCancelled.selector, 0x56dd9c0fade8d5511484e464d4f4ab8ebdb74119f4b1ed6d4695398ca395063c
        );
    }

    function _assertSelector(bytes4 actual, bytes4 expected) private pure {
        assertEq(bytes32(actual), bytes32(expected));
    }
}
