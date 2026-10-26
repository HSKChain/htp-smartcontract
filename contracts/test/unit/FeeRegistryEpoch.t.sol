// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

contract FeeRegistryEpochTest is FeeRegistryTestBase {
    FeeRegistry internal registry;

    function setUp() public override {
        super.setUp();
        registry = feeRegistry;
    }

    function testGovernanceCreatesCanonicalDraftEpoch() public {
        FeePolicyEpochConfig memory config = _epoch(1);

        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        FeePolicyEpochRecord memory record = registry.getFeePolicyEpoch(1);
        assertTrue(record.exists);
        assertFalse(record.isSealed);
        assertEq(uint8(record.status), uint8(FeePolicyEpochStatus.DRAFT));
        assertEq(record.config.configHash, config.configHash);
        assertEq(record.config.quoteValidFrom, config.quoteValidFrom);
        assertEq(record.config.quoteValidUntil, config.quoteValidUntil);
        assertEq(record.config.settlementValidUntil, config.settlementValidUntil);
    }

    function testGovernanceSealsDraftEpochWithExactStoredAndRecomputedHash() public {
        FeePolicyEpochConfig memory config = _epoch(1);
        vm.startPrank(address(timelock));
        registry.createFeePolicyEpoch(config);
        registry.sealFeePolicyEpoch(1, config.configHash);
        vm.stopPrank();

        FeePolicyEpochRecord memory record = registry.getFeePolicyEpoch(1);
        assertTrue(record.isSealed);
        assertEq(uint8(record.status), uint8(FeePolicyEpochStatus.DRAFT));
        assertEq(record.config.configHash, config.configHash);
    }

    function testActivatingNewSealedEpochAtomicallyMovesOldActiveToLegacyServing() public {
        _publishGlobalFeeEpoch(1);
        _publishGlobalFeeEpoch(2);

        assertEq(uint8(registry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING));
        assertEq(uint8(registry.getFeePolicyEpoch(2).status), uint8(FeePolicyEpochStatus.ACTIVE));
    }

    function testGovernanceMovesExpiredActiveEpochToLegacyThenClosesAfterSettlementWindow() public {
        FeePolicyEpochConfig memory config = _publishGlobalFeeEpoch(1);

        vm.warp(config.quoteValidUntil + 1);
        vm.prank(address(timelock));
        registry.moveFeePolicyEpochToLegacyServing(1, bytes32(uint256(0xE301)));
        assertEq(uint8(registry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING));

        vm.warp(config.settlementValidUntil + 1);
        vm.prank(address(timelock));
        registry.closeFeePolicyEpoch(1, bytes32(uint256(0xE302)));

        assertEq(uint8(registry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.CLOSED));
    }

    function testCreateRejectsNonSequentialEpochInvalidTimeChainAndHashWithoutState() public {
        FeePolicyEpochConfig memory config = _epoch(2);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochSequenceMismatch.selector, uint64(1), uint64(2)));
        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        config = _epoch(1);
        config.quoteValidFrom = 0;
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.InvalidFeePolicyEpochValidity.selector,
                config.quoteValidFrom,
                config.quoteValidUntil,
                config.settlementValidUntil
            )
        );
        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        config = _epoch(1);
        config.chainId = block.chainid + 1;
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigChainMismatch.selector, block.chainid, block.chainid + 1)
        );
        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        config = _epoch(1);
        bytes32 recomputedHash = config.configHash;
        config.configHash = bytes32(uint256(config.configHash) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.FeePolicyEpochConfigHashMismatch.selector, config.configHash, recomputedHash
            )
        );
        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        assertFalse(registry.getFeePolicyEpoch(1).exists);
        assertFalse(registry.getFeePolicyEpoch(2).exists);
    }

    function testSealAndActivationRejectWrongHashesUnsealedOrOutsideQuoteWindow() public {
        FeePolicyEpochConfig memory config = _epoch(1);
        vm.prank(address(timelock));
        registry.createFeePolicyEpoch(config);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochNotSealed.selector, uint64(1)));
        vm.prank(address(timelock));
        registry.activateFeePolicyEpoch(1, config.configHash, bytes32(0));

        bytes32 wrongHash = bytes32(uint256(config.configHash) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.FeePolicyEpochExpectedHashMismatch.selector, wrongHash, config.configHash, config.configHash
            )
        );
        vm.prank(address(timelock));
        registry.sealFeePolicyEpoch(1, wrongHash);

        vm.prank(address(timelock));
        registry.sealFeePolicyEpoch(1, config.configHash);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.FeePolicyEpochOutsideQuoteWindow.selector, uint64(1), uint64(block.timestamp)
            )
        );
        vm.prank(address(timelock));
        registry.activateFeePolicyEpoch(1, config.configHash, bytes32(0));

        FeePolicyEpochRecord memory unchanged = registry.getFeePolicyEpoch(1);
        assertTrue(unchanged.isSealed);
        assertEq(uint8(unchanged.status), uint8(FeePolicyEpochStatus.DRAFT));
    }

    function _publishGlobalFeeEpoch(uint64 epochNumber) private returns (FeePolicyEpochConfig memory epoch) {
        epoch = _createEpoch(epochNumber);
        FeeConfig memory fee = _feeConfig(epochNumber, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        registry.activateFeeVersion(fee.feeVersionId, fee.configHash);
        _activateEpoch(epoch, fee.feeVersionId);
    }

    function _epoch(uint64 epoch) private view returns (FeePolicyEpochConfig memory config) {
        config = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: epoch,
            chainId: block.chainid,
            quoteValidFrom: uint64(block.timestamp + 1 days),
            quoteValidUntil: uint64(block.timestamp + 30 days),
            settlementValidUntil: uint64(block.timestamp + 60 days),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);
    }
}
