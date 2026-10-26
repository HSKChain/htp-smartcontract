// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    ReasonCode,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

contract FeeRegistrySealedHandler {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FeeRegistry private immutable REGISTRY;
    address private immutable CONFIGURER;
    address private immutable PAUSER;
    address private immutable GOVERNANCE;
    FeeConfig private original;

    constructor(
        FeeRegistry registry,
        address configurer,
        address pauser,
        address governance,
        FeeConfig memory original_
    ) {
        REGISTRY = registry;
        CONFIGURER = configurer;
        PAUSER = pauser;
        GOVERNANCE = governance;
        original = original_;
    }

    function attemptSealedReplacement(uint16 investorRateBps, uint16 makerRateBps) external {
        FeeConfig memory replacement = original;
        replacement.revision = 2;
        replacement.replacesFeeVersionId = original.feeVersionId;
        replacement.investorRateBps = uint16(uint256(investorRateBps) % 10_001);
        replacement.makerRateBps = uint16(uint256(makerRateBps) % 10_001);
        replacement.feeVersionId = ConfigId.derive(
            ConfigId.FEE_NAMESPACE,
            replacement.schemaVersion,
            replacement.chainId,
            replacement.matchedScopeHash,
            replacement.revision
        );
        replacement.feeConstraintHash = HTPHashing.hashFeeConstraint(replacement);
        replacement.configHash = HTPHashing.hashFeeConfig(replacement);

        VM.prank(CONFIGURER);
        try REGISTRY.registerFeeVersion(replacement) {} catch {}
    }

    function exerciseRuntimeStatus(uint8 action) external {
        FeeVersionRecord memory record = REGISTRY.getFeeVersion(original.feeVersionId);
        if (action % 3 == 0) {
            VM.prank(PAUSER);
            try REGISTRY.pauseFeeVersion(original.feeVersionId, ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1))) {}
                catch {}
        } else if (action % 3 == 1) {
            VM.prank(GOVERNANCE);
            try REGISTRY.unpauseFeeVersion(
                original.feeVersionId, original.configHash, ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(2))
            ) {}
                catch {}
        } else if (record.exists) {
            VM.prank(GOVERNANCE);
            try REGISTRY.deprecateFeeVersion(
                original.feeVersionId, ReasonCode.PLANNED_MIGRATION, bytes32(uint256(3))
            ) {}
                catch {}
        }
    }
}

contract FeeRegistrySealedInvariantTest is FeeRegistryTestBase {
    FeeConfig private originalFee;
    FeeRegistrySealedHandler private handler;

    function setUp() public override {
        super.setUp();
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        originalFee = _feeConfig(1, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(originalFee);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(originalFee.feeVersionId, originalFee.configHash);
        _activateEpoch(epoch, originalFee.feeVersionId);
        FeePolicyEpochConfig memory nextEpoch = _createEpoch(2);
        FeeConfig memory nextFee =
            _feeConfig(2, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId, 1, bytes32(0));
        _registerFee(nextFee);
        _sealEpoch(nextEpoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(nextFee.feeVersionId, nextFee.configHash);
        _activateEpoch(nextEpoch, nextFee.feeVersionId);

        handler = new FeeRegistrySealedHandler(feeRegistry, CONFIGURER, PAUSER, address(timelock), originalFee);
        targetContract(address(handler));
    }

    function invariantSealedScopeMappingAndHistoricalConfigNeverChange() public view {
        (bytes32 feeVersionId, bytes32 matchedScopeHash) =
            feeRegistry.resolveApplicableFee(1, assetVersionConfig.assetVersionId);
        FeeVersionRecord memory record = feeRegistry.getFeeVersion(originalFee.feeVersionId);

        assertEq(feeVersionId, originalFee.feeVersionId);
        assertEq(matchedScopeHash, originalFee.matchedScopeHash);
        assertEq(record.config.configHash, originalFee.configHash);
        assertEq(record.config.feeConstraintHash, originalFee.feeConstraintHash);
        assertTrue(feeRegistry.getFeePolicyEpoch(1).isSealed);
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(1).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING));
        assertEq(uint8(feeRegistry.getFeePolicyEpoch(2).status), uint8(FeePolicyEpochStatus.ACTIVE));
    }
}
