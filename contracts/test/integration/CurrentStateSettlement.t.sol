// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    Decision,
    EligibilityInput,
    ParticipantInput,
    ParticipantType,
    ReasonCode,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract CurrentStateSettlementTest is UsdySettlementFixture {
    function testParticipantUpdateAfterPreCheckIsRevalidatedAndCanStillSettle() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));

        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: params.snapshot.seller,
                participantIdHash: bytes32(uint256(0xA001)),
                participantType: ParticipantType.MAKER,
                validUntil: SETTLEMENT_VALID_UNTIL + 1,
                evidenceHash: bytes32(uint256(0xE314))
            }),
            1
        );

        _settleUsdy(params);
        assertTrue(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
    }

    function testParticipantPauseAfterPreCheckBlocksSettlementWithoutLocks() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));

        vm.prank(REGISTRY_PAUSER);
        participantRegistry.pauseParticipant(params.snapshot.seller, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantInactive.selector, params.snapshot.seller));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testEligibilityDecisionChangeAfterPreCheckBlocksUsingCurrentState() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));

        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: params.snapshot.seller,
                assetVersionId: usdyAssetVersionConfig.assetVersionId,
                decision: Decision.BLOCK,
                validFrom: QUOTE_VALID_FROM,
                validUntil: SETTLEMENT_VALID_UNTIL,
                kycDecisionVersion: bytes32(uint256(0xD300)),
                permissionVersion: bytes32(uint256(0xD301)),
                evidenceHash: EVIDENCE_HASH
            }),
            1
        );

        vm.expectPartialRevert(HTPErrors.EligibilityNotPassed.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
    }

    function testEligibilityRecordUpdateAfterPreCheckUsesCurrentVersionWithoutConsumption() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));

        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: params.snapshot.seller,
                assetVersionId: usdyAssetVersionConfig.assetVersionId,
                decision: Decision.PASS,
                validFrom: QUOTE_VALID_FROM,
                validUntil: SETTLEMENT_VALID_UNTIL,
                kycDecisionVersion: bytes32(uint256(0xD300)),
                permissionVersion: bytes32(uint256(0xD301)),
                evidenceHash: EVIDENCE_HASH
            }),
            1
        );

        _settleUsdy(params);
        bytes32 senderKey =
            keccak256(abi.encode(block.chainid, params.snapshot.seller, usdyAssetVersionConfig.assetVersionId));
        assertEq(eligibilityRegistry.getEligibility(senderKey).recordVersion, 2);
    }
}
