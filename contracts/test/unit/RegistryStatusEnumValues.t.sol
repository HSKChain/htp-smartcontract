// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {
    AdapterStatus,
    AssetVersionStatus,
    CalculatorStatus,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    ParticipantStatus,
    SettlementTokenStatus
} from "src/types/HTPTypes.sol";

contract RegistryStatusEnumValuesTest is Test {
    function testParticipantStatusValues() public pure {
        assertEq(uint8(ParticipantStatus.NONE), 0);
        assertEq(uint8(ParticipantStatus.ACTIVE), 1);
        assertEq(uint8(ParticipantStatus.PAUSED), 2);
        assertEq(uint8(ParticipantStatus.REVOKED), 3);
    }

    function testVersionedConfigStatusValues() public pure {
        assertEq(uint8(AssetVersionStatus.DEPRECATED), 4);
        assertEq(uint8(FeeVersionStatus.DEPRECATED), 4);
        assertEq(uint8(SettlementTokenStatus.DEPRECATED), 4);
        assertEq(uint8(AdapterStatus.DEPRECATED), 4);
        assertEq(uint8(CalculatorStatus.DEPRECATED), 4);
        assertEq(uint8(AssetVersionStatus.NONE), 0);
        assertEq(uint8(AssetVersionStatus.REGISTERED), 1);
        assertEq(uint8(AssetVersionStatus.ACTIVE), 2);
        assertEq(uint8(AssetVersionStatus.PAUSED), 3);
    }

    function testFeePolicyEpochStatusValues() public pure {
        assertEq(uint8(FeePolicyEpochStatus.NONE), 0);
        assertEq(uint8(FeePolicyEpochStatus.DRAFT), 1);
        assertEq(uint8(FeePolicyEpochStatus.ACTIVE), 2);
        assertEq(uint8(FeePolicyEpochStatus.LEGACY_SERVING), 3);
        assertEq(uint8(FeePolicyEpochStatus.CLOSED), 4);
    }
}
