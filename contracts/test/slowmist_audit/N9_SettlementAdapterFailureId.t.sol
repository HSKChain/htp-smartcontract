// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

/// @notice SlowMist N9: strict settlement reports the adapter config that actually failed.
contract SlowMistN9SettlementAdapterFailureIdTest is UsdySettlementFixture {
    function test_N9_SettlementAdapterFailureReportsSettlementConfigId() public {
        SettlementParams memory params = _validUsdyBuyParams();
        bytes32 settlementAdapterConfigId = settlementTokenConfig.adapterConfigId;
        assertNotEq(params.snapshot.adapterConfigId, settlementAdapterConfigId);

        _pauseAdapter(settlementAdapterConfigId);
        _assertAdapterInactive(params, settlementAdapterConfigId);
    }

    function test_N9_AssetAdapterFailureStillReportsAssetConfigId() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _pauseAdapter(params.snapshot.adapterConfigId);
        _assertAdapterInactive(params, params.snapshot.adapterConfigId);
    }

    function test_N9_BothAdapterFailuresReportAssetSideFirst() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _pauseAdapter(params.snapshot.adapterConfigId);
        _pauseAdapter(settlementTokenConfig.adapterConfigId);

        _assertAdapterInactive(params, params.snapshot.adapterConfigId);
    }

    function _assertAdapterInactive(SettlementParams memory params, bytes32 expectedConfigId) private {
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.AdapterInactive.selector, expectedConfigId));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function _pauseAdapter(bytes32 configId) private {
        vm.prank(REGISTRY_PAUSER);
        adapterRegistry.pauseAdapter(configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
    }
}
