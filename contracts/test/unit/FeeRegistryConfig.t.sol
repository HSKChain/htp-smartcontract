// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {Roles} from "src/libraries/Roles.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    ParticipantType,
    ReasonCode,
    RoundingMode,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract FeeRegistryV2 is FeeRegistry {
    function phase11V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract FeeRegistryConfigTest is FeeRegistryTestBase {
    function testConfigurerRegistersCanonicalFeeVersionInUnsealedDraftEpoch() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(epoch.feePolicyEpoch, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));

        _registerFee(config);

        FeeVersionRecord memory record = feeRegistry.getFeeVersion(config.feeVersionId);
        assertTrue(record.exists);
        assertEq(uint8(record.status), uint8(FeeVersionStatus.REGISTERED));
        assertEq(record.config.feeVersionId, config.feeVersionId);
        assertEq(record.config.matchedScopeHash, config.matchedScopeHash);
        assertEq(record.config.feeConstraintHash, config.feeConstraintHash);
        assertEq(record.config.configHash, config.configHash);
    }

    function testGovernanceAndPauserControlFeeVersionLifecycleWithoutChangingConfig() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(epoch.feePolicyEpoch, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(config);
        _sealEpoch(epoch);

        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        assertEq(uint8(feeRegistry.getFeeVersion(config.feeVersionId).status), uint8(FeeVersionStatus.ACTIVE));

        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(config.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xE311)));
        assertEq(uint8(feeRegistry.getFeeVersion(config.feeVersionId).status), uint8(FeeVersionStatus.PAUSED));

        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            config.feeVersionId, config.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xE312))
        );
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(config.feeVersionId, ReasonCode.PLANNED_MIGRATION, bytes32(uint256(0xE313)));

        FeeVersionRecord memory deprecated = feeRegistry.getFeeVersion(config.feeVersionId);
        assertEq(uint8(deprecated.status), uint8(FeeVersionStatus.DEPRECATED));
        assertEq(deprecated.config.configHash, config.configHash);
    }

    function testScopeRevisionsAreLinearAndGovernanceSelectsServingVersionBeforeEpochActivation() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory first =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(first);
        FeeConfig memory second =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 2, first.feeVersionId);
        _registerFee(second);
        _sealEpoch(epoch);

        // Configurer 的 latest 是 second，但 Governance 可选择已审核的 first 进入 serving。
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(first.feeVersionId, first.configHash);
        _activateEpoch(epoch);

        (bytes32 resolvedId, bytes32 resolvedScope) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        assertEq(resolvedId, first.feeVersionId);
        assertEq(resolvedScope, first.matchedScopeHash);
        assertEq(feeRegistry.getFeeVersion(first.feeVersionId).config.configHash, first.configHash);
        assertEq(uint8(feeRegistry.getFeeVersion(first.feeVersionId).status), uint8(FeeVersionStatus.ACTIVE));
        assertEq(uint8(feeRegistry.getFeeVersion(second.feeVersionId).status), uint8(FeeVersionStatus.REGISTERED));

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigAlreadyExists.selector, second.feeVersionId));
        _registerFee(second);

        FeeConfig memory third =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 3, second.feeVersionId);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochSealed.selector, uint64(1)));
        _registerFee(third);
        assertFalse(feeRegistry.getFeeVersion(third.feeVersionId).exists);

        // Epoch ACTIVE 后不能再把未批准的 latest 候选切入 serving。
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.UnauthorizedStateTransition.selector,
                second.feeVersionId,
                uint8(FeePolicyEpochStatus.ACTIVE),
                uint8(FeePolicyEpochStatus.DRAFT)
            )
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(second.feeVersionId, second.configHash);
    }

    function testRegisterRejectsNonCanonicalRatesCapsRoundingAndValidityWithoutWritingHistory() public {
        _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));

        config.investorRateBps = 10_001;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeRateOutOfRange.selector, ParticipantType.INVESTOR, uint16(10_001))
        );
        _registerFee(config);

        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorHasCap = false;
        config.investorCapAmount = 1;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeCapNotCanonical.selector, ParticipantType.INVESTOR, false, uint256(1))
        );
        _registerFee(config);

        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.makerRateBps = 10_001;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.FeeRateOutOfRange.selector, ParticipantType.MAKER, uint16(10_001))
        );
        _registerFee(config);

        // 逐档合法不代表组合合法：两档各 100% 会让买方付两倍本金、卖方净收零，
        // 而守恒式 debit == credit + collector 对此仍然成立，结算期的重算只会
        // 确认这组数字。聚合上限是唯一能拦下它的地方。
        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorRateBps = 10_000;
        config.makerRateBps = 10_000;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AggregateFeeRateOutOfRange.selector, uint256(20_000), uint256(1_000))
        );
        _registerFee(config);

        // 单档 100% 同样被聚合上限拦下，这正是「卖方零收款」的唯一入口。
        // 报告的是最坏可达聚合 2×10000，不是两档之和。
        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorRateBps = 0;
        config.makerRateBps = 10_000;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AggregateFeeRateOutOfRange.selector, uint256(20_000), uint256(1_000))
        );
        _registerFee(config);

        // 紧邻边界：单档 501 的最坏可达聚合是 1002，超一点点也要拦。
        // 上限按单档而非两档之和判断，正是为了堵住 Maker–Maker 路径的 2×makerRate。
        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorRateBps = 0;
        config.makerRateBps = 501;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AggregateFeeRateOutOfRange.selector, uint256(1_002), uint256(1_000))
        );
        _registerFee(config);

        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.roundingMode = RoundingMode.NONE;
        _rehash(config);
        vm.expectRevert(HTPErrors.InvalidFeeConfig.selector);
        _registerFee(config);

        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.validFrom -= 1;
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.FeeValidityOutsideEpoch.selector, uint64(1), config.validFrom, config.validUntil
            )
        );
        _registerFee(config);

        assertFalse(feeRegistry.getFeeVersion(config.feeVersionId).exists);
    }

    // 聚合上限是闭区间：恰好等于上限的组合必须能登记，否则边界被写成排他，
    // 运营侧会在一个看不出原因的地方被卡住。
    // 上限判的是最坏可达聚合 2×较高档，所以「恰好可登记」的极值是两档都取 500，
    // 而不是任意加起来等于 1000 的组合：400/600 会在 Maker–Maker 路径上收 12%。
    function testAggregateFeeRateAtTheCapIsRegistrable() public {
        _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorRateBps = 500;
        config.makerRateBps = 500;
        _rehash(config);
        _registerFee(config);

        assertEq(feeRegistry.getFeeVersion(config.feeVersionId).config.investorRateBps, 500);
        assertEq(feeRegistry.getFeeVersion(config.feeVersionId).config.makerRateBps, 500);
    }

    function testRegisterRejectsNoneScopeWithoutWritingHistory() public {
        _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.scopeType = ScopeType.NONE;
        config.scopeKeyHash = bytes32(uint256(0xA55E7));
        config.matchedScopeHash = 0x9791c9074fc58c25bbb0896e91161607c6a3175377c36c9c42da796e56dad6c7;
        config.feeVersionId = ConfigId.derive(
            ConfigId.FEE_NAMESPACE, config.schemaVersion, config.chainId, config.matchedScopeHash, config.revision
        );
        _rehash(config);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.InvalidFeeScopeKey.selector, ScopeType.NONE, config.scopeKeyHash)
        );
        _registerFee(config);
        assertFalse(feeRegistry.getFeeVersion(config.feeVersionId).exists);
    }

    function testExplicitZeroCapIsValidAndMeansZeroRatherThanUnlimited() public {
        _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.investorHasCap = true;
        config.investorCapAmount = 0;
        _rehash(config);

        _registerFee(config);

        FeeVersionRecord memory record = feeRegistry.getFeeVersion(config.feeVersionId);
        assertTrue(record.exists);
        assertTrue(record.config.investorHasCap);
        assertEq(record.config.investorCapAmount, 0);
    }

    function testRegisterRequiresExactActiveSettlementTokenReferenceAndCollector() public {
        _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.settlementTokenConfigHash = bytes32(uint256(config.settlementTokenConfigHash) ^ 1);
        _rehash(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.settlementTokenConfigId,
                config.settlementTokenConfigHash
            )
        );
        _registerFee(config);

        config = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        config.collector = address(0);
        _rehash(config);
        vm.expectRevert(HTPErrors.InvalidFeeConfig.selector);
        _registerFee(config);
        assertFalse(feeRegistry.getFeeVersion(config.feeVersionId).exists);
    }

    // 登记只要求结算币已存在、内容哈希与 runtime 基线一致，不要求 ACTIVE；
    // 激活才要求 ACTIVE。这支持「一批登记 + 一批激活」的两笔上线流程。
    function testRegisterAcceptsNonActiveSettlementTokenButActivationStillRequiresActive() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));

        vm.prank(PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            settlementTokenConfig.configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        // 结算币非 ACTIVE：登记仍然成功。
        _registerFee(config);
        assertTrue(feeRegistry.getFeeVersion(config.feeVersionId).exists);

        _sealEpoch(epoch);

        // 但激活必须因结算币非 ACTIVE 而失败。
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.settlementTokenConfigId,
                config.settlementTokenConfigHash
            )
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);

        // 结算币恢复后即可激活。
        vm.prank(address(timelock));
        settlementTokenRegistry.unpauseSettlementToken(
            settlementTokenConfig.configId,
            settlementTokenConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        assertEq(uint8(feeRegistry.getFeeVersion(config.feeVersionId).status), uint8(FeeVersionStatus.ACTIVE));
    }

    function testDuplicateIdentityWinsBeforeReferenceChecksAndNewConfigRejectsRuntimeTokenDrift() public {
        _createEpoch(1);
        FeeConfig memory assetFee =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(assetFee);
        vm.etch(address(settlementToken), hex"00");

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigAlreadyExists.selector, assetFee.feeVersionId));
        _registerFee(assetFee);

        FeeConfig memory globalFee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                globalFee.settlementTokenConfigId,
                globalFee.settlementTokenConfigHash
            )
        );
        _registerFee(globalFee);
        assertFalse(feeRegistry.getFeeVersion(globalFee.feeVersionId).exists);
    }

    function testActivateAndUnpauseRevalidateSettlementTokenRuntime() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(config);
        _sealEpoch(epoch);
        bytes memory settlementTokenCode = address(settlementToken).code;
        vm.etch(address(settlementToken), hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.settlementTokenConfigId,
                config.settlementTokenConfigHash
            )
        );
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);

        vm.etch(address(settlementToken), settlementTokenCode);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.prank(PAUSER);
        feeRegistry.pauseFeeVersion(config.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(0xE314)));
        vm.etch(address(settlementToken), hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.settlementTokenConfigId,
                config.settlementTokenConfigHash
            )
        );
        vm.prank(address(timelock));
        feeRegistry.unpauseFeeVersion(
            config.feeVersionId, config.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(0xE315))
        );
        assertEq(uint8(feeRegistry.getFeeVersion(config.feeVersionId).status), uint8(FeeVersionStatus.PAUSED));
    }

    function testUpgradePreservesEpochScopeFeeRolesAndDependentDvps() public {
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory config =
            _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(config);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        _activateEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        dependentDvp.setGlobalPaused(true);

        FeeRegistryV2 nextImplementation = new FeeRegistryV2();
        vm.prank(address(timelock));
        feeRegistry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(FeeRegistryV2(address(feeRegistry)).phase11V2Marker(), 2);
        assertTrue(feeRegistry.getFeePolicyEpoch(1).isSealed);
        assertEq(uint8(feeRegistry.getFeeVersion(config.feeVersionId).status), uint8(FeeVersionStatus.ACTIVE));
        (bytes32 feeVersionId, bytes32 matchedScopeHash) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        assertEq(feeVersionId, config.feeVersionId);
        assertEq(matchedScopeHash, config.matchedScopeHash);
        assertEq(feeRegistry.getDependentDvpCount(), 1);
        assertTrue(feeRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(feeRegistry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));

        FeePolicyEpochConfig memory secondEpoch = _createEpoch(2);
        _sealEpoch(secondEpoch);
        _activateEpoch(secondEpoch);
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING));
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(2).status), uint8(FeePolicyEpochStatus.ACTIVE));
    }

    function _rehash(FeeConfig memory config) private pure {
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
    }
}
