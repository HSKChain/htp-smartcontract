// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {FeeConfig, FeePolicyEpochConfig, RoundingMode} from "src/types/HTPTypes.sol";

contract FeeConfigHashHarness {
    function epoch(FeePolicyEpochConfig calldata epochConfig) external pure returns (bytes32) {
        return HTPHashing.hashFeePolicyEpochConfig(epochConfig);
    }

    function constraint(FeeConfig calldata feeTerms) external pure returns (bytes32) {
        return HTPHashing.hashFeeConstraint(feeTerms);
    }

    function feeConfig(FeeConfig calldata value) external pure returns (bytes32) {
        return HTPHashing.hashFeeConfig(value);
    }
}

contract FeeConfigHashTest is Test {
    bytes32 private constant CONSTRAINT_HASH = 0x96fd3a47b56b27d4bf98c87953437d926ac54b6da606e58bcf17cc646793488a;
    FeeConfigHashHarness private immutable HARNESS = new FeeConfigHashHarness();

    function testEpochConstraintAndConfigHashesMatchBootstrap() public view {
        FeePolicyEpochConfig memory epoch = SchemaFixtures.feePolicyEpochConfig();
        FeeConfig memory config = SchemaFixtures.feeConfig();
        assertEq(HARNESS.epoch(epoch), 0x84d5f3565bcf597a6fc1ccbfec2f0aaa3de161b5af59cd861bc7357e97c958b0);
        assertEq(HARNESS.constraint(config), CONSTRAINT_HASH);
        assertEq(HARNESS.feeConfig(config), 0x22aaea28af57be5b799a7133eaf0918499c227c5e1d3e03acdfb9f89f3ed8706);
        config.configHash = bytes32(uint256(1));
        assertEq(HARNESS.feeConfig(config), 0x22aaea28af57be5b799a7133eaf0918499c227c5e1d3e03acdfb9f89f3ed8706);
    }

    function testRatesCapsRoundingTokenCollectorAndValidityAreCommitted() public view {
        FeeConfig memory config = SchemaFixtures.feeConfig();
        config.investorRateBps += 1;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.investorHasCap = false;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.investorCapAmount += 1;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.makerRateBps += 1;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.makerHasCap = true;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.makerCapAmount += 1;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.roundingMode = RoundingMode.NONE;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.settlementToken = address(0xc002);
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.settlementTokenConfigId = _flip(config.settlementTokenConfigId);
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.settlementTokenConfigHash = _flip(config.settlementTokenConfigHash);
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.collector = address(0xc012);
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.validFrom += 1;
        _assertConstraintChanged(config);
        config = SchemaFixtures.feeConfig();
        config.validUntil += 1;
        _assertConstraintChanged(config);
    }

    function testFeeConfigCommitsEpochScopeConstraintAndReplacement() public view {
        FeeConfig memory config = SchemaFixtures.feeConfig();
        bytes32 expected = 0x22aaea28af57be5b799a7133eaf0918499c227c5e1d3e03acdfb9f89f3ed8706;
        config.feePolicyEpoch += 1;
        assertNotEq(HARNESS.feeConfig(config), expected);
        config = SchemaFixtures.feeConfig();
        config.matchedScopeHash = _flip(config.matchedScopeHash);
        assertNotEq(HARNESS.feeConfig(config), expected);
        config = SchemaFixtures.feeConfig();
        config.feeConstraintHash = _flip(config.feeConstraintHash);
        assertNotEq(HARNESS.feeConfig(config), expected);
        config = SchemaFixtures.feeConfig();
        config.replacesFeeVersionId = bytes32(uint256(1));
        assertNotEq(HARNESS.feeConfig(config), expected);
    }

    function _assertConstraintChanged(FeeConfig memory config) private view {
        assertNotEq(HARNESS.constraint(config), CONSTRAINT_HASH);
    }

    function _flip(bytes32 value) private pure returns (bytes32) {
        return bytes32(uint256(value) ^ 1);
    }
}
