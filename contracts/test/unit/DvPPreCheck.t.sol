// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ProtocolSecurityLimits} from "src/libraries/ProtocolSecurityLimits.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IAssetVersionRegistry} from "src/interfaces/IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "src/interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IParticipantRegistry} from "src/interfaces/IParticipantRegistry.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {IPrincipalCalculatorRegistry} from "src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {
    AssetClass,
    AdapterRecord,
    AdapterStatus,
    AssetVersionRecord,
    AssetVersionStatus,
    CalculatorStatus,
    Decision,
    EligibilityInput,
    EligibilityRecord,
    FeeVersionRecord,
    FeeVersionStatus,
    NonceStatus,
    NonceType,
    ParticipantInput,
    ParticipantType,
    PrincipalCalculatorRecord,
    ReasonCode,
    RequesterSide,
    RoundingMode,
    SettlementParams,
    SettlementTokenRecord,
    SettlementTokenStatus,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract RevertingPreCheck1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("SIGNATURE_BACKEND_UNAVAILABLE");
    }
}

contract WrongMagicPreCheck1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

contract DvPPreCheckTest is DvPPreCheckTestBase {
    // DvPSettlement 三张占用表的存储槽，取自 forge inspect storage。
    uint256 private constant USED_QUOTE_HASH_SLOT = 2;
    uint256 private constant USED_SNAPSHOT_HASH_SLOT = 3;
    uint256 private constant USED_TRADE_ID_HASH_SLOT = 4;

    struct ObservablePreCheckState {
        NonceStatus makerNonce;
        NonceStatus requesterNonce;
        EligibilityRecord senderEligibility;
        EligibilityRecord receiverEligibility;
        uint256 sellerAssetBalance;
        uint256 buyerSettlementBalance;
        uint256 assetAllowance;
        uint256 settlementAllowance;
        uint256 assetPermitCalls;
        uint256 settlementPermitCalls;
    }

    function testPhase13ReasonSelectorsMatchReviewedLiterals() public pure {
        _assertSelector(HTPErrors.ExternalCallFailed.selector, 0xd4937b6b);
        _assertSelector(HTPErrors.ParticipantInactive.selector, 0xfe1042c2);
        _assertSelector(HTPErrors.ParticipantRelationshipInvalid.selector, 0xffb6443d);
        _assertSelector(HTPErrors.AssetVersionInactive.selector, 0xecbad3e4);
        _assertSelector(HTPErrors.SettlementTokenInactive.selector, 0xc1831f12);
        _assertSelector(HTPErrors.AdapterInactive.selector, 0x79ad8b65);
        _assertSelector(HTPErrors.CalculatorInactive.selector, 0xc3873134);
        _assertSelector(HTPErrors.InvalidQuantityRange.selector, 0x2d7e8237);
        _assertSelector(HTPErrors.InvalidQuantityStep.selector, 0xdd5180bf);
        _assertSelector(HTPErrors.InvalidSettlementTimeWindow.selector, 0xc7f2f589);
        _assertSelector(HTPErrors.FeeSnapshotMismatch.selector, 0x6eb3d67b);
        _assertSelector(HTPErrors.TransferRestricted.selector, 0x675873e9);
        _assertSelector(HTPErrors.InsufficientAllowance.selector, 0x91beda24);
        _assertSelector(HTPErrors.PermitSimulationRequired.selector, 0xc856379c);
        // 三张占用表的 reason 与 settle 的 revert 同源，钉死后两侧不会各自漂移。
        _assertSelector(HTPErrors.QuoteAlreadyExecuted.selector, 0x75dc6cf6);
        _assertSelector(HTPErrors.SnapshotAlreadyExecuted.selector, 0x0ef7c78f);
        _assertSelector(HTPErrors.TradeAlreadyExecuted.selector, 0xd8f6883f);
    }

    function testZeroSettlementParamsBlockWithoutStateChange() public {
        SettlementParams memory params;

        vm.recordLogs();
        (Decision decision, bytes4 reason) = dvp.preCheck(params);

        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSettlementParams.selector);
        assertEq(uint8(dvp.getNonceStatus(address(0), NonceType.MAKER_QUOTE, 0)), uint8(NonceStatus.UNUSED));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testDecodedMissingRequiredAddressBlocksWithoutRevert() public view {
        SettlementParams memory params;
        params.firmQuote.schemaVersion = 1;
        params.tradeIntent.schemaVersion = 1;
        params.snapshot.schemaVersion = 1;

        (Decision decision, bytes4 reason) = dvp.preCheck(params);

        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSettlementParams.selector);
    }

    function testUnsupportedSchemaVersionBlocksWithoutRevert() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.firmQuote.schemaVersion = 2;

        (Decision decision, bytes4 reason) = dvp.preCheck(params);

        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, HTPErrors.InvalidSettlementParams.selector);
    }

    function testExternalRegistryFailureReturnsUnknownWithoutRevert() public {
        vm.warp(1_780_000_100);
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(participantRegistry),
            abi.encodeWithSelector(IParticipantRegistry.getParticipant.selector, params.firmQuote.quotingMaker),
            bytes("REGISTRY_FAILURE")
        );

        (Decision decision, bytes4 reason) = dvp.preCheck(params);

        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(reason, HTPErrors.ExternalCallFailed.selector);
    }

    function testEligibilityRegistryFailureIsUnknownInPreCheckAndFailClosedInSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(eligibilityRegistry),
            abi.encodeCall(IEligibilityRegistry.isEligible, (params.snapshot.seller, params.snapshot.assetVersionId)),
            bytes("ELIGIBILITY_REGISTRY_FAILURE")
        );

        _assertDecision(params, Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ExternalCallFailed.selector, IEligibilityRegistry.isEligible.selector)
        );
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testEip1271RevertReturnsUnknownWithoutRevert() public {
        SettlementParams memory params = _validPreCheckParams();
        address wallet = address(new RevertingPreCheck1271Wallet());
        params.firmQuote.quotingMaker = wallet;
        params.tradeIntent.quotingMaker = wallet;
        params.snapshot.quotingMaker = wallet;
        params.tradeIntent.seller = wallet;
        params.snapshot.seller = wallet;
        _resign(params);

        _assertDecision(params, Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
    }

    function testEip1271WrongMagicIsDeterministicBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        address wallet = address(new WrongMagicPreCheck1271Wallet());
        params.firmQuote.quotingMaker = wallet;
        params.tradeIntent.quotingMaker = wallet;
        params.snapshot.quotingMaker = wallet;
        params.tradeIntent.seller = wallet;
        params.snapshot.seller = wallet;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSignature.selector);
    }

    function testInvalidEoaSignatureBlocksEvenWhenOtherSignerIsContract() public {
        SettlementParams memory params = _validPreCheckParams();
        address requesterWallet = address(new WrongMagicPreCheck1271Wallet());
        params.firmQuote.requester = requesterWallet;
        params.tradeIntent.requester = requesterWallet;
        params.snapshot.requester = requesterWallet;
        params.tradeIntent.buyer = requesterWallet;
        params.snapshot.buyer = requesterWallet;
        _resign(params);
        params.quotingMakerSignature[0] = bytes1(uint8(params.quotingMakerSignature[0]) ^ 1);

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSignature.selector);
    }

    function testGlobalPauseAndRetirementBlockBeforeExternalValidation() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 evidenceHash = bytes32(uint256(0xA13));

        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, evidenceHash);
        (Decision pausedDecision, bytes4 pausedReason) = dvp.preCheck(params);
        assertEq(uint8(pausedDecision), uint8(Decision.BLOCK));
        assertEq(pausedReason, HTPErrors.ContractPaused.selector);

        vm.prank(address(timelock));
        dvp.retire(ReasonCode.PLANNED_MIGRATION, evidenceHash);
        (Decision retiredDecision, bytes4 retiredReason) = dvp.preCheck(params);
        assertEq(uint8(retiredDecision), uint8(Decision.BLOCK));
        assertEq(retiredReason, HTPErrors.RetiredContract.selector);
    }

    function testFullyValidSettlementParamsPassWithoutStateChanges() public {
        SettlementParams memory params = _validPreCheckParams();
        ObservablePreCheckState memory beforeState = _snapshotState(params);

        vm.recordLogs();
        (Decision decision, bytes4 reason) = dvp.preCheck(params);

        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
        _assertStateUnchanged(beforeState, _snapshotState(params));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testParticipantCurrentStateAndTypeBlockOldSignedTrade() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(REGISTRY_PAUSER);
        participantRegistry.pauseParticipant(
            params.firmQuote.quotingMaker, 1, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        _assertDecision(params, Decision.BLOCK, HTPErrors.ParticipantInactive.selector);
    }

    function testRevokedParticipantBlocksOldSignedTrade() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(address(timelock));
        participantRegistry.revokeParticipant(params.firmQuote.quotingMaker, 1, EVIDENCE_HASH);
        _assertDecision(params, Decision.BLOCK, HTPErrors.ParticipantInactive.selector);
    }

    function testParticipantExpiryAtCurrentTimestampBlocks() public {
        SettlementParams memory params = _validPreCheckParams();
        uint64 validUntil = CREATED_AT + 1;
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: params.firmQuote.quotingMaker,
                participantIdHash: bytes32(uint256(0xA001)),
                participantType: ParticipantType.MAKER,
                validUntil: validUntil,
                evidenceHash: EVIDENCE_HASH
            }),
            1
        );
        vm.warp(validUntil);

        _assertDecision(params, Decision.BLOCK, HTPErrors.ParticipantInactive.selector);
    }

    function testBuySettlementWalletsMustMatchUniqueDerivedFlow() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.buyer = params.snapshot.seller;
        params.snapshot.buyer = params.snapshot.seller;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSettlementParams.selector);
    }

    function testSellDerivesBuyerSellerAndAssetFlow() public {
        SettlementParams memory params = _validPreCheckParams();
        address maker = params.firmQuote.quotingMaker;
        address requester = params.firmQuote.requester;
        params.firmQuote.requesterSide = RequesterSide.SELL;
        params.tradeIntent.requesterSide = RequesterSide.SELL;
        params.snapshot.requesterSide = RequesterSide.SELL;
        params.tradeIntent.buyer = maker;
        params.snapshot.buyer = maker;
        params.tradeIntent.seller = requester;
        params.snapshot.seller = requester;
        _applyFeeAmounts(params, ParticipantType.MAKER, params.firmQuote.requesterType, feeConfig);
        assetToken.setAllowance(requester, address(dvp), params.snapshot.executedQuantity);
        settlementToken.setAllowance(maker, address(dvp), params.snapshot.buyerDebit);
        _resign(params);

        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    function testCollectorMustBeDisjointFromParticipantsTokensAndDvp() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.collector = params.snapshot.buyer;
        params.snapshot.collector = params.snapshot.buyer;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSettlementParams.selector);
    }

    function testQuantityRangeAndRelativeStepAreEnforced() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.executedQuantity = 10 ether + 1;
        params.snapshot.executedQuantity = 10 ether + 1;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidQuantityStep.selector);

        params = _validPreCheckParams();
        params.tradeIntent.executedQuantity = params.firmQuote.maxExecutableQuantity + 1;
        params.snapshot.executedQuantity = params.firmQuote.maxExecutableQuantity + 1;
        _resign(params);
        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidQuantityRange.selector);

        params = _validPreCheckParams();
        params.firmQuote.stepQuantity = 0;
        _resign(params);
        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidQuantityStep.selector);
    }

    function testTimeBoundariesIncludeEqualityAndRejectOneSecondLate() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.warp(params.snapshot.tradeDeadline);
        _assertDecision(params, Decision.PASS, bytes4(0));

        vm.warp(params.snapshot.tradeDeadline + 1);
        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSettlementTimeWindow.selector);
    }

    // 时间戳之间的先后关系不约束窗口有多长。没有寿命上限，Executor 就持有一份
    // 按窗口长度计价的免费择时期权，createdAt 也能回填到任意过去以套用旧费率。
    function testQuoteLifetimeIsCappedByProtocolNotByOperatorConfiguration() public {
        SettlementParams memory params = _validPreCheckParams();
        assertLe(
            params.snapshot.tradeDeadline - params.snapshot.createdAt,
            ProtocolSecurityLimits.MAX_QUOTE_LIFETIME,
            "baseline fixture must stay inside the protocol bound"
        );

        // 恰好等于上限仍应放行，避免把边界写成排他。quoteExpiresAt 需同步抬高，
        // 否则先撞上既有的 tradeDeadline <= quoteExpiresAt 约束，测不到本上限。
        uint64 atCap = params.snapshot.createdAt + ProtocolSecurityLimits.MAX_QUOTE_LIFETIME;
        params.snapshot.tradeDeadline = atCap;
        params.tradeIntent.deadline = atCap;
        params.snapshot.quoteExpiresAt = atCap;
        params.firmQuote.expiresAt = atCap;
        _resign(params);
        vm.warp(params.snapshot.createdAt);
        _assertDecision(params, Decision.PASS, bytes4(0));

        // 超出一秒即拒，且与「过期」共用同一个结构化错误。
        params.snapshot.tradeDeadline = atCap + 1;
        params.tradeIntent.deadline = atCap + 1;
        params.snapshot.quoteExpiresAt = atCap + 1;
        params.firmQuote.expiresAt = atCap + 1;
        _resign(params);
        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSettlementTimeWindow.selector);
    }

    // preCheck 的归因质量在运营上是有意义的：BLOCK 表示「参数非法，拒绝即可」，
    // UNKNOWN 表示「外部依赖故障，需要排查」。validator 内部任何算术下溢都会被
    // DvPSettlement 的 try/catch 兜住，因而不表现为 revert，而是静默把前者降级成
    // 后者——制造假警报，且在链上看不出根因。本用例已验证有效：把窗口上限改回
    // tradeDeadline - createdAt 并前移到 || 链首位，fuzz 首轮即给出反例。
    function testFuzzPreCheckReturnsDecisionInsteadOfRevertingOnAnyTimeWindow(
        uint64 createdAt,
        uint64 tradeDeadline,
        uint64 quoteExpiresAt
    ) public {
        SettlementParams memory params = _validPreCheckParams();
        params.snapshot.createdAt = createdAt;
        params.snapshot.tradeDeadline = tradeDeadline;
        params.snapshot.quoteExpiresAt = quoteExpiresAt;
        params.firmQuote.expiresAt = quoteExpiresAt;
        params.tradeIntent.deadline = tradeDeadline;
        _resign(params);

        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertTrue(decision == Decision.PASS || decision == Decision.BLOCK, "decision must stay well-formed");
        if (decision == Decision.PASS) {
            assertEq(reason, bytes4(0), "PASS carries no reason");
            assertLe(
                uint256(tradeDeadline) - uint256(createdAt),
                ProtocolSecurityLimits.MAX_QUOTE_LIFETIME,
                "PASS implies the window is within the protocol bound"
            );
        }
    }

    function testCreatedAtMustFallInsidePolicyWindowsAndNotAfterCurrentTime() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.snapshot.createdAt = QUOTE_VALID_FROM - 1;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.MarketRuleSnapshotMismatch.selector);
    }

    function testInactiveConfigurationMatrixFailsClosed() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(REGISTRY_PAUSER);
        assetVersionRegistry.pauseAssetVersion(
            assetVersionConfig.assetVersionId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH
        );
        _assertDecision(params, Decision.BLOCK, HTPErrors.AssetVersionInactive.selector);
    }

    function testRegisteredAndDeprecatedAssetVersionsBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        AssetVersionRecord memory record = assetVersionRegistry.getAssetVersion(assetVersionConfig.assetVersionId);
        bytes memory callData =
            abi.encodeWithSelector(IAssetVersionRegistry.getAssetVersion.selector, assetVersionConfig.assetVersionId);

        record.status = AssetVersionStatus.REGISTERED;
        vm.mockCall(address(assetVersionRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.AssetVersionInactive.selector);
        vm.clearMockedCalls();

        record.status = AssetVersionStatus.DEPRECATED;
        vm.mockCall(address(assetVersionRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.AssetVersionInactive.selector);
    }

    function testRegisteredAndDeprecatedSettlementTokensBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        SettlementTokenRecord memory record = settlementTokenRegistry.getSettlementToken(settlementTokenConfig.configId);
        bytes memory callData = abi.encodeWithSelector(
            ISettlementTokenRegistry.getSettlementToken.selector, settlementTokenConfig.configId
        );

        record.status = SettlementTokenStatus.REGISTERED;
        vm.mockCall(address(settlementTokenRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.SettlementTokenInactive.selector);
        vm.clearMockedCalls();

        record.status = SettlementTokenStatus.DEPRECATED;
        vm.mockCall(address(settlementTokenRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.SettlementTokenInactive.selector);
    }

    function testRegisteredAndDeprecatedAdaptersBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        AdapterRecord memory record = adapterRegistry.getAdapter(adapterConfig.adapterConfigId);
        bytes memory callData =
            abi.encodeWithSelector(IAdapterRegistry.getAdapter.selector, adapterConfig.adapterConfigId);

        record.status = AdapterStatus.REGISTERED;
        vm.mockCall(address(adapterRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.AdapterInactive.selector);
        vm.clearMockedCalls();

        record.status = AdapterStatus.DEPRECATED;
        vm.mockCall(address(adapterRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.AdapterInactive.selector);
    }

    function testRegisteredAndDeprecatedCalculatorsBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        PrincipalCalculatorRecord memory record =
            calculatorRegistry.getPrincipalCalculator(calculatorConfig.calculatorConfigId);
        bytes memory callData = abi.encodeWithSelector(
            IPrincipalCalculatorRegistry.getPrincipalCalculator.selector, calculatorConfig.calculatorConfigId
        );

        record.status = CalculatorStatus.REGISTERED;
        vm.mockCall(address(calculatorRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.CalculatorInactive.selector);
        vm.clearMockedCalls();

        record.status = CalculatorStatus.DEPRECATED;
        vm.mockCall(address(calculatorRegistry), callData, abi.encode(record));
        _assertDecision(params, Decision.BLOCK, HTPErrors.CalculatorInactive.selector);
    }

    function testSignedHistoricalIdsNeverFallBackToCurrentPointers() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(assetVersionRegistry),
            abi.encodeWithSelector(IAssetVersionRegistry.getCurrentAssetVersion.selector, address(assetToken)),
            bytes("CURRENT_ASSET_FORBIDDEN")
        );
        vm.mockCallRevert(
            address(settlementTokenRegistry),
            abi.encodeWithSelector(
                ISettlementTokenRegistry.getCurrentSettlementToken.selector, address(settlementToken)
            ),
            bytes("CURRENT_SETTLEMENT_FORBIDDEN")
        );
        vm.mockCallRevert(
            address(adapterRegistry),
            abi.encodeWithSelector(IAdapterRegistry.getCurrentAdapter.selector, adapterConfig.capabilityHash),
            bytes("CURRENT_ADAPTER_FORBIDDEN")
        );
        vm.mockCallRevert(
            address(calculatorRegistry),
            abi.encodeWithSelector(
                IPrincipalCalculatorRegistry.getCurrentPrincipalCalculator.selector, AssetClass.FUND
            ),
            bytes("CURRENT_CALCULATOR_FORBIDDEN")
        );

        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    function testPausedSettlementTokenAdapterCalculatorAndFeeAllBlock() public {
        SettlementParams memory params = _validPreCheckParams();

        vm.prank(REGISTRY_PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            settlementTokenConfig.configId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH
        );
        _assertDecision(params, Decision.BLOCK, HTPErrors.SettlementTokenInactive.selector);
        vm.prank(address(timelock));
        settlementTokenRegistry.unpauseSettlementToken(
            settlementTokenConfig.configId,
            settlementTokenConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );

        vm.prank(REGISTRY_PAUSER);
        adapterRegistry.pauseAdapter(adapterConfig.adapterConfigId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH);
        _assertDecision(params, Decision.BLOCK, HTPErrors.AdapterInactive.selector);
        vm.prank(address(timelock));
        adapterRegistry.unpauseAdapter(
            adapterConfig.adapterConfigId, adapterConfig.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );

        vm.prank(REGISTRY_PAUSER);
        calculatorRegistry.pausePrincipalCalculator(
            calculatorConfig.calculatorConfigId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH
        );
        _assertDecision(params, Decision.BLOCK, HTPErrors.CalculatorInactive.selector);
        vm.prank(address(timelock));
        calculatorRegistry.unpausePrincipalCalculator(
            calculatorConfig.calculatorConfigId,
            calculatorConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );

        vm.prank(REGISTRY_PAUSER);
        feeRegistry.pauseFeeVersion(feeConfig.feeVersionId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH);
        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeSnapshotMismatch.selector);
    }

    function testDeprecatedFeeRemainsServiceableInsideBoundWindow() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(address(timelock));
        feeRegistry.deprecateFeeVersion(feeConfig.feeVersionId, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);

        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    function testRegisteredFeeVersionBlocks() public {
        SettlementParams memory params = _validPreCheckParams();
        FeeVersionRecord memory record = feeRegistry.getFeeVersion(feeConfig.feeVersionId);
        record.status = FeeVersionStatus.REGISTERED;
        vm.mockCall(
            address(feeRegistry),
            abi.encodeWithSelector(IFeeRegistry.getFeeVersion.selector, feeConfig.feeVersionId),
            abi.encode(record)
        );

        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeSnapshotMismatch.selector);
    }

    function testTokenCodeHashAndDecimalsAreRechecked() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(address(assetToken), abi.encodeWithSelector(bytes4(0x313ce567)), abi.encode(uint256(17)));

        _assertDecision(params, Decision.BLOCK, HTPErrors.AssetDecimalsMismatch.selector);

        vm.clearMockedCalls();
        params = _validPreCheckParams();
        vm.mockCall(address(settlementToken), abi.encodeWithSelector(bytes4(0x313ce567)), abi.encode(uint256(5)));
        _assertDecision(params, Decision.BLOCK, HTPErrors.SettlementTokenDecimalsMismatch.selector);
    }

    function testCalculatorAndFeeSnapshotMutationsBlock() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.cashPrincipal += 1;
        params.snapshot.cashPrincipal += 1;
        _resign(params);
        _assertDecision(params, Decision.BLOCK, HTPErrors.CashPrincipalZero.selector);

        params = _validPreCheckParams();
        params.firmQuote.feeConstraintHash = bytes32(uint256(0xBAD));
        params.tradeIntent.feeConstraintHash = bytes32(uint256(0xBAD));
        params.snapshot.feeConstraintHash = bytes32(uint256(0xBAD));
        _resign(params);
        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeSnapshotMismatch.selector);
    }

    function testRoundingModeMustBeDownAndMatchFeeConfiguration() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.tradeIntent.roundingMode = RoundingMode.NONE;
        params.snapshot.roundingMode = RoundingMode.NONE;
        _resign(params);

        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeSnapshotMismatch.selector);
    }

    function testCalculatorExternalFailureReturnsUnknown() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(calculator),
            abi.encodeWithSelector(
                IPrincipalCalculator.calculate.selector,
                params.snapshot.priceData,
                params.snapshot.executedQuantity,
                params.snapshot.assetDecimals
            ),
            bytes("CALCULATOR_UNAVAILABLE")
        );

        _assertDecision(params, Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
    }

    function testStructuredFeeResolverNoMatchIsDeterministicBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCallRevert(
            address(feeRegistry),
            abi.encodeWithSelector(
                IFeeRegistry.resolveApplicableFee.selector,
                params.snapshot.feePolicyEpoch,
                params.snapshot.assetVersionId
            ),
            abi.encodeWithSelector(
                HTPErrors.FeeResolverNoMatch.selector, params.snapshot.feePolicyEpoch, params.snapshot.assetVersionId
            )
        );

        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeResolverNoMatch.selector);
    }

    function testFeeResolverResultDriftIsDeterministicBlock() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.mockCall(
            address(feeRegistry),
            abi.encodeWithSelector(
                IFeeRegistry.resolveApplicableFee.selector,
                params.snapshot.feePolicyEpoch,
                params.snapshot.assetVersionId
            ),
            abi.encode(bytes32(uint256(0xBAD)), params.snapshot.matchedScopeHash)
        );

        _assertDecision(params, Decision.BLOCK, HTPErrors.FeeSnapshotMismatch.selector);
    }

    function testAdapterBlockAndMalformedReturnFailClosed() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes memory assetCall = abi.encodeWithSelector(
            bytes4(0x4b5cf187),
            params.snapshot.assetToken,
            params.snapshot.seller,
            params.snapshot.buyer,
            params.snapshot.executedQuantity,
            uint8(1),
            params.tradeIntent.snapshotHash
        );
        vm.mockCall(address(adapter), assetCall, abi.encode(Decision.BLOCK, uint256(77), bytes32(uint256(0xBAD))));
        _assertDecision(params, Decision.BLOCK, HTPErrors.TransferRestricted.selector);

        vm.mockCall(address(adapter), assetCall, hex"01");
        _assertDecision(params, Decision.UNKNOWN, HTPErrors.ExternalCallFailed.selector);
    }

    function testAllThreeNonzeroAdapterLegsUseExactInputs() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes memory fallbackCall = abi.encodeWithSelector(IAssetAdapter.preCheck.selector);
        vm.mockCall(address(adapter), fallbackCall, abi.encode(Decision.BLOCK, uint256(999), bytes32(uint256(0xBAD))));
        bytes memory passResult = abi.encode(Decision.PASS, uint256(0), bytes32(0));
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(
                IAssetAdapter.preCheck.selector,
                params.snapshot.assetToken,
                params.snapshot.seller,
                params.snapshot.buyer,
                params.snapshot.executedQuantity,
                TransferLeg.ASSET,
                params.tradeIntent.snapshotHash
            ),
            passResult
        );
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(
                IAssetAdapter.preCheck.selector,
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.seller,
                params.snapshot.sellerCredit,
                TransferLeg.SETTLEMENT_TO_SELLER,
                params.tradeIntent.snapshotHash
            ),
            passResult
        );
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(
                IAssetAdapter.preCheck.selector,
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.collector,
                params.snapshot.collectorCredit,
                TransferLeg.SETTLEMENT_TO_COLLECTOR,
                params.tradeIntent.snapshotHash
            ),
            passResult
        );

        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    function testZeroCollectorCreditSkipsCollectorAdapterLeg() public {
        SettlementParams memory params = _zeroCollectorParams();
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSelector(
                bytes4(0x4b5cf187),
                params.snapshot.settlementToken,
                params.snapshot.buyer,
                params.snapshot.collector,
                uint256(0),
                uint8(3),
                params.tradeIntent.snapshotHash
            ),
            bytes("ZERO_LEG_MUST_BE_SKIPPED")
        );

        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    // 卖方零收款曾由 maker 档 100% 配置出来，聚合费率上限已使其在登记期不可达
    // （断言见 FeeRegistryConfig.t.sol）。这里改为确认结算腿在可登记的费率下恒非零，
    // 也就是资产交割必然伴随现金对付。
    function testSettlementLegIsAlwaysNonZeroUnderRegistrableFees() public {
        SettlementParams memory params = _validPreCheckParams();
        assertGt(params.snapshot.sellerCredit, 0, "asset delivery must be paid for");
        _assertDecision(params, Decision.PASS, bytes4(0));
    }

    function testEligibilityReflectsCurrentState() public {
        SettlementParams memory params = _validPreCheckParams();
        bytes32 senderKey = keccak256(abi.encode(block.chainid, params.snapshot.seller, params.snapshot.assetVersionId));
        vm.prank(REGISTRY_PAUSER);
        eligibilityRegistry.pauseEligibility(senderKey, 1, ReasonCode.ELIGIBILITY_INCIDENT, EVIDENCE_HASH);

        _assertDecision(params, Decision.BLOCK, HTPErrors.EligibilityPausedOrRevoked.selector);
        assertEq(eligibilityRegistry.getEligibility(senderKey).recordVersion, 2);
    }

    function testExpiredEligibilityBlocksPreCheckAndStrictSettlement() public {
        SettlementParams memory params = _validPreCheckParams();
        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: params.snapshot.seller,
                assetVersionId: params.snapshot.assetVersionId,
                decision: Decision.PASS,
                validFrom: QUOTE_VALID_FROM,
                validUntil: uint64(block.timestamp - 1),
                kycDecisionVersion: bytes32(uint256(0xD200)),
                permissionVersion: bytes32(uint256(0xD201)),
                evidenceHash: EVIDENCE_HASH
            }),
            1
        );

        _assertDecision(params, Decision.BLOCK, HTPErrors.EligibilityExpired.selector);
        vm.expectPartialRevert(HTPErrors.EligibilityExpired.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testAllowanceAndPermitDecisionMatrix() public {
        SettlementParams memory params = _validPreCheckParams();
        assetToken.setAllowance(params.snapshot.seller, address(dvp), 0);
        _assertDecision(params, Decision.BLOCK, HTPErrors.InsufficientAllowance.selector);

        params.assetPermit.usePermit = true;
        params.assetPermit.owner = params.snapshot.seller;
        params.assetPermit.token = params.snapshot.assetToken;
        params.assetPermit.value = params.snapshot.executedQuantity;
        params.assetPermit.deadline = params.snapshot.tradeDeadline;
        params.assetPermit.v = 27;
        params.assetPermit.r = bytes32(uint256(1));
        params.assetPermit.s = bytes32(uint256(2));
        _assertDecision(params, Decision.UNKNOWN, HTPErrors.PermitSimulationRequired.selector);
        assertEq(assetToken.permitCalls(), 0);
    }

    function testProvidedPermitMustBeCanonicalEvenWhenAllowanceAlreadySuffices() public view {
        SettlementParams memory params = _validPreCheckParams();
        params.assetPermit.usePermit = true;
        params.assetPermit.owner = params.snapshot.buyer;
        params.assetPermit.token = params.snapshot.assetToken;
        params.assetPermit.value = params.snapshot.executedQuantity;
        params.assetPermit.deadline = params.snapshot.tradeDeadline;
        params.assetPermit.v = 27;
        params.assetPermit.r = bytes32(uint256(1));
        params.assetPermit.s = bytes32(uint256(2));

        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSettlementParams.selector);
    }

    // settle 的 _validateReplayAvailability 与 preCheck 共用 DvPSettlement._usedReplayHash。
    // 三条分支逐一断言，防止将来只有 tradeIdHash 那条被维护。
    //
    // 真实流程只构造得出 tradeIdHash 一条：quoteHash 由含 quoteNonce 的 FirmQuote 内容算出，
    // snapshotHash 同理，所以「hash 已用而 nonce 未用」对它俩不成立——已用的 quote 必然
    // 伴随已用的 nonce，preCheck 的 nonce 检查早就挡住了。另两条只能直接置位存储来覆盖。
    function testUsedReplayHashesBlockPreCheckWithSettleGradeReasons() public {
        SettlementParams memory params = _validPreCheckParams();
        _assertDecision(params, Decision.PASS, bytes4(0));

        _setReplayHashUsed(USED_QUOTE_HASH_SLOT, params.tradeIntent.quoteHash, true);
        _assertDecision(params, Decision.BLOCK, HTPErrors.QuoteAlreadyExecuted.selector);
        _setReplayHashUsed(USED_QUOTE_HASH_SLOT, params.tradeIntent.quoteHash, false);

        _setReplayHashUsed(USED_SNAPSHOT_HASH_SLOT, params.tradeIntent.snapshotHash, true);
        _assertDecision(params, Decision.BLOCK, HTPErrors.SnapshotAlreadyExecuted.selector);
        _setReplayHashUsed(USED_SNAPSHOT_HASH_SLOT, params.tradeIntent.snapshotHash, false);

        // 唯一在真实流程里可达的一条：tradeIdHash 是链下自由值，与 nonce 解耦。
        _setReplayHashUsed(USED_TRADE_ID_HASH_SLOT, params.tradeIntent.tradeIdHash, true);
        _assertDecision(params, Decision.BLOCK, HTPErrors.TradeAlreadyExecuted.selector);
    }

    // 占用表在签名之后才查：载荷本身不成立时，报的仍是签名/入参问题而非防重放，
    // 与 _settle 的步骤顺序一致。
    function testReplayHashCheckStaysBehindSignatureValidation() public {
        SettlementParams memory params = _validPreCheckParams();
        _setReplayHashUsed(USED_TRADE_ID_HASH_SLOT, params.tradeIntent.tradeIdHash, true);

        params.requesterSignature = hex"";
        _assertDecision(params, Decision.BLOCK, HTPErrors.InvalidSignature.selector);
    }

    function _setReplayHashUsed(uint256 mappingSlot, bytes32 key, bool used) private {
        vm.store(address(dvp), keccak256(abi.encode(key, mappingSlot)), bytes32(uint256(used ? 1 : 0)));
    }

    function _snapshotState(SettlementParams memory params)
        private
        view
        returns (ObservablePreCheckState memory state)
    {
        state.makerNonce = dvp.getNonceStatus(
            params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce
        );
        state.requesterNonce =
            dvp.getNonceStatus(params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce);
        state.senderEligibility = eligibilityRegistry.getEligibility(
            keccak256(abi.encode(block.chainid, params.snapshot.seller, params.snapshot.assetVersionId))
        );
        state.receiverEligibility = eligibilityRegistry.getEligibility(
            keccak256(abi.encode(block.chainid, params.snapshot.buyer, params.snapshot.assetVersionId))
        );
        state.sellerAssetBalance = assetToken.balanceOf(params.snapshot.seller);
        state.buyerSettlementBalance = settlementToken.balanceOf(params.snapshot.buyer);
        state.assetAllowance = assetToken.allowance(params.snapshot.seller, address(dvp));
        state.settlementAllowance = settlementToken.allowance(params.snapshot.buyer, address(dvp));
        state.assetPermitCalls = assetToken.permitCalls();
        state.settlementPermitCalls = settlementToken.permitCalls();
    }

    function _assertStateUnchanged(
        ObservablePreCheckState memory beforeState,
        ObservablePreCheckState memory afterState
    ) private pure {
        assertEq(uint8(afterState.makerNonce), uint8(beforeState.makerNonce));
        assertEq(uint8(afterState.requesterNonce), uint8(beforeState.requesterNonce));
        assertEq(afterState.senderEligibility.recordVersion, beforeState.senderEligibility.recordVersion);
        assertEq(afterState.receiverEligibility.recordVersion, beforeState.receiverEligibility.recordVersion);
        assertEq(afterState.sellerAssetBalance, beforeState.sellerAssetBalance);
        assertEq(afterState.buyerSettlementBalance, beforeState.buyerSettlementBalance);
        assertEq(afterState.assetAllowance, beforeState.assetAllowance);
        assertEq(afterState.settlementAllowance, beforeState.settlementAllowance);
        assertEq(afterState.assetPermitCalls, beforeState.assetPermitCalls);
        assertEq(afterState.settlementPermitCalls, beforeState.settlementPermitCalls);
    }

    function _assertDecision(SettlementParams memory params, Decision expectedDecision, bytes4 expectedReason)
        private
        view
    {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(expectedDecision));
        assertEq(reason, expectedReason);
    }

    function _assertSelector(bytes4 actual, bytes4 expected) private pure {
        assertEq(bytes32(actual), bytes32(expected));
    }
}
