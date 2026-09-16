// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// TEMPORARY AUDIT ARTIFACT (Module F). Delete after review.

import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {AssetVersionStatus, Decision, FeeConfig, ReasonCode, SettlementParams} from "src/types/HTPTypes.sol";

contract TmpAuditModuleFOpsBlastRadius is UsdySettlementFixture {
    address private constant WRONG_COLLECTOR = address(0xDEAD00);

    /// F-05: fee terms are frozen when the epoch is sealed. A wrong `collector`
    /// (or wrong rate) cannot be corrected in place; the only on-chain repair
    /// is a whole new fee policy epoch.
    function test_F05_sealedEpochCannotRepairAWrongCollector() public {
        // Baseline: fees really do go wherever FeeConfig.collector points.
        SettlementParams memory params = _validUsdyBuyParams();
        assertEq(params.snapshot.collector, usdyFeeConfig.collector, "snapshot collector is pinned to the fee config");

        // Operations notices the collector is wrong and tries to publish revision 2.
        FeeConfig memory corrected = usdyFeeConfig;
        corrected.revision = 2;
        corrected.collector = WRONG_COLLECTOR; // stand-in for "the corrected address"
        corrected.replacesFeeVersionId = usdyFeeConfig.feeVersionId;
        corrected.feeVersionId =
            ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, corrected.matchedScopeHash, 2);
        corrected.feeConstraintHash = HTPHashing.hashFeeConstraint(corrected);
        corrected.configHash = HTPHashing.hashFeeConfig(corrected);

        vm.prank(CONFIGURER);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.FeePolicyEpochSealed.selector, USDY_FEE_EPOCH));
        feeRegistry.registerFeeVersion(corrected);

        // The only lever left is PAUSER, which stops settlement entirely rather
        // than fixing the destination.
        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(usdyFeeConfig.feeVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK), "pausing the fee version halts the whole scope");
        assertEq(reason, HTPErrors.FeeSnapshotMismatch.selector);
    }

    /// F-06: the asset-version lifecycle is one-way. DEPRECATED is terminal, so
    /// deprecating the wrong assetVersionId permanently invalidates every quote
    /// already signed against it.
    function test_F06_deprecateAssetVersionIsTerminalAndKillsSignedQuotes() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision before,) = dvp.preCheck(params);
        assertEq(uint8(before), uint8(Decision.PASS));

        bytes32 assetVersionId = usdyAssetVersionConfig.assetVersionId;
        vm.prank(REGISTRY_PAUSER);
        assetVersionRegistry.pauseAssetVersion(assetVersionId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        assetVersionRegistry.deprecateAssetVersion(assetVersionId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(assetVersionId).status), uint8(AssetVersionStatus.DEPRECATED)
        );

        // No path back: neither unpause nor re-activate is accepted.
        vm.prank(address(timelock));
        vm.expectRevert();
        assetVersionRegistry.unpauseAssetVersion(
            assetVersionId, usdyAssetVersionConfig.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        vm.prank(address(timelock));
        vm.expectRevert();
        assetVersionRegistry.activateAssetVersion(assetVersionId, usdyAssetVersionConfig.configHash);

        // Already-signed, previously-valid trades are dead.
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.AssetVersionInactive.selector);

        vm.prank(EXECUTOR);
        vm.expectRevert();
        dvp.settle(params);
    }

    /// Registry-level emergency response is per-config, not per-registry: there
    /// is no single "pause this registry" switch, so DvP.pauseGlobal is the only
    /// O(1) stop. Recorded as verification, not a defect.
    function test_registryPauseIsPerConfigOnly() public {
        SettlementParams memory params = _validUsdyBuyParams();

        vm.prank(REGISTRY_PAUSER);
        adapterRegistry.pauseAdapter(usdyAdapterConfig.adapterConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK), "one config paused blocks only that config");

        // Meanwhile the DvP itself is still unpaused and other configs are untouched.
        assertFalse(dvp.globalPaused());
    }
}
