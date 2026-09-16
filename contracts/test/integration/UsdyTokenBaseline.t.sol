// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetVersionConfig, AssetVersionStatus, Decision, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";
import {IntegrationUpgradeableUsdyTokenV2} from "test/fixtures/IntegrationTokens.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract UsdyTokenBaselineTest is UsdySettlementFixture {
    function testDecimalsAndRuntimeCodeHashDriftFailClosedWithoutConsumingState() public {
        SettlementParams memory params = _validUsdyBuyParams();

        usdyToken.setDecimals(17);
        vm.expectPartialRevert(HTPErrors.AssetDecimalsMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        usdyToken.setDecimals(18);

        bytes memory approvedRuntime = address(usdyToken).code;
        vm.etch(address(usdyToken), hex"00");
        vm.expectPartialRevert(HTPErrors.TokenCodeHashMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        vm.etch(address(usdyToken), approvedRuntime);
    }

    function testImplementationIncidentRunbookPermanentlyRetiresOldAssetVersion() public {
        SettlementParams memory oldParams = _validUsdyBuyParams();
        bytes32 approvedProxyCodeHash = address(usdyToken).codehash;
        IntegrationUpgradeableUsdyTokenV2 nextImplementation = new IntegrationUpgradeableUsdyTokenV2();
        usdyToken.upgradeImplementation(address(nextImplementation));

        assertEq(address(usdyToken).codehash, approvedProxyCodeHash);
        assertEq(usdyToken.implementationAddress(), address(nextImplementation));
        assertEq(usdyToken.decimals(), 18);
        (Decision decisionBeforeMonitor,) = dvp.preCheck(oldParams);
        assertEq(uint8(decisionBeforeMonitor), uint8(Decision.PASS));

        vm.prank(REGISTRY_PAUSER);
        assetVersionRegistry.pauseAssetVersion(
            usdyAssetVersionConfig.assetVersionId, ReasonCode.IMPLEMENTATION_CHANGED, EVIDENCE_HASH
        );
        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.expectRevert(HTPErrors.ContractPaused.selector);
        vm.prank(EXECUTOR);
        dvp.settle(oldParams);

        vm.expectPartialRevert(HTPErrors.AssetVersionImplementationChanged.selector);
        vm.prank(address(timelock));
        assetVersionRegistry.unpauseAssetVersion(
            usdyAssetVersionConfig.assetVersionId,
            usdyAssetVersionConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );

        AssetVersionConfig memory replacement = usdyAssetVersionConfig;
        replacement.versionNo = 2;
        replacement.assetVersionId =
            ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 2);
        replacement.implementation = address(nextImplementation);
        replacement.implementationCodeHash = address(nextImplementation).codehash;
        replacement.replacesAssetVersionId = usdyAssetVersionConfig.assetVersionId;
        replacement.configHash = bytes32(0);
        replacement.configHash = HTPHashing.hashAssetVersionConfig(replacement);
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(replacement);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(replacement.assetVersionId, replacement.configHash);

        vm.prank(address(timelock));
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertFalse(dvp.globalPaused());
        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(usdyAssetVersionConfig.assetVersionId).status),
            uint8(AssetVersionStatus.PAUSED)
        );
        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(replacement.assetVersionId).status),
            uint8(AssetVersionStatus.ACTIVE)
        );
    }
}
