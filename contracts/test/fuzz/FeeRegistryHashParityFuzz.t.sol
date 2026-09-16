// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {FeeConfig, FeePolicyEpochConfig, FeeVersionRecord, RoundingMode, ScopeType} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

// FeeRegistry 用紧凑 calldata/memory 拷贝重算 epoch/config/constraint 哈希，字节偏移硬编码了
// HTPTypes 里的字段顺序；HTPHashing 按字段名逐个赋值。两者必须逐位一致，否则链下用 HTPHashing
// 算出的 configHash 会被链上拒收，或更糟：偏移错位后仍能算出某个「看起来合法」的哈希。
// 固定向量只覆盖一组取值，相邻字段恰好同值时抓不到错位，所以这里用随机取值压。
contract FeeRegistryHashParityFuzzTest is FeeRegistryTestBase {
    function testFuzzEpochHashParityAcrossCreateAndSeal(
        uint64 quoteValidFrom,
        uint64 quoteWindow,
        uint64 settlementWindow
    ) public {
        quoteValidFrom = uint64(bound(quoteValidFrom, 1, type(uint32).max));
        quoteWindow = uint64(bound(quoteWindow, 0, type(uint32).max));
        settlementWindow = uint64(bound(settlementWindow, 0, type(uint32).max));

        FeePolicyEpochConfig memory config = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: 1,
            chainId: block.chainid,
            quoteValidFrom: quoteValidFrom,
            quoteValidUntil: quoteValidFrom + quoteWindow,
            settlementValidUntil: quoteValidFrom + quoteWindow + settlementWindow,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);

        // 走 calldata 版本：链上重算必须等于 HTPHashing 的结果，否则 revert。
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(config);

        // 走 memory 版本：从 storage 读回后重算，同样必须一致。
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(config.feePolicyEpoch, config.configHash);

        assertEq(feeRegistry.getFeePolicyEpoch(config.feePolicyEpoch).config.configHash, config.configHash);
    }

    function testFuzzFeeConfigAndConstraintHashParityOnRegister(
        uint16 investorRateBps,
        uint256 investorCapAmount,
        uint16 makerRateBps,
        bool makerHasCap,
        uint256 makerCapAmount,
        address collector,
        uint64 validFromOffset
    ) public {
        vm.assume(collector != address(0));
        // 登记期强制单档 ≤ MAX_AGGREGATE_FEE_BPS/2（Maker–Maker 成交两腿共用同一档，
        // 聚合是 2×rate），超限的组合根本写不进 Registry，因此哈希一致性只需在
        // 可登记的费率空间上验证。
        investorRateBps = uint16(bound(investorRateBps, 0, FeeMath.MAX_AGGREGATE_FEE_BPS / 2));
        makerRateBps = uint16(bound(makerRateBps, 0, FeeMath.MAX_AGGREGATE_FEE_BPS / 2));
        if (!makerHasCap) makerCapAmount = 0;

        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        uint64 span = epoch.settlementValidUntil - epoch.quoteValidFrom;
        uint64 validFrom = epoch.quoteValidFrom + uint64(bound(validFromOffset, 0, span));

        FeeConfig memory config = _parityFeeConfig(epoch.feePolicyEpoch, validFrom);
        config.investorRateBps = investorRateBps;
        config.investorCapAmount = investorCapAmount;
        config.makerRateBps = makerRateBps;
        config.makerHasCap = makerHasCap;
        config.makerCapAmount = makerCapAmount;
        config.collector = collector;
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);

        // registerFeeVersion 同时重算 constraint 与 config 两个哈希，任一分叉都会 revert。
        _registerFee(config);

        FeeVersionRecord memory record = feeRegistry.getFeeVersion(config.feeVersionId);
        assertEq(record.config.feeConstraintHash, config.feeConstraintHash);
        assertEq(record.config.configHash, config.configHash);
    }

    function _parityFeeConfig(uint64 feePolicyEpoch, uint64 validFrom) private view returns (FeeConfig memory config) {
        bytes32 scopeKeyHash = assetVersionConfig.assetVersionId;
        bytes32 matchedScopeHash = FeeScope.matchedHash(feePolicyEpoch, ScopeType.ASSET_VERSION, scopeKeyHash);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: feePolicyEpoch,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: scopeKeyHash,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 0,
            investorHasCap: true,
            investorCapAmount: 0,
            makerRateBps: 0,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: validFrom,
            validUntil: _epochSettlementValidUntil(feePolicyEpoch),
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
    }

    function _epochSettlementValidUntil(uint64 feePolicyEpoch) private view returns (uint64) {
        return feeRegistry.getFeePolicyEpoch(feePolicyEpoch).config.settlementValidUntil;
    }
}
