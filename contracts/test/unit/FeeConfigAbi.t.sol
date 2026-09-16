// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {FeeConfig, FeeVersionRecord, ScopeType} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract FeeConfigAbiTest is Test {
    function testFeeConfigUsesDistinctScopeKeyAndMatchedScopeHashes() public pure {
        FeeConfig memory config;
        config.schemaVersion = 1;
        config.scopeType = ScopeType.ASSET_VERSION;
        config.scopeKeyHash = bytes32(uint256(7));
        config.matchedScopeHash = bytes32(uint256(8));
        config.settlementToken = address(0xB0B);
        config.feeConstraintHash = bytes32(uint256(22));
        config.configHash = bytes32(uint256(24));
        assertEq(abi.encode(config).length, 24 * 32);
        bytes memory callData = abi.encodeCall(IFeeRegistry.registerFeeVersion, (config));
        assertEq(abiSelector(callData), IFeeRegistry.registerFeeVersion.selector);
        assertEq(callData.length, 4 + 24 * 32);
        assertTrue(config.scopeKeyHash != config.matchedScopeHash);
        assertTrue(config.feeConstraintHash != bytes32(0));
    }

    function testFeeRecordOwnsStatusAndExistence() public pure {
        FeeVersionRecord memory record;
        record.exists = true;
        assertEq(abi.encode(record).length, 26 * 32);
    }
}
