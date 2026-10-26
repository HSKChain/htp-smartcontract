// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";

contract FeeRegistryAbiTest is Test {
    function testCompletePublicBehaviorSelectorsMatchReviewedLiterals() public pure {
        _assertSelector(IFeeRegistry.createFeePolicyEpoch.selector, 0x2a54a300);
        _assertSelector(IFeeRegistry.sealFeePolicyEpoch.selector, 0x4f38e1b8);
        _assertSelector(IFeeRegistry.activateFeePolicyEpoch.selector, 0xd17bcc17);
        _assertSelector(IFeeRegistry.moveFeePolicyEpochToLegacyServing.selector, 0x4e5a0df5);
        _assertSelector(IFeeRegistry.closeFeePolicyEpoch.selector, 0x290bdffc);
        _assertSelector(IFeeRegistry.getFeePolicyEpoch.selector, 0x185b117e);
        _assertSelector(IFeeRegistry.registerFeeVersion.selector, 0xd7c0f23d);
        _assertSelector(IFeeRegistry.activateFeeVersion.selector, 0x057c647f);
        _assertSelector(IFeeRegistry.pauseFeeVersion.selector, 0x142ac593);
        _assertSelector(IFeeRegistry.unpauseFeeVersion.selector, 0xfdc938c3);
        _assertSelector(IFeeRegistry.deprecateFeeVersion.selector, 0x025133b4);
        _assertSelector(IFeeRegistry.getFeeVersion.selector, 0xb2db32b7);
        _assertSelector(IFeeRegistry.resolveApplicableFee.selector, 0x3100962e);
        _assertSelector(IFeeRegistry.isFeeVersionExecutable.selector, 0xf00cba64);
        _assertSelector(IFeeRegistry.registerDependentDvp.selector, 0x03f8d147);
        _assertSelector(IFeeRegistry.exemptRetiredDependentDvp.selector, 0xd74df627);
        _assertSelector(IFeeRegistry.getDependentDvpCount.selector, 0xbafdbeba);
        _assertSelector(IFeeRegistry.getDependentDvp.selector, 0x9816d4b9);
        _assertSelector(IFeeRegistry.upgradeToAndCall.selector, 0x4f1ef286);
    }

    function _assertSelector(bytes4 actual, bytes4 expected) private pure {
        assertEq(bytes32(actual), bytes32(expected));
    }
}
