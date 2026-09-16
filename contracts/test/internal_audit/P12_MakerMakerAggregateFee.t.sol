// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {FeeMath} from "src/libraries/FeeMath.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {FeeConfig, ParticipantType, ScopeType} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

/*
 * P12：Maker–Maker 路径下可登记费率有效聚合可达 20% —— 已修复，断言已反转
 *
 * 原缺陷：
 * - 登记期 `_validateFeeTerms` 只约束 `investorRateBps + makerRateBps ≤ 1000`
 * - 结算 `FeeMath.tryCalculate` 按参与方身份各取一档；MM 成交两腿都取 `makerRateBps`
 * - 有效聚合是 `2×makerRate`，不是两档之和
 * - 后果：`investor=0, maker=1000` 可合法登记，MM 路径 collectorCredit=0.2P，
 *   击穿设计文档「把一次费率笔误的爆炸半径压到 10%」的承诺
 * - 卖方净收仍为 0.9P，M-12「卖方恒正」未破
 *
 * 可达的身份组合（见 DvPCurrentStateValidator._feeAmountsMatch）只有三个：
 * quotingMaker 一侧恒为 MAKER，所以是 (I,M)、(M,I)、(M,M)。(INVESTOR, INVESTOR)
 * 构造不出来，因此最坏可达聚合是 `max(i+m, 2m)` 而不是 `2×max(i,m)` 的每一项都可达。
 *
 * 修复：
 * - 登记期上限改判 `2×max(investor, maker) ≤ MAX_AGGREGATE_FEE_BPS`，即单档 ≤ 500 bps
 * - 取保守的单档口径而非精确的 `max(i+m, 2m)`，是为了不把「quotingMaker 恒为 MAKER」
 *   这个跨模块事实硬编码进 FeeRegistry
 * - 三个可达组合的聚合因此一律 ≤ 1000 bps
 */
contract P12_MakerMakerAggregateFeeTest is FeeRegistryTestBase {
    /// @notice 原 PoC 反转：让 MM 路径达到 20% 的那个配置已经登记不进去
    function test_makerOnlyRateAtFullAggregateIsRejectedAtRegistration() public {
        _createEpoch(1);

        // 登记期旧口径下合法（两档之和 = 1000），但 MM 路径的有效聚合是 2000
        FeeConfig memory config = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        config.investorRateBps = 0;
        config.makerRateBps = 1_000;
        config.investorHasCap = false;
        config.investorCapAmount = 0;
        config.makerHasCap = false;
        config.makerCapAmount = 0;
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AggregateFeeRateOutOfRange.selector, uint256(2_000), FeeMath.MAX_AGGREGATE_FEE_BPS
            )
        );
        _registerFee(config);
    }

    /// @notice 上限是紧的而不是过度收紧：单档取满 500 仍可登记，MM 聚合恰好 10%
    function test_halfRateStillRegistersAndMakerMakerAggregateLandsExactlyOnTheBound() public {
        _createEpoch(1);

        FeeConfig memory config = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        config.investorRateBps = 500;
        config.makerRateBps = 500;
        config.investorHasCap = false;
        config.investorCapAmount = 0;
        config.makerHasCap = false;
        config.makerCapAmount = 0;
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);

        _registerFee(config);
        assertEq(feeRegistry.getFeeVersion(config.feeVersionId).config.makerRateBps, 500);

        uint256 principal = 1_000_000;
        // 三个可达组合逐一核对，聚合都恰好落在 1000 bps 上限而不越过
        _assertAggregate(principal, ParticipantType.MAKER, ParticipantType.MAKER, config, 100_000);
        _assertAggregate(principal, ParticipantType.INVESTOR, ParticipantType.MAKER, config, 100_000);
        _assertAggregate(principal, ParticipantType.MAKER, ParticipantType.INVESTOR, config, 100_000);
    }

    /// @notice 对照：两档之和超限仍被拒，只是报告的是最坏可达聚合 2×600 而非之和 1100
    function test_registrationStillRejectsInvestorPlusMakerAboveTenPercent() public {
        _createEpoch(1);

        FeeConfig memory config = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        config.investorRateBps = 600;
        config.makerRateBps = 500;
        config.investorHasCap = false;
        config.investorCapAmount = 0;
        config.makerHasCap = false;
        config.makerCapAmount = 0;
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AggregateFeeRateOutOfRange.selector, uint256(1_200), FeeMath.MAX_AGGREGATE_FEE_BPS
            )
        );
        _registerFee(config);
    }

    function _assertAggregate(
        uint256 principal,
        ParticipantType buyerType,
        ParticipantType sellerType,
        FeeConfig memory config,
        uint256 expectedCollectorCredit
    ) private pure {
        (FeeMath.CalculationStatus status,,,,, uint256 collectorCredit) =
            FeeMath.tryCalculate(principal, buyerType, sellerType, config);
        assertEq(uint8(status), uint8(FeeMath.CalculationStatus.SUCCESS));
        assertEq(collectorCredit, expectedCollectorCredit);
        assertLe(collectorCredit * 10_000, principal * FeeMath.MAX_AGGREGATE_FEE_BPS);
    }
}
