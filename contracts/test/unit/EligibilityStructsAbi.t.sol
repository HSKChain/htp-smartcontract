// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IEligibilityRegistry} from "src/interfaces/IEligibilityRegistry.sol";
import {Decision, EligibilityInput, EligibilityRecord, ReasonCode} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract EligibilityStructsAbiTest is Test {
    function testEligibilityStructsContainOnlyCurrentPermissionFields() public pure {
        EligibilityInput memory input;
        input.wallet = address(0xA11CE);
        input.decision = Decision.PASS;
        assertEq(abi.encode(input).length, 8 * 32);

        EligibilityRecord memory record;
        record.recordVersion = 1;
        record.paused = true;
        assertEq(abi.encode(record).length, 12 * 32);
    }

    function testCurrentPublicSelectorsEncode() public pure {
        EligibilityInput memory input;
        bytes memory callData = abi.encodeCall(IEligibilityRegistry.setEligibility, (input, uint64(0)));
        assertEq(abiSelector(callData), IEligibilityRegistry.setEligibility.selector);
        assertEq(callData.length, 4 + 9 * 32);
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IEligibilityRegistry.pauseEligibility,
                    (bytes32(0), uint64(0), ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)))
                )
            ),
            IEligibilityRegistry.pauseEligibility.selector
        );
        assertEq(
            abiSelector(abi.encodeCall(IEligibilityRegistry.isEligible, (address(0), bytes32(0)))),
            IEligibilityRegistry.isEligible.selector
        );
        assertEq(
            abiSelector(abi.encodeCall(IEligibilityRegistry.getEligibility, (bytes32(0)))),
            IEligibilityRegistry.getEligibility.selector
        );
    }
}
