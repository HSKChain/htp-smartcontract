// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeeVersionRecord,
    FundPriceTerms,
    RoundingMode,
    ScopeType,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract SettlementFeeConservationFuzzTest is DvPPreCheckTestBase {
    uint64 private constant FUZZ_EPOCH = 2;

    struct FeeAmounts {
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 buyerDebit;
        uint256 sellerCredit;
        uint256 collectorCredit;
    }

    struct CashBalances {
        uint256 buyer;
        uint256 seller;
        uint256 collector;
    }

    function testFuzzSettlementConservesPrincipalAndCappedFees(uint256 seed) public {
        SettlementParams memory params = _validPreCheckParams();
        uint256 navPerUnit = (1 + uint256(keccak256(abi.encode(seed, uint256(1)))) % 500) * 10_000;
        uint256 principal = _bindPrincipal(params, navPerUnit);
        // 费率只是让 cap 生效的手段：实际费用取 min(floor(P*rate), cap)，所以
        // cap 必须落在费率能产生的金额之内，否则被截断的是费率而不是 cap。
        // 聚合上限把费率压到 5% 一档，cap 的取值范围随之收窄，守恒性验证不受影响。
        uint16 halfCap = uint16(FeeMath.MAX_AGGREGATE_FEE_BPS / 2);
        uint256 maxFeeFromRate = principal * halfCap / 10_000;
        uint256 buyerFee = (seed >> 32) % (maxFeeFromRate + 1);
        uint256 sellerFee = uint256(keccak256(abi.encode(seed, uint256(2)))) % (maxFeeFromRate + 1);
        FeeConfig memory selectedFee = _activateFuzzFee(halfCap, halfCap, true, true, buyerFee, sellerFee);

        // Fees are chosen as signed cap values. No expected amount is derived
        // from the production bps formula; assertions below observe only cash conservation.
        _settleAndAssert(params, selectedFee, _conservedAmounts(principal, buyerFee, sellerFee), principal);
    }

    function testReviewedGoldenCappedAmountsSettleAndConserveCash() public {
        // Reviewed literals are shared with test/unit/FeeMath.t.sol; this test
        // consumes them without recomputing any expected fee from bps.
        SettlementParams memory params = _validPreCheckParams();
        uint256 principal = _bindPrincipal(params, 100_000);
        assertEq(principal, 1_000_000);
        FeeConfig memory selectedFee = _activateFuzzFee(25, 15, true, false, 2_000, 0);
        FeeAmounts memory reviewed = FeeAmounts({
            buyerFee: 2_000, sellerFee: 1_500, buyerDebit: 1_002_000, sellerCredit: 998_500, collectorCredit: 3_500
        });

        _settleAndAssert(params, selectedFee, reviewed, principal);
    }

    function testReviewedGoldenZeroCapAndFloorRoundingSettle() public {
        // Reviewed zero-cap/floor-rounding literals from test/unit/FeeMath.t.sol.
        SettlementParams memory params = _validPreCheckParams();
        uint256 principal = _bindPrincipal(params, 1_000_000);
        assertEq(principal, 10_000_000);
        // 被测的是 cap == 0 把费用截到零这条路径，费率只需大到让 cap 真正生效。
        // 单档上限是 MAX_AGGREGATE_FEE_BPS/2，取满即可。
        FeeConfig memory selectedFee = _activateFuzzFee(uint16(FeeMath.MAX_AGGREGATE_FEE_BPS / 2), 0, true, false, 0, 0);
        FeeAmounts memory reviewed = FeeAmounts({
            buyerFee: 0, sellerFee: 0, buyerDebit: 10_000_000, sellerCredit: 10_000_000, collectorCredit: 0
        });

        _settleAndAssert(params, selectedFee, reviewed, principal);
    }

    function testRegistryStoresNearMaxFeeCapsThroughPublicAbi() public {
        // 被测对象是 cap 的存储上界，不是费率上界；费率取聚合上限内的组合即可。
        uint16 halfCap = uint16(FeeMath.MAX_AGGREGATE_FEE_BPS / 2);
        FeeConfig memory selectedFee =
            _activateFuzzFee(halfCap, halfCap, true, true, type(uint256).max, type(uint256).max);
        FeeVersionRecord memory stored = feeRegistry.getFeeVersion(selectedFee.feeVersionId);

        assertEq(stored.config.investorRateBps, halfCap);
        assertEq(stored.config.makerRateBps, halfCap);
        assertTrue(stored.config.investorHasCap);
        assertTrue(stored.config.makerHasCap);
        assertEq(stored.config.investorCapAmount, type(uint256).max);
        assertEq(stored.config.makerCapAmount, type(uint256).max);
    }

    function _settleAndAssert(
        SettlementParams memory params,
        FeeConfig memory selectedFee,
        FeeAmounts memory amounts,
        uint256 principal
    ) private {
        _bindFeeAndAmounts(params, selectedFee, amounts, principal, CREATED_AT + 1);
        settlementToken.setAllowance(params.snapshot.buyer, address(dvp), amounts.buyerDebit);
        settlementToken.setBalance(params.snapshot.buyer, amounts.buyerDebit + 1);

        CashBalances memory beforeBalances = CashBalances({
            buyer: settlementToken.balanceOf(params.snapshot.buyer),
            seller: settlementToken.balanceOf(params.snapshot.seller),
            collector: settlementToken.balanceOf(params.snapshot.collector)
        });

        vm.prank(EXECUTOR);
        dvp.settle(params);

        _assertSettlementBalances(params, amounts, beforeBalances);
        assertEq(assetToken.balanceOf(params.snapshot.buyer), params.snapshot.executedQuantity);
    }

    function _bindPrincipal(SettlementParams memory params, uint256 navPerUnit)
        private
        view
        returns (uint256 principal)
    {
        bytes memory priceData = abi.encode(
            FundPriceTerms({navPerUnit: navPerUnit, navDate: 20_260_810, navSourceHash: bytes32(uint256(0x201))})
        );
        (bytes32 priceTermsHash,,, uint256 cashPrincipal) =
            calculator.calculate(priceData, params.snapshot.executedQuantity, params.snapshot.assetDecimals);
        params.firmQuote.priceData = priceData;
        params.tradeIntent.priceData = priceData;
        params.snapshot.priceData = priceData;
        params.firmQuote.priceTermsHash = priceTermsHash;
        params.tradeIntent.priceTermsHash = priceTermsHash;
        params.snapshot.priceTermsHash = priceTermsHash;
        return cashPrincipal;
    }

    function _assertSettlementBalances(
        SettlementParams memory params,
        FeeAmounts memory amounts,
        CashBalances memory beforeBalances
    ) private view {
        uint256 buyerPaid =
            beforeBalances.buyer - settlementToken.balanceOf(params.snapshot.buyer);
        uint256 sellerReceived = settlementToken.balanceOf(params.snapshot.seller) - beforeBalances.seller;
        uint256 collectorReceived = settlementToken.balanceOf(params.snapshot.collector) - beforeBalances.collector;
        assertEq(buyerPaid, amounts.buyerDebit);
        assertEq(sellerReceived, amounts.sellerCredit);
        assertEq(collectorReceived, amounts.collectorCredit);
        assertEq(buyerPaid, sellerReceived + collectorReceived);
        assertEq(sellerReceived + amounts.sellerFee, params.snapshot.cashPrincipal);
        assertEq(collectorReceived, amounts.buyerFee + amounts.sellerFee);
    }

    function _conservedAmounts(uint256 principal, uint256 buyerFee, uint256 sellerFee)
        private
        pure
        returns (FeeAmounts memory amounts)
    {
        amounts.buyerFee = buyerFee;
        amounts.sellerFee = sellerFee;
        amounts.buyerDebit = principal + buyerFee;
        amounts.sellerCredit = principal - sellerFee;
        amounts.collectorCredit = buyerFee + sellerFee;
    }

    function _activateFuzzFee(
        uint16 investorRateBps,
        uint16 makerRateBps,
        bool investorHasCap,
        bool makerHasCap,
        uint256 investorCap,
        uint256 makerCap
    ) private returns (FeeConfig memory config) {
        uint64 validFrom = CREATED_AT + 1;
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: FUZZ_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: validFrom,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash =
            FeeScope.matchedHash(FUZZ_EPOCH, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: FUZZ_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionConfig.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: investorRateBps,
            investorHasCap: investorHasCap,
            investorCapAmount: investorCap,
            makerRateBps: makerRateBps,
            makerHasCap: makerHasCap,
            makerCapAmount: makerCap,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: validFrom,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(config);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(FUZZ_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(validFrom);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(FUZZ_EPOCH, epoch.configHash, config.feeVersionId);
    }

    function _bindFeeAndAmounts(
        SettlementParams memory params,
        FeeConfig memory selectedFee,
        FeeAmounts memory amounts,
        uint256 principal,
        uint64 createdAt
    ) private view {
        params.firmQuote.feePolicyEpoch = FUZZ_EPOCH;
        params.tradeIntent.feePolicyEpoch = FUZZ_EPOCH;
        params.snapshot.feePolicyEpoch = FUZZ_EPOCH;
        params.firmQuote.feeVersionId = selectedFee.feeVersionId;
        params.tradeIntent.feeVersionId = selectedFee.feeVersionId;
        params.snapshot.feeVersionId = selectedFee.feeVersionId;
        params.firmQuote.matchedScopeHash = selectedFee.matchedScopeHash;
        params.tradeIntent.matchedScopeHash = selectedFee.matchedScopeHash;
        params.snapshot.matchedScopeHash = selectedFee.matchedScopeHash;
        params.firmQuote.feeConstraintHash = selectedFee.feeConstraintHash;
        params.tradeIntent.feeConstraintHash = selectedFee.feeConstraintHash;
        params.snapshot.feeConstraintHash = selectedFee.feeConstraintHash;
        params.tradeIntent.cashPrincipal = principal;
        params.snapshot.cashPrincipal = principal;
        params.tradeIntent.buyerFee = amounts.buyerFee;
        params.snapshot.buyerFee = amounts.buyerFee;
        params.tradeIntent.sellerFee = amounts.sellerFee;
        params.snapshot.sellerFee = amounts.sellerFee;
        params.tradeIntent.buyerDebit = amounts.buyerDebit;
        params.snapshot.buyerDebit = amounts.buyerDebit;
        params.tradeIntent.sellerCredit = amounts.sellerCredit;
        params.snapshot.sellerCredit = amounts.sellerCredit;
        params.tradeIntent.collectorCredit = amounts.collectorCredit;
        params.snapshot.collectorCredit = amounts.collectorCredit;
        params.snapshot.createdAt = createdAt;
        _resign(params);
    }
}
