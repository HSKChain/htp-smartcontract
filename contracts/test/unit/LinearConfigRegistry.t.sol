// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {LinearConfigMetadata} from "../../src/registry/LinearConfigRegistryBase.sol";
import {HTPErrors} from "../../src/types/HTPErrors.sol";
import {ReasonCode} from "../../src/types/HTPTypes.sol";
import {
    LinearConfigRegistryBadHashV2,
    LinearConfigRegistryHarness,
    LinearConfigRegistryHarnessV2
} from "../fixtures/LinearConfigRegistryHarness.sol";
import {LinearConfigRegistryLegacyHarness} from "../fixtures/LinearConfigRegistryLegacyHarness.sol";
import {RegistryTestBase} from "../helpers/RegistryTestBase.sol";

contract LinearConfigRegistryTest is RegistryTestBase {
    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);

    bytes32 internal constant SUBJECT = 0x0000000000000000000000000000000000000000000000000000000000000a11;
    bytes32 internal constant PAYLOAD_1 = 0x0000000000000000000000000000000000000000000000000000000000000b11;
    bytes32 internal constant PAYLOAD_2 = 0x0000000000000000000000000000000000000000000000000000000000000b12;
    bytes32 internal constant PAYLOAD_3 = 0x0000000000000000000000000000000000000000000000000000000000000b13;
    bytes32 internal constant CONFIG_ID_1 = 0x60f5dd2b398dea939f79ecb4fcbde1c391122f1508c699f5f848073ea93143d1;
    bytes32 internal constant CONFIG_HASH_1 = 0xd2afffb601737e223491511c34d1834bfb8ed851ee61b9fe7624a23e2a9cae85;
    bytes32 internal constant CONFIG_ID_2 = 0xcec811b7faa6ef4bac134640a47e07b1006da2e53be88aa06fb47f5c3c76e820;
    bytes32 internal constant CONFIG_HASH_2 = 0xb0d5f8aa092fb6036e2763842ca38365534902b2b2c3fef76a97d072e68293a4;
    bytes32 internal constant CONFIG_ID_3 = 0x55a96098eb81f1d78dcdf02d60e0ad0148fb3fc0e951e5733b534eba283b009f;
    bytes32 internal constant CONFIG_HASH_3 = 0xfefbc3f005dab8ef8a0ca9bc05da24e926b03005a6dffd40aaeeb5ef20424708;
    bytes32 internal constant REGISTERED_TOPIC = 0x502688a4c8a8257d9adcebc0eedde08b54f6802d4a3b1740dfdbe7c21c3d14ed;
    bytes32 internal constant STATUS_CHANGED_TOPIC = 0x0952cfb6907f27074c19256502ae01da8ca4c13c3c76aed7d8f60f6575cd057e;
    bytes32 internal constant CURRENT_CHANGED_TOPIC =
        0xef9c8e6ca728f1950e272267928aa75d87e52f214281188506ed9deb45707099;
    bytes32 internal constant EVIDENCE_HASH = 0x0000000000000000000000000000000000000000000000000000000000000e11;

    LinearConfigRegistryHarness internal registry;

    function setUp() public override {
        super.setUp();
        LinearConfigRegistryHarness implementation = new LinearConfigRegistryHarness();
        registry = LinearConfigRegistryHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(LinearConfigRegistryHarness.initialize, (address(timelock), PAUSER, CONFIGURER))
            )
        );
    }

    function testConfigVersionsAreLinearWithoutForksGapsOrHistoryOverwrite() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);

        vm.expectRevert();
        _register(CONFIG_ID_3, 3, CONFIG_ID_1, PAYLOAD_3, CONFIG_HASH_3);
        _register(CONFIG_ID_2, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);

        vm.expectRevert();
        _register(CONFIG_ID_2, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);

        vm.expectRevert();
        _register(CONFIG_ID_3, 3, CONFIG_ID_1, PAYLOAD_3, CONFIG_HASH_3);
        _register(CONFIG_ID_3, 3, CONFIG_ID_2, PAYLOAD_3, CONFIG_HASH_3);

        (LinearConfigMetadata memory first, bytes32 firstPayload) = registry.getConfig(CONFIG_ID_1);
        (LinearConfigMetadata memory second, bytes32 secondPayload) = registry.getConfig(CONFIG_ID_2);
        (LinearConfigMetadata memory third, bytes32 thirdPayload) = registry.getConfig(CONFIG_ID_3);
        assertEq(first.revision, 1);
        assertEq(first.replacesId, bytes32(0));
        assertEq(firstPayload, PAYLOAD_1);
        assertEq(second.revision, 2);
        assertEq(second.replacesId, CONFIG_ID_1);
        assertEq(secondPayload, PAYLOAD_2);
        assertEq(third.revision, 3);
        assertEq(third.replacesId, CONFIG_ID_2);
        assertEq(thirdPayload, PAYLOAD_3);
    }

    function testNewCandidateCanSupersedeUnactivatedCandidateWithoutMovingCurrent() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        _register(CONFIG_ID_2, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);

        (LinearConfigMetadata memory current,) = registry.getCurrentConfig(SUBJECT);
        assertFalse(current.exists);

        vm.expectRevert();
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);

        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_2, CONFIG_HASH_2);
        (current,) = registry.getCurrentConfig(SUBJECT);
        assertEq(current.revision, 2);
    }

    function testRegisterCreatesOnlyRegisteredHistoryWithoutChangingCurrent() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);

        (LinearConfigMetadata memory stored, bytes32 payloadHash) = registry.getConfig(CONFIG_ID_1);
        (LinearConfigMetadata memory current, bytes32 currentPayload) = registry.getCurrentConfig(SUBJECT);
        assertTrue(stored.exists);
        assertEq(stored.status, 1);
        assertEq(stored.configHash, CONFIG_HASH_1);
        assertEq(payloadHash, PAYLOAD_1);
        assertFalse(current.exists);
        assertEq(current.status, 0);
        assertEq(currentPayload, bytes32(0));
    }

    function testActivateRequiresGovernanceAndExpectedStoredRecomputedHashEquality() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);

        vm.expectRevert();
        vm.prank(CONFIGURER);
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);

        bytes32 wrongHash = bytes32(uint256(CONFIG_HASH_1) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigHashMismatch.selector, wrongHash, CONFIG_HASH_1));
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, wrongHash);

        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
        (LinearConfigMetadata memory current, bytes32 currentPayload) = registry.getCurrentConfig(SUBJECT);
        assertEq(current.status, 2);
        assertEq(current.configHash, CONFIG_HASH_1);
        assertEq(currentPayload, PAYLOAD_1);
    }

    function testActivateRejectsStoredHashWhenUpgradedRecomputationDiffers() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        _satisfyUpgradeGate(address(registry));
        LinearConfigRegistryBadHashV2 badImplementation = new LinearConfigRegistryBadHashV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(badImplementation), bytes(""));

        bytes32 recomputed = bytes32(uint256(CONFIG_HASH_1) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigHashMismatch.selector, CONFIG_HASH_1, recomputed));
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
    }

    function testPauseUnpauseAndDeprecateFollowOnlyApprovedStateEdges() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnauthorizedStateTransition.selector, CONFIG_ID_1, 1, 3));
        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ReasonCodeRequired.selector, ReasonCode.NONE));
        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.NONE, EVIDENCE_HASH);

        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.SECURITY_INCIDENT, bytes32(0));

        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        (LinearConfigMetadata memory paused,) = registry.getConfig(CONFIG_ID_1);
        assertEq(paused.status, 3);

        vm.prank(address(timelock));
        registry.unpauseConfig(CONFIG_ID_1, CONFIG_HASH_1, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        (LinearConfigMetadata memory active,) = registry.getConfig(CONFIG_ID_1);
        assertEq(active.status, 2);

        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecateConfig(CONFIG_ID_1, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        (LinearConfigMetadata memory deprecated,) = registry.getConfig(CONFIG_ID_1);
        assertEq(deprecated.status, 4);
    }

    function testDeprecatedIsTerminalAndHistoricalRecordsRemainReadable() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecateConfig(CONFIG_ID_1, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        vm.expectRevert();
        vm.prank(address(timelock));
        registry.unpauseConfig(CONFIG_ID_1, CONFIG_HASH_1, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        vm.expectRevert();
        vm.prank(PAUSER);
        registry.pauseConfig(CONFIG_ID_1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        vm.expectRevert();
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);

        _register(CONFIG_ID_2, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_2, CONFIG_HASH_2);

        (LinearConfigMetadata memory historical, bytes32 historicalPayload) = registry.getConfig(CONFIG_ID_1);
        (LinearConfigMetadata memory current, bytes32 currentPayload) = registry.getCurrentConfig(SUBJECT);
        assertEq(historical.status, 4);
        assertEq(historicalPayload, PAYLOAD_1);
        assertEq(current.revision, 2);
        assertEq(currentPayload, PAYLOAD_2);
    }

    function testUpgradePreservesHistoryCurrentRolesAndDependentDvps() public {
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
        _register(CONFIG_ID_2, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        LinearConfigRegistryHarnessV2 nextImplementation = new LinearConfigRegistryHarnessV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(registry.implementationVersion(), 2);
        (LinearConfigMetadata memory first, bytes32 firstPayload) = registry.getConfig(CONFIG_ID_1);
        (LinearConfigMetadata memory second, bytes32 secondPayload) = registry.getConfig(CONFIG_ID_2);
        (LinearConfigMetadata memory current,) = registry.getCurrentConfig(SUBJECT);
        assertEq(first.status, 2);
        assertEq(firstPayload, PAYLOAD_1);
        assertEq(second.status, 1);
        assertEq(secondPayload, PAYLOAD_2);
        assertEq(current.revision, 1);
        assertEq(registry.getDependentDvpCount(), 1);
        assertTrue(registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));

        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_2, CONFIG_HASH_2);
        (current,) = registry.getCurrentConfig(SUBJECT);
        assertEq(current.revision, 2);
    }

    function testUpgradeBootstrapsLatestFromLegacyRegisteredCandidate() public {
        LinearConfigRegistryHarnessV2 upgraded = _upgradeLegacyWithRegisteredCandidate();

        vm.prank(CONFIGURER);
        upgraded.registerConfig(CONFIG_ID_3, SUBJECT, 3, CONFIG_ID_2, PAYLOAD_3, CONFIG_HASH_3);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigNotLatest.selector, CONFIG_ID_2, CONFIG_ID_3));
        vm.prank(address(timelock));
        upgraded.activateConfig(CONFIG_ID_2, CONFIG_HASH_2);

        vm.prank(address(timelock));
        upgraded.activateConfig(CONFIG_ID_3, CONFIG_HASH_3);
        (LinearConfigMetadata memory current, bytes32 payload) = upgraded.getCurrentConfig(SUBJECT);
        assertEq(current.revision, 3);
        assertEq(payload, PAYLOAD_3);
    }

    function testUpgradeBackfillsLatestWhenActivatingLegacyCandidate() public {
        LinearConfigRegistryHarnessV2 upgraded = _upgradeLegacyWithRegisteredCandidate();

        vm.prank(address(timelock));
        upgraded.activateConfig(CONFIG_ID_2, CONFIG_HASH_2);
        vm.prank(CONFIGURER);
        upgraded.registerConfig(CONFIG_ID_3, SUBJECT, 3, CONFIG_ID_2, PAYLOAD_3, CONFIG_HASH_3);

        (LinearConfigMetadata memory current, bytes32 payload) = upgraded.getCurrentConfig(SUBJECT);
        assertEq(current.revision, 2);
        assertEq(payload, PAYLOAD_2);
    }

    function testStrongTypedEventsUseReviewedTopicsAndStaticReplayableFields() public {
        vm.recordLogs();
        _register(CONFIG_ID_1, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        assertEq(registrationLogs[0].emitter, address(registry));
        assertEq(registrationLogs[0].topics.length, 3);
        assertEq(registrationLogs[0].topics[0], REGISTERED_TOPIC);
        assertEq(registrationLogs[0].topics[1], CONFIG_ID_1);
        assertEq(registrationLogs[0].topics[2], SUBJECT);
        assertEq(registrationLogs[0].data.length, 160);
        (uint256 registeredChainId, uint32 revision, bytes32 configHash, bytes32 replacesId, bytes32 payloadHash) =
            abi.decode(registrationLogs[0].data, (uint256, uint32, bytes32, bytes32, bytes32));
        assertEq(registeredChainId, block.chainid);
        assertEq(revision, 1);
        assertEq(configHash, CONFIG_HASH_1);
        assertEq(replacesId, bytes32(0));
        assertEq(payloadHash, PAYLOAD_1);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();
        assertEq(activationLogs.length, 2);
        assertEq(activationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics[0], CURRENT_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics.length, 4);
        assertEq(activationLogs[1].topics[1], SUBJECT);
        assertEq(activationLogs[1].topics[2], bytes32(0));
        assertEq(activationLogs[1].topics[3], CONFIG_ID_1);
    }

    function _register(bytes32 configId, uint32 revision, bytes32 replacesId, bytes32 payloadHash, bytes32 configHash)
        private
    {
        vm.prank(CONFIGURER);
        registry.registerConfig(configId, SUBJECT, revision, replacesId, payloadHash, configHash);
    }

    function _upgradeLegacyWithRegisteredCandidate() private returns (LinearConfigRegistryHarnessV2 upgraded) {
        LinearConfigRegistryLegacyHarness legacy = LinearConfigRegistryLegacyHarness(
            _deployProxy(
                address(new LinearConfigRegistryLegacyHarness()),
                abi.encodeCall(LinearConfigRegistryLegacyHarness.initialize, (address(timelock), PAUSER, CONFIGURER))
            )
        );
        vm.prank(CONFIGURER);
        legacy.registerConfig(CONFIG_ID_1, SUBJECT, 1, bytes32(0), PAYLOAD_1, CONFIG_HASH_1);
        vm.prank(address(timelock));
        legacy.activateConfig(CONFIG_ID_1, CONFIG_HASH_1);
        vm.prank(CONFIGURER);
        legacy.registerConfig(CONFIG_ID_2, SUBJECT, 2, CONFIG_ID_1, PAYLOAD_2, CONFIG_HASH_2);

        _satisfyUpgradeGate(address(legacy));
        LinearConfigRegistryHarnessV2 nextImplementation = new LinearConfigRegistryHarnessV2();
        vm.prank(address(timelock));
        legacy.upgradeToAndCall(address(nextImplementation), bytes(""));
        upgraded = LinearConfigRegistryHarnessV2(address(legacy));
    }
}
