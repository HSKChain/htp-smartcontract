// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";
import {Roles} from "src/libraries/Roles.sol";
import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    ParticipantInput,
    ParticipantRecord,
    ParticipantStatus,
    ParticipantType,
    ReasonCode
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract ParticipantRegistryV2 is ParticipantRegistry {
    function phase9V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract ParticipantRegistryTest is RegistryTestBase {
    struct ParticipantUpdatedData {
        uint256 chainId;
        ParticipantType participantType;
        ParticipantStatus oldStatus;
        ParticipantStatus newStatus;
        uint64 validUntil;
        uint64 oldVersion;
        uint64 newVersion;
        bytes32 evidenceHash;
        address actor;
    }

    struct ParticipantRevokedData {
        uint256 chainId;
        uint64 oldVersion;
        uint64 newVersion;
        bytes32 evidenceHash;
        address actor;
    }

    bytes32 internal constant PARTICIPANT_UPDATED_TOPIC =
        0x4226b5f55070d7385655a2b35a6f097d50c4e0d0cb44840baa7ff505d5348305;
    bytes32 internal constant PARTICIPANT_REVOKED_TOPIC =
        0x6363cc6ae09e0546f1bc70159852ce136b37aeb71450dc5b1e11cf1c004865fb;
    address internal constant PAUSER = address(0x2201);
    address internal constant CONFIGURER = address(0x3201);
    address internal constant WALLET = address(0x4201);
    bytes32 internal constant PARTICIPANT_ID_HASH = bytes32(uint256(0x5001));
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE001));

    ParticipantRegistry internal registry;

    function setUp() public override {
        super.setUp();
        registry = ParticipantRegistry(
            _deployProxy(
                address(new ParticipantRegistry()),
                abi.encodeCall(
                    ParticipantRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
    }

    function testFirstRegistrationCreatesActiveVersionOneRecord() public {
        ParticipantInput memory input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.INVESTOR);

        vm.prank(CONFIGURER);
        registry.setParticipant(input, 0);

        ParticipantRecord memory record = registry.getParticipant(WALLET);
        assertEq(record.wallet, WALLET);
        assertEq(record.participantIdHash, PARTICIPANT_ID_HASH);
        assertEq(uint8(record.participantType), uint8(ParticipantType.INVESTOR));
        assertEq(uint8(record.status), uint8(ParticipantStatus.ACTIVE));
        assertEq(record.validUntil, input.validUntil);
        assertEq(record.version, 1);
        assertEq(record.evidenceHash, EVIDENCE_HASH);
    }

    function testFirstRegistrationRejectsInvalidIdentityTypeVersionAndValidity() public {
        vm.recordLogs();
        ParticipantInput memory input = _input(address(0), PARTICIPANT_ID_HASH, ParticipantType.INVESTOR);
        vm.expectRevert(HTPErrors.InvalidParticipantInput.selector);
        _setParticipant(input, 0);

        input = _input(WALLET, bytes32(0), ParticipantType.INVESTOR);
        vm.expectRevert(HTPErrors.InvalidParticipantInput.selector);
        _setParticipant(input, 0);

        input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.NONE);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidParticipantType.selector, ParticipantType.NONE));
        _setParticipant(input, 0);

        input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        input.validUntil = uint64(block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.InvalidParticipantValidity.selector, input.validUntil, uint64(block.timestamp)
            )
        );
        _setParticipant(input, 0);

        input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ParticipantVersionConflict.selector, WALLET, uint64(1), uint64(0))
        );
        _setParticipant(input, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(registry.getParticipant(WALLET).version, 0);
        assertEq(registry.getParticipant(address(0)).version, 0);
    }

    function testUpdatePreservesIdentityAndUsesExactMonotonicVersion() public {
        ParticipantInput memory input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        _setParticipant(input, 0);

        vm.recordLogs();
        ParticipantInput memory changed = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        changed.participantIdHash = bytes32(uint256(0xBAD1));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantIdentityImmutable.selector, WALLET));
        _setParticipant(changed, 1);

        changed = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        changed.participantType = ParticipantType.INVESTOR;
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantIdentityImmutable.selector, WALLET));
        _setParticipant(changed, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        ParticipantRecord memory beforeUpdate = registry.getParticipant(WALLET);
        assertEq(beforeUpdate.version, 1);
        assertEq(beforeUpdate.participantIdHash, PARTICIPANT_ID_HASH);
        assertEq(uint8(beforeUpdate.participantType), uint8(ParticipantType.MAKER));

        input.validUntil = uint64(block.timestamp + 10 days);
        input.evidenceHash = bytes32(uint256(0xE002));
        _setParticipant(input, 1);

        ParticipantRecord memory record = registry.getParticipant(WALLET);
        assertEq(record.participantIdHash, PARTICIPANT_ID_HASH);
        assertEq(uint8(record.participantType), uint8(ParticipantType.MAKER));
        assertEq(uint8(record.status), uint8(ParticipantStatus.ACTIVE));
        assertEq(record.validUntil, input.validUntil);
        assertEq(record.version, 2);
        assertEq(record.evidenceHash, input.evidenceHash);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ParticipantVersionConflict.selector, WALLET, uint64(1), uint64(2))
        );
        _setParticipant(input, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        ParticipantRecord memory afterConflict = registry.getParticipant(WALLET);
        assertEq(afterConflict.version, 2);
        assertEq(afterConflict.validUntil, input.validUntil);
    }

    function testPauseUnpauseAndPermanentRevokeAreRoleAndVersionGated() public {
        ParticipantInput memory input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        _setParticipant(input, 0);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, CONFIGURER, Roles.PAUSER_ROLE
            )
        );
        vm.prank(CONFIGURER);
        registry.pauseParticipant(WALLET, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertEq(vm.getRecordedLogs().length, 0);
        ParticipantRecord memory unchanged = registry.getParticipant(WALLET);
        assertEq(uint8(unchanged.status), uint8(ParticipantStatus.ACTIVE));
        assertEq(unchanged.version, 1);

        vm.prank(PAUSER);
        registry.pauseParticipant(WALLET, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        ParticipantRecord memory paused = registry.getParticipant(WALLET);
        assertEq(uint8(paused.status), uint8(ParticipantStatus.PAUSED));
        assertEq(paused.version, 2);

        input.validUntil = uint64(block.timestamp + 60 days);
        _setParticipant(input, 2);
        paused = registry.getParticipant(WALLET);
        assertEq(uint8(paused.status), uint8(ParticipantStatus.PAUSED));
        assertEq(paused.version, 3);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(PAUSER);
        registry.unpauseParticipant(WALLET, 3, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(vm.getRecordedLogs().length, 0);
        unchanged = registry.getParticipant(WALLET);
        assertEq(uint8(unchanged.status), uint8(ParticipantStatus.PAUSED));
        assertEq(unchanged.version, 3);

        vm.prank(address(timelock));
        registry.unpauseParticipant(WALLET, 3, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        ParticipantRecord memory active = registry.getParticipant(WALLET);
        assertEq(uint8(active.status), uint8(ParticipantStatus.ACTIVE));
        assertEq(active.version, 4);

        // 永久撤销是本合约唯一的不可逆终态，归 GOVERNANCE：Configurer 只能登记与更新。
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, CONFIGURER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(CONFIGURER);
        registry.revokeParticipant(WALLET, 4, EVIDENCE_HASH);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(uint8(registry.getParticipant(WALLET).status), uint8(ParticipantStatus.ACTIVE));

        vm.prank(address(timelock));
        registry.revokeParticipant(WALLET, 4, EVIDENCE_HASH);
        ParticipantRecord memory revoked = registry.getParticipant(WALLET);
        assertEq(uint8(revoked.status), uint8(ParticipantStatus.REVOKED));
        assertEq(revoked.version, 5);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantPermanentlyRevoked.selector, WALLET));
        _setParticipant(input, 5);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantPermanentlyRevoked.selector, WALLET));
        vm.prank(address(timelock));
        registry.unpauseParticipant(WALLET, 5, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(vm.getRecordedLogs().length, 0);
        ParticipantRecord memory stillRevoked = registry.getParticipant(WALLET);
        assertEq(uint8(stillRevoked.status), uint8(ParticipantStatus.REVOKED));
        assertEq(stillRevoked.version, 5);
    }

    function testActiveQueryChecksStatusTypeFiniteExpiryAndKeepsWalletsIndependent() public {
        address secondWallet = address(0x4202);
        ParticipantInput memory maker = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        ParticipantInput memory sameEntityMaker = _input(secondWallet, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        _setParticipant(maker, 0);
        _setParticipant(sameEntityMaker, 0);

        assertTrue(registry.isParticipantActive(WALLET, ParticipantType.MAKER));
        assertTrue(registry.isParticipantActive(secondWallet, ParticipantType.MAKER));
        assertFalse(registry.isParticipantActive(WALLET, ParticipantType.INVESTOR));
        assertFalse(registry.isParticipantActive(address(0xDEAD), ParticipantType.MAKER));

        vm.prank(PAUSER);
        registry.pauseParticipant(WALLET, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertFalse(registry.isParticipantActive(WALLET, ParticipantType.MAKER));
        assertTrue(registry.isParticipantActive(secondWallet, ParticipantType.MAKER));

        vm.warp(sameEntityMaker.validUntil);
        assertFalse(registry.isParticipantActive(secondWallet, ParticipantType.MAKER));
    }

    function testEventsReplayCompleteUpdatesAndIndependentRevocation() public {
        ParticipantInput memory input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        vm.recordLogs();
        _setParticipant(input, 0);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        _assertUpdatedLog(
            registrationLogs[0],
            ParticipantStatus.NONE,
            ParticipantStatus.ACTIVE,
            input.validUntil,
            0,
            1,
            EVIDENCE_HASH,
            CONFIGURER
        );

        input.validUntil = uint64(block.timestamp + 60 days);
        input.evidenceHash = bytes32(uint256(0xE002));
        vm.recordLogs();
        _setParticipant(input, 1);
        Vm.Log[] memory updateLogs = vm.getRecordedLogs();
        assertEq(updateLogs.length, 1);
        _assertUpdatedLog(
            updateLogs[0],
            ParticipantStatus.ACTIVE,
            ParticipantStatus.ACTIVE,
            input.validUntil,
            1,
            2,
            input.evidenceHash,
            CONFIGURER
        );

        vm.recordLogs();
        vm.prank(PAUSER);
        registry.pauseParticipant(WALLET, 2, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        Vm.Log[] memory pauseLogs = vm.getRecordedLogs();
        assertEq(pauseLogs.length, 1);
        _assertUpdatedLog(
            pauseLogs[0],
            ParticipantStatus.ACTIVE,
            ParticipantStatus.PAUSED,
            input.validUntil,
            2,
            3,
            EVIDENCE_HASH,
            PAUSER
        );

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.unpauseParticipant(WALLET, 3, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        Vm.Log[] memory unpauseLogs = vm.getRecordedLogs();
        assertEq(unpauseLogs.length, 1);
        _assertUpdatedLog(
            unpauseLogs[0],
            ParticipantStatus.PAUSED,
            ParticipantStatus.ACTIVE,
            input.validUntil,
            3,
            4,
            EVIDENCE_HASH,
            address(timelock)
        );

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.revokeParticipant(WALLET, 4, EVIDENCE_HASH);
        Vm.Log[] memory revocationLogs = vm.getRecordedLogs();
        assertEq(revocationLogs.length, 2);
        _assertUpdatedLog(
            revocationLogs[0],
            ParticipantStatus.ACTIVE,
            ParticipantStatus.REVOKED,
            input.validUntil,
            4,
            5,
            EVIDENCE_HASH,
            address(timelock)
        );
        assertEq(revocationLogs[1].emitter, address(registry));
        assertEq(revocationLogs[1].topics.length, 3);
        assertEq(revocationLogs[1].topics[0], PARTICIPANT_REVOKED_TOPIC);
        assertEq(revocationLogs[1].topics[1], bytes32(uint256(uint160(WALLET))));
        assertEq(revocationLogs[1].topics[2], PARTICIPANT_ID_HASH);
        ParticipantRevokedData memory revokedData = abi.decode(revocationLogs[1].data, (ParticipantRevokedData));
        assertEq(revokedData.chainId, block.chainid);
        assertEq(revokedData.oldVersion, 4);
        assertEq(revokedData.newVersion, 5);
        assertEq(revokedData.evidenceHash, EVIDENCE_HASH);
        assertEq(revokedData.actor, address(timelock));
    }

    function testUpgradePreservesParticipantRolesAndDependentDvps() public {
        ParticipantInput memory input = _input(WALLET, PARTICIPANT_ID_HASH, ParticipantType.MAKER);
        _setParticipant(input, 0);
        vm.prank(PAUSER);
        registry.pauseParticipant(WALLET, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        dependentDvp.setGlobalPaused(true);
        ParticipantRegistryV2 implementation = new ParticipantRegistryV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(implementation), bytes(""));

        ParticipantRegistryV2 upgraded = ParticipantRegistryV2(address(registry));
        assertEq(upgraded.phase9V2Marker(), 2);
        ParticipantRecord memory record = upgraded.getParticipant(WALLET);
        assertEq(record.wallet, WALLET);
        assertEq(record.participantIdHash, PARTICIPANT_ID_HASH);
        assertEq(uint8(record.participantType), uint8(ParticipantType.MAKER));
        assertEq(uint8(record.status), uint8(ParticipantStatus.PAUSED));
        assertEq(record.validUntil, input.validUntil);
        assertEq(record.version, 2);
        assertEq(record.evidenceHash, EVIDENCE_HASH);
        assertTrue(upgraded.hasRole(Roles.DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(upgraded.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(upgraded.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(upgraded.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
        assertTrue(upgraded.hasRole(Roles.UPGRADER_ROLE, address(timelock)));
        assertEq(upgraded.getDependentDvpCount(), 1);
        (address dvp, bool retiredExempt) = upgraded.getDependentDvp(0);
        assertEq(dvp, address(dependentDvp));
        assertFalse(retiredExempt);
    }

    function _assertUpdatedLog(
        Vm.Log memory entry,
        ParticipantStatus oldStatus,
        ParticipantStatus newStatus,
        uint64 validUntil,
        uint64 oldVersion,
        uint64 newVersion,
        bytes32 evidenceHash,
        address actor
    ) private view {
        assertEq(entry.emitter, address(registry));
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], PARTICIPANT_UPDATED_TOPIC);
        assertEq(entry.topics[1], bytes32(uint256(uint160(WALLET))));
        assertEq(entry.topics[2], PARTICIPANT_ID_HASH);
        ParticipantUpdatedData memory data = abi.decode(entry.data, (ParticipantUpdatedData));
        assertEq(data.chainId, block.chainid);
        assertEq(uint8(data.participantType), uint8(ParticipantType.MAKER));
        assertEq(uint8(data.oldStatus), uint8(oldStatus));
        assertEq(uint8(data.newStatus), uint8(newStatus));
        assertEq(data.validUntil, validUntil);
        assertEq(data.oldVersion, oldVersion);
        assertEq(data.newVersion, newVersion);
        assertEq(data.evidenceHash, evidenceHash);
        assertEq(data.actor, actor);
    }

    function _setParticipant(ParticipantInput memory input, uint64 expectedVersion) private {
        vm.prank(CONFIGURER);
        registry.setParticipant(input, expectedVersion);
    }

    function _input(address wallet, bytes32 participantIdHash, ParticipantType participantType)
        private
        view
        returns (ParticipantInput memory input)
    {
        input = ParticipantInput({
            wallet: wallet,
            participantIdHash: participantIdHash,
            participantType: participantType,
            validUntil: uint64(block.timestamp + 30 days),
            evidenceHash: EVIDENCE_HASH
        });
    }
}
