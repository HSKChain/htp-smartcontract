// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {FeePolicyEpochConfig, FeePolicyEpochRecord, FeePolicyEpochStatus} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract FeePolicyEpochStructsAbiTest is Test {
    function testEpochConfigOwnsImmutableHash() public pure {
        FeePolicyEpochConfig memory config;
        config.schemaVersion = 1;
        config.feePolicyEpoch = 2;
        config.configHash = bytes32(uint256(7));
        assertEq(abi.encode(config).length, 7 * 32);
        bytes memory callData = abi.encodeCall(IFeeRegistry.createFeePolicyEpoch, (config));
        assertEq(abiSelector(callData), IFeeRegistry.createFeePolicyEpoch.selector);
        assertEq(callData.length, 4 + 7 * 32);
    }

    function testEpochRecordAddsStatusSealedAndExists() public pure {
        FeePolicyEpochRecord memory record;
        record.status = FeePolicyEpochStatus.DRAFT;
        record.isSealed = true;
        record.exists = true;
        assertEq(abi.encode(record).length, 10 * 32);
    }
}
