// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {FeeConfig, FeePolicyEpochConfig, ReasonCode, ScopeType} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

contract FeeResolverTest is FeeRegistryTestBase {
    function testResolverReturnsHighestPriorityAssetVersionMatchFromRegistryFacts() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory global = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        FeeConfig memory chain = _feeConfig(1, ScopeType.CHAIN, bytes32(block.chainid), 1, bytes32(0));
        FeeConfig memory assetClass =
            _feeConfig(1, ScopeType.ASSET_CLASS, bytes32(uint256(assetVersionConfig.assetClass)), 1, bytes32(0));
        FeeConfig memory instrument = _feeConfig(1, ScopeType.INSTRUMENT, ECONOMIC_ASSET_ID_HASH, 1, bytes32(0));
        FeeConfig memory assetVersion =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(global);
        _registerFee(chain);
        _registerFee(assetClass);
        _registerFee(instrument);
        _registerFee(assetVersion);
        _sealEpoch(epoch);
        _activateFee(global);
        _activateFee(chain);
        _activateFee(assetClass);
        _activateFee(instrument);
        _activateFee(assetVersion);
        _activateEpoch(epoch, assetVersion.feeVersionId);

        (bytes32 feeVersionId, bytes32 matchedScopeHash) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);

        assertEq(feeVersionId, assetVersion.feeVersionId);
        assertEq(matchedScopeHash, assetVersion.matchedScopeHash);
    }

    function testPausedHigherScopeDoesNotFallBackToActiveGlobal() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory global = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        FeeConfig memory assetVersion =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(global);
        _registerFee(assetVersion);
        _sealEpoch(epoch);
        _activateFee(global);
        _activateFee(assetVersion);
        _activateEpoch(epoch, assetVersion.feeVersionId);

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(assetVersion.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xE324)));

        (bytes32 feeVersionId, bytes32 matchedScopeHash) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        assertEq(feeVersionId, assetVersion.feeVersionId);
        assertEq(matchedScopeHash, assetVersion.matchedScopeHash);
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                global.feeVersionId,
                global.matchedScopeHash,
                global.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                assetVersion.feeVersionId,
                assetVersion.matchedScopeHash,
                assetVersion.feeConstraintHash
            )
        );
    }

    function testExecutableDiagnosticRechecksResolverStatusTimeReferencesAndHashesWithoutGrantingAuthorization()
        public
    {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(config);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        _activateEpoch(epoch, config.feeVersionId);

        assertTrue(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                bytes32(uint256(config.feeVersionId) ^ 1),
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                2,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                bytes32(uint256(assetVersionConfig.assetVersionId) ^ 1),
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                bytes32(uint256(config.matchedScopeHash) ^ 1),
                config.feeConstraintHash
            )
        );
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                bytes32(uint256(config.feeConstraintHash) ^ 1)
            )
        );

        bytes memory settlementTokenCode = address(settlementToken).code;
        vm.etch(address(settlementToken), hex"00");
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
        vm.etch(address(settlementToken), settlementTokenCode);

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(config.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xE321)));
        assertFalse(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );

        // PAUSED 不能直接废弃：DEPRECATED 可结算而 PAUSED 不可，那条边等于把停掉的
        // 费率不可逆地重新放行。要退役先恢复成 ACTIVE。
        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            config.feeVersionId, config.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xE322))
        );
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(config.feeVersionId, ReasonCode.PLANNED_MIGRATION, bytes32(uint256(0xE323)));
        assertTrue(
            feeRegistry.isFeeVersionExecutable(
                1,
                assetVersionConfig.assetVersionId,
                config.feeVersionId,
                config.matchedScopeHash,
                config.feeConstraintHash
            )
        );
    }

    function testResolverFallsBackAtEveryLevelAndNewEpochDoesNotChangeHistoricalResult() public {
        FeeConfig memory global = _publishSingleScope(1, ScopeType.GLOBAL, bytes32(0));
        _assertResolved(1, global);

        FeeConfig memory chain = _publishSingleScope(2, ScopeType.CHAIN, bytes32(block.chainid));
        _assertResolved(2, chain);
        _assertResolved(1, global);

        FeeConfig memory assetClass =
            _publishSingleScope(3, ScopeType.ASSET_CLASS, bytes32(uint256(assetVersionConfig.assetClass)));
        _assertResolved(3, assetClass);

        FeeConfig memory instrument = _publishSingleScope(4, ScopeType.INSTRUMENT, ECONOMIC_ASSET_ID_HASH);
        _assertResolved(4, instrument);

        FeeConfig memory assetVersion =
            _publishSingleScope(5, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId);
        _assertResolved(5, assetVersion);
        _assertResolved(1, global);
    }

    function testResolverFailsClosedForUnknownAssetAndNoConfiguredScope() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory unrelated = _feeConfig(1, ScopeType.ASSET_VERSION, bytes32(uint256(0xBEEF)), 1, bytes32(0));
        _registerFee(unrelated);
        _sealEpoch(epoch);
        _activateFee(unrelated);
        _activateEpoch(epoch, unrelated.feeVersionId);

        bytes32 unknownAsset = bytes32(uint256(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigNotFound.selector, unknownAsset));
        feeRegistry.resolveApplicableFee(1, unknownAsset);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeResolverNoMatch.selector, uint64(1), assetVersionConfig.assetVersionId)
        );
        feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
    }

    function _publishSingleScope(uint64 epochNumber, ScopeType scopeType, bytes32 scopeKeyHash)
        private
        returns (FeeConfig memory config)
    {
        FeePolicyEpochConfig memory epoch = _createEpoch(epochNumber);
        config = _feeConfig(epochNumber, scopeType, scopeKeyHash, 1, bytes32(0));
        _registerFee(config);
        _sealEpoch(epoch);
        _activateFee(config);
        _activateEpoch(epoch, config.feeVersionId);
    }

    function _activateFee(FeeConfig memory config) private {
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
    }

    function _assertResolved(uint64 epochNumber, FeeConfig memory expected) private view {
        (bytes32 feeVersionId, bytes32 matchedScopeHash) =
            feeRegistry.resolveApplicableFee(epochNumber, assetVersionConfig.assetVersionId);
        assertEq(feeVersionId, expected.feeVersionId);
        assertEq(matchedScopeHash, expected.matchedScopeHash);
    }
}
