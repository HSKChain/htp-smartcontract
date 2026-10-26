// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {ParticipantInput, ParticipantRecord, ParticipantType} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

/// @notice SlowMist N13: participant creation and updates require non-zero evidence.
contract SlowMistN13ParticipantEvidenceRequiredTest is RegistryTestBase {
    address private constant PAUSER = address(0x2201);
    address private constant CONFIGURER = address(0x3201);
    address private constant WALLET = address(0x4201);
    bytes32 private constant PARTICIPANT_ID_HASH = bytes32(uint256(0x5001));
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0xE001));

    ParticipantRegistry private registry;

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

    function test_N13_CreateRejectsZeroEvidenceHash() public {
        ParticipantInput memory input = _input();
        input.evidenceHash = bytes32(0);
        ParticipantRecord memory beforeCreate = registry.getParticipant(WALLET);

        vm.recordLogs();
        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(CONFIGURER);
        registry.setParticipant(input, 0);

        assertEq(vm.getRecordedLogs().length, 0);
        _assertRecordEquals(registry.getParticipant(WALLET), beforeCreate);
    }

    function test_N13_UpdateRejectsZeroEvidenceHashWithoutChangingRecord() public {
        ParticipantInput memory input = _input();
        vm.prank(CONFIGURER);
        registry.setParticipant(input, 0);
        ParticipantRecord memory beforeUpdate = registry.getParticipant(WALLET);

        input.validUntil += 1 days;
        input.evidenceHash = bytes32(0);
        vm.recordLogs();
        vm.expectRevert(HTPErrors.EvidenceHashRequired.selector);
        vm.prank(CONFIGURER);
        registry.setParticipant(input, 1);

        assertEq(vm.getRecordedLogs().length, 0);
        _assertRecordEquals(registry.getParticipant(WALLET), beforeUpdate);
    }

    function _input() private view returns (ParticipantInput memory input) {
        input = ParticipantInput({
            wallet: WALLET,
            participantIdHash: PARTICIPANT_ID_HASH,
            participantType: ParticipantType.INVESTOR,
            validUntil: uint64(block.timestamp + 30 days),
            evidenceHash: EVIDENCE_HASH
        });
    }

    function _assertRecordEquals(ParticipantRecord memory actual, ParticipantRecord memory expected) private pure {
        assertEq(actual.wallet, expected.wallet);
        assertEq(actual.participantIdHash, expected.participantIdHash);
        assertEq(uint8(actual.participantType), uint8(expected.participantType));
        assertEq(uint8(actual.status), uint8(expected.status));
        assertEq(actual.validUntil, expected.validUntil);
        assertEq(actual.version, expected.version);
        assertEq(actual.evidenceHash, expected.evidenceHash);
    }
}
