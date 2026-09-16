// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ReasonCode} from "src/types/HTPTypes.sol";
import {DeployFixture} from "test/helpers/DeployFixture.sol";

interface IPhase15RegistryV2 {
    function phase15Marker() external pure returns (uint256);
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract ParticipantRegistryPhase15V2 is ParticipantRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract AssetVersionRegistryPhase15V2 is AssetVersionRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract EligibilityRegistryPhase15V2 is EligibilityRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract FeeRegistryPhase15V2 is FeeRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract SettlementTokenRegistryPhase15V2 is SettlementTokenRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract AdapterRegistryPhase15V2 is AdapterRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract PrincipalCalculatorRegistryPhase15V2 is PrincipalCalculatorRegistry {
    function phase15Marker() external pure returns (uint256) {
        return 15;
    }
}

contract RegistryUpgradeIntegrationTest is DeployFixture {
    function testAllRegistriesRequireRealDvpPauseBeforeUpgrade() public {
        (address[] memory registries, address[] memory implementations) = _upgradePairs();

        for (uint256 i = 0; i < registries.length; ++i) {
            vm.prank(address(timelock));
            (bool success, bytes memory returnData) = registries[i].call(
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementations[i], bytes(""))
            );
            assertFalse(success);
            assertEq(_selector(returnData), HTPErrors.DependentDvpNotPaused.selector);
        }

        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        for (uint256 i = 0; i < registries.length; ++i) {
            vm.prank(address(timelock));
            (bool success,) = registries[i].call(
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementations[i], bytes(""))
            );
            assertTrue(success);
            assertEq(IPhase15RegistryV2(registries[i]).phase15Marker(), 15);
            _assertDependentHistory(registries[i], false);
        }

        assertEq(
            assetVersionRegistry.getAssetVersion(assetVersionConfig.assetVersionId).config.configHash,
            assetVersionConfig.configHash
        );
        assertEq(adapterRegistry.getAdapter(adapterConfig.adapterConfigId).config.configHash, adapterConfig.configHash);
    }

    function testRetiredRealDvpCanBeIrreversiblyExemptedWithoutDeletingHistory() public {
        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        dvp.retire(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        address[] memory registries = _registries();
        for (uint256 i = 0; i < registries.length; ++i) {
            vm.prank(address(timelock));
            (bool success,) = registries[i].call(
                abi.encodeWithSignature("exemptRetiredDependentDvp(address,bytes32)", address(dvp), EVIDENCE_HASH)
            );
            assertTrue(success);
            _assertDependentHistory(registries[i], true);
        }

        vm.expectPartialRevert(HTPErrors.DependentDvpAlreadyRetiredExempt.selector);
        vm.prank(address(timelock));
        participantRegistry.exemptRetiredDependentDvp(address(dvp), EVIDENCE_HASH);

        vm.expectRevert(HTPErrors.RetiredContract.selector);
        vm.prank(address(timelock));
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(participantRegistry.getParticipant(vm.addr(MAKER_KEY)).participantIdHash, bytes32(uint256(0xA001)));
    }

    function _upgradePairs() private returns (address[] memory registries, address[] memory implementations) {
        registries = _registries();
        implementations = new address[](7);
        implementations[0] = address(new ParticipantRegistryPhase15V2());
        implementations[1] = address(new AssetVersionRegistryPhase15V2());
        implementations[2] = address(new EligibilityRegistryPhase15V2());
        implementations[3] = address(new FeeRegistryPhase15V2());
        implementations[4] = address(new SettlementTokenRegistryPhase15V2());
        implementations[5] = address(new AdapterRegistryPhase15V2());
        implementations[6] = address(new PrincipalCalculatorRegistryPhase15V2());
    }

    function _registries() private view returns (address[] memory registries) {
        registries = new address[](7);
        registries[0] = address(participantRegistry);
        registries[1] = address(assetVersionRegistry);
        registries[2] = address(eligibilityRegistry);
        registries[3] = address(feeRegistry);
        registries[4] = address(settlementTokenRegistry);
        registries[5] = address(adapterRegistry);
        registries[6] = address(calculatorRegistry);
    }

    function _assertDependentHistory(address registry, bool expectedExempt) private view {
        (bool countSuccess, bytes memory countData) =
            registry.staticcall(abi.encodeWithSignature("getDependentDvpCount()"));
        assertTrue(countSuccess);
        assertEq(abi.decode(countData, (uint256)), 1);
        (bool entrySuccess, bytes memory entryData) =
            registry.staticcall(abi.encodeWithSignature("getDependentDvp(uint256)", 0));
        assertTrue(entrySuccess);
        (address storedDvp, bool retiredExempt) = abi.decode(entryData, (address, bool));
        assertEq(storedDvp, address(dvp));
        assertEq(retiredExempt, expectedExempt);
    }

    function _selector(bytes memory returnData) private pure returns (bytes4 selector) {
        if (returnData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
