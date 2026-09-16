// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {
    ParticipantInput,
    ParticipantRecord,
    ParticipantStatus,
    ParticipantType,
    ReasonCode
} from "src/types/HTPTypes.sol";
import {abiSelector} from "test/helpers/AbiAssertions.sol";

contract ParticipantStructsAbiTest is Test {
    bytes4 private constant SET = 0xbdea0246;
    bytes4 private constant PAUSE = 0x2aada92b;
    bytes4 private constant UNPAUSE = 0xe0d1aeac;
    bytes4 private constant REVOKE = 0x9b637a1c;
    bytes4 private constant GET = 0x7143059f;
    bytes4 private constant IS_ACTIVE = 0x1fe01fc7;
    bytes4 private constant REGISTER_DEPENDENT = 0x03f8d147;
    bytes4 private constant EXEMPT_RETIRED = 0xd74df627;
    bytes4 private constant GET_DEPENDENT_COUNT = 0xbafdbeba;
    bytes4 private constant GET_DEPENDENT = 0x9816d4b9;
    bytes4 private constant UPGRADE = 0x4f1ef286;

    function testParticipantInputExcludesManagedFields() public pure {
        ParticipantInput memory input = ParticipantInput({
            wallet: address(0xA11CE),
            participantIdHash: bytes32(uint256(2)),
            participantType: ParticipantType.INVESTOR,
            validUntil: 4,
            evidenceHash: bytes32(uint256(5))
        });
        assertEq(abi.encode(input).length, 5 * 32);
        bytes memory callData = abi.encodeCall(IParticipantRegistry.setParticipant, (input, uint64(0)));
        assertEq(abiSelector(callData), IParticipantRegistry.setParticipant.selector);
        assertEq(callData.length, 4 + 6 * 32);
    }

    function testParticipantRecordAddsStatusAndVersion() public pure {
        ParticipantRecord memory record;
        record.status = ParticipantStatus.ACTIVE;
        record.version = 7;
        assertEq(abi.encode(record).length, 7 * 32);
        assertEq(record.version, 7);
    }

    function testParticipantRegistryCompletePublicSelectors() public pure {
        assertEq(IParticipantRegistry.setParticipant.selector, SET);
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IParticipantRegistry.pauseParticipant,
                    (address(0), uint64(0), ReasonCode.SECURITY_INCIDENT, bytes32(uint256(1)))
                )
            ),
            PAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(
                    IParticipantRegistry.unpauseParticipant,
                    (address(0), uint64(0), ReasonCode.GOVERNANCE_ACTION, bytes32(uint256(1)))
                )
            ),
            UNPAUSE
        );
        assertEq(
            abiSelector(
                abi.encodeCall(IParticipantRegistry.revokeParticipant, (address(0), uint64(0), bytes32(uint256(1))))
            ),
            REVOKE
        );
        assertEq(abiSelector(abi.encodeCall(IParticipantRegistry.getParticipant, (address(0)))), GET);
        assertEq(
            abiSelector(abi.encodeCall(IParticipantRegistry.isParticipantActive, (address(0), ParticipantType.MAKER))),
            IS_ACTIVE
        );
        assertEq(
            abiSelector(abi.encodeCall(IParticipantRegistry.registerDependentDvp, (address(0), bytes32(uint256(1))))),
            REGISTER_DEPENDENT
        );
        assertEq(
            abiSelector(
                abi.encodeCall(IParticipantRegistry.exemptRetiredDependentDvp, (address(0), bytes32(uint256(1))))
            ),
            EXEMPT_RETIRED
        );
        assertEq(abiSelector(abi.encodeCall(IParticipantRegistry.getDependentDvpCount, ())), GET_DEPENDENT_COUNT);
        assertEq(abiSelector(abi.encodeCall(IParticipantRegistry.getDependentDvp, (0))), GET_DEPENDENT);
        assertEq(abiSelector(abi.encodeCall(IParticipantRegistry.upgradeToAndCall, (address(0), bytes("")))), UPGRADE);
    }
}
