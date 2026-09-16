// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DirectOperation} from "script/DeployTypes.sol";
import {UpgradeRegistries, UpgradeSnapshot, UpgradeVerificationSet} from "script/UpgradeRegistries.s.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "src/interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IMarketRuleRegistry} from "src/interfaces/IMarketRuleRegistry.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {MarketRuleRegistry} from "src/registry/MarketRuleRegistry.sol";
import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {ReasonCode} from "src/types/HTPTypes.sol";
import {DeployFixture} from "test/helpers/DeployFixture.sol";

contract UpgradeRunbookTest is DeployFixture {
    UpgradeRegistries private runbook;

    function setUp() public override {
        super.setUp();
        runbook = new UpgradeRegistries();
    }

    function testEightRegistryRunbookRejectsUnpausedThenExecutesDirectlyAndVerifiesBeforeUnpause() public {
        (address[] memory registries, address[] memory implementations) = _upgradePairs();
        UpgradeSnapshot[] memory beforeStates = new UpgradeSnapshot[](registries.length);
        bytes[][] memory probes = new bytes[][](registries.length);
        bytes32[] memory expectedCodeHashes = new bytes32[](registries.length);

        for (uint256 i = 0; i < registries.length; ++i) {
            probes[i] = _probes(i);
            beforeStates[i] = runbook.snapshot(registries[i], probes[i]);
            expectedCodeHashes[i] = implementations[i].codehash;
            vm.expectRevert(abi.encodeWithSelector(UpgradeRegistries.DependentDvpNotPaused.selector, address(dvp)));
            runbook.buildUpgrade(registries[i], beforeStates[i].implementation, implementations[i], bytes(""));
        }

        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        for (uint256 i = 0; i < registries.length; ++i) {
            _execute(runbook.buildUpgrade(registries[i], beforeStates[i].implementation, implementations[i], bytes("")));
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeRegistries.UpgradeRunbookCheckFailed.selector, bytes32("UPGRADE_CODE_HASH"), implementations[0]
            )
        );
        runbook.verifyUpgrade(
            registries[0],
            implementations[0],
            bytes32(uint256(1)),
            beforeStates[0],
            _probes(0),
            address(timelock),
            address(timelock),
            address(timelock)
        );
        assertTrue(dvp.globalPaused(), "failed verification must leave DvP paused");

        UpgradeVerificationSet memory verification = UpgradeVerificationSet({
            registries: registries,
            implementations: implementations,
            codeHashes: expectedCodeHashes,
            beforeStates: beforeStates,
            publicStateProbes: probes,
            expectedDefaultAdmin: address(timelock),
            expectedGovernance: address(timelock),
            expectedUpgrader: address(timelock)
        });

        expectedCodeHashes[0] = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeRegistries.UpgradeRunbookCheckFailed.selector, bytes32("UPGRADE_CODE_HASH"), implementations[0]
            )
        );
        runbook.buildUnpauseAfterSuccessfulVerification(address(dvp), verification, EVIDENCE_HASH);
        assertTrue(dvp.globalPaused());
        expectedCodeHashes[0] = implementations[0].codehash;

        bytes32 savedHistoryHash = beforeStates[0].dependentHistoryHash;
        beforeStates[0].dependentHistoryHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeRegistries.UpgradeRunbookCheckFailed.selector,
                bytes32("DEPENDENT_HISTORY_CHANGED"),
                registries[0]
            )
        );
        runbook.buildUnpauseAfterSuccessfulVerification(address(dvp), verification, EVIDENCE_HASH);
        assertTrue(dvp.globalPaused());
        beforeStates[0].dependentHistoryHash = savedHistoryHash;

        bytes32 savedProbeHash = beforeStates[0].publicStateHashes[0];
        beforeStates[0].publicStateHashes[0] = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeRegistries.UpgradeRunbookCheckFailed.selector, bytes32("PUBLIC_STORAGE_CHANGED"), registries[0]
            )
        );
        runbook.buildUnpauseAfterSuccessfulVerification(address(dvp), verification, EVIDENCE_HASH);
        assertTrue(dvp.globalPaused());
        beforeStates[0].publicStateHashes[0] = savedProbeHash;

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeRegistries.UpgradeRunbookCheckFailed.selector, bytes32("EVIDENCE_REQUIRED"), address(dvp)
            )
        );
        runbook.buildUnpauseAfterSuccessfulVerification(address(dvp), verification, bytes32(0));

        _execute(runbook.buildUnpauseAfterSuccessfulVerification(address(dvp), verification, EVIDENCE_HASH));
        assertFalse(dvp.globalPaused());
    }

    function _execute(DirectOperation memory operation) private {
        vm.prank(address(timelock));
        (bool success, bytes memory returnData) = operation.target.call(operation.data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _upgradePairs() private returns (address[] memory registries, address[] memory implementations) {
        registries = new address[](8);
        implementations = new address[](8);
        registries[0] = address(participantRegistry);
        implementations[0] = address(new ParticipantRegistry());
        registries[1] = address(assetVersionRegistry);
        implementations[1] = address(new AssetVersionRegistry());
        registries[2] = address(eligibilityRegistry);
        implementations[2] = address(new EligibilityRegistry());
        registries[3] = address(feeRegistry);
        implementations[3] = address(new FeeRegistry());
        registries[4] = address(settlementTokenRegistry);
        implementations[4] = address(new SettlementTokenRegistry());
        registries[5] = address(adapterRegistry);
        implementations[5] = address(new AdapterRegistry());
        registries[6] = address(calculatorRegistry);
        implementations[6] = address(new PrincipalCalculatorRegistry());
        registries[7] = address(marketRuleRegistry);
        implementations[7] = address(new MarketRuleRegistry());
    }

    function _probes(uint256 index) private view returns (bytes[] memory probes) {
        probes = new bytes[](1);
        if (index == 0) {
            probes[0] = abi.encodeCall(IParticipantRegistry.getParticipant, (vm.addr(MAKER_KEY)));
        } else if (index == 1) {
            probes[0] = abi.encodeCall(IAssetVersionRegistry.getAssetVersion, (assetVersionConfig.assetVersionId));
        } else if (index == 2) {
            probes[0] = abi.encodeCall(
                IEligibilityRegistry.isEligible, (vm.addr(MAKER_KEY), assetVersionConfig.assetVersionId)
            );
        } else if (index == 3) {
            probes[0] = abi.encodeCall(IFeeRegistry.getFeeVersion, (feeConfig.feeVersionId));
        } else if (index == 4) {
            probes[0] = abi.encodeCall(ISettlementTokenRegistry.getSettlementToken, (settlementTokenConfig.configId));
        } else if (index == 5) {
            probes[0] = abi.encodeCall(IAdapterRegistry.getAdapter, (adapterConfig.adapterConfigId));
        } else if (index == 6) {
            probes[0] = abi.encodeCall(
                IPrincipalCalculatorRegistry.getPrincipalCalculator, (calculatorConfig.calculatorConfigId)
            );
        } else {
            probes[0] = abi.encodeCall(IMarketRuleRegistry.getMarketRule, (marketRuleConfig.marketRuleConfigId));
        }
    }
}
