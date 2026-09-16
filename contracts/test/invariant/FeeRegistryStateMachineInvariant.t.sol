// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {
    AssetClass,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    FeePolicyEpochStatus,
    FeeVersionRecord,
    FeeVersionStatus,
    ReasonCode,
    RoundingMode,
    ScopeType
} from "src/types/HTPTypes.sol";
import {FeeRegistryTestBase} from "test/helpers/FeeRegistryTestBase.sol";

struct FeeInvariantContext {
    FeeRegistry registry;
    address configurer;
    address pauser;
    address governance;
    address settlementToken;
    bytes32 settlementTokenConfigId;
    bytes32 settlementTokenConfigHash;
    bytes32 assetVersionId;
    bytes32 economicAssetIdHash;
    AssetClass assetClass;
}

contract FeeRegistryStateMachineHandler {
    uint256 private constant MAX_EPOCHS = 6;
    uint256 private constant MAX_FEES = 30;
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0x1636));

    struct EpochShadow {
        FeePolicyEpochConfig config;
        FeePolicyEpochStatus status;
        bool isSealed;
        bytes32 resolvedFeeVersionId;
        bytes32 resolvedScopeHash;
        ScopeType resolvedScopeType;
    }

    struct RegistrationPlan {
        bool expectedValid;
        uint256 epochIndex;
        uint64 epochNumber;
        ScopeType scopeType;
        FeeConfig candidate;
    }

    FeeRegistry private immutable REGISTRY;
    address private immutable CONFIGURER;
    address private immutable PAUSER;
    address private immutable GOVERNANCE;
    address private immutable SETTLEMENT_TOKEN;
    bytes32 private immutable SETTLEMENT_TOKEN_CONFIG_ID;
    bytes32 private immutable SETTLEMENT_TOKEN_CONFIG_HASH;
    bytes32 private immutable ASSET_VERSION_ID;
    bytes32 private immutable ECONOMIC_ASSET_ID_HASH;
    AssetClass private immutable ASSET_CLASS;

    EpochShadow[] private epochs;
    FeeConfig[] private fees;
    FeeVersionStatus[] private feeStatuses;
    mapping(uint64 epoch => uint256 positionPlusOne) private epochPositions;
    mapping(bytes32 feeVersionId => uint256 positionPlusOne) private feePositions;
    mapping(uint64 epoch => mapping(uint8 scope => bytes32 feeVersionId)) private latestByScope;

    uint256 public unexpectedSuccesses;
    uint256 public unexpectedReverts;

    constructor(
        FeeInvariantContext memory context,
        FeePolicyEpochConfig memory initialEpoch,
        FeeConfig memory initialFee
    ) {
        REGISTRY = context.registry;
        CONFIGURER = context.configurer;
        PAUSER = context.pauser;
        GOVERNANCE = context.governance;
        SETTLEMENT_TOKEN = context.settlementToken;
        SETTLEMENT_TOKEN_CONFIG_ID = context.settlementTokenConfigId;
        SETTLEMENT_TOKEN_CONFIG_HASH = context.settlementTokenConfigHash;
        ASSET_VERSION_ID = context.assetVersionId;
        ECONOMIC_ASSET_ID_HASH = context.economicAssetIdHash;
        ASSET_CLASS = context.assetClass;

        epochs.push(
            EpochShadow({
                config: initialEpoch,
                status: FeePolicyEpochStatus.ACTIVE,
                isSealed: true,
                resolvedFeeVersionId: initialFee.feeVersionId,
                resolvedScopeHash: initialFee.matchedScopeHash,
                resolvedScopeType: initialFee.scopeType
            })
        );
        epochPositions[initialEpoch.feePolicyEpoch] = 1;
        _recordFee(initialFee, FeeVersionStatus.ACTIVE);
    }

    function createEpoch(uint8 mode) external {
        bool expectedValid = mode % 3 == 0 && epochs.length < MAX_EPOCHS;
        uint64 nextEpoch = epochs[epochs.length - 1].config.feePolicyEpoch + 1;
        FeePolicyEpochConfig memory candidate = _newEpoch(nextEpoch);
        if (mode % 3 == 1) {
            candidate.feePolicyEpoch = nextEpoch + 1;
            candidate.configHash = HTPHashing.hashFeePolicyEpochConfig(candidate);
        } else if (mode % 3 == 2) {
            candidate.configHash = bytes32(uint256(candidate.configHash) ^ 1);
        }
        if (epochs.length >= MAX_EPOCHS && mode % 3 == 0) candidate = epochs[0].config;

        _prank(GOVERNANCE);
        try REGISTRY.createFeePolicyEpoch(candidate) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            epochs.push(
                EpochShadow({
                    config: candidate,
                    status: FeePolicyEpochStatus.DRAFT,
                    isSealed: false,
                    resolvedFeeVersionId: bytes32(0),
                    resolvedScopeHash: bytes32(0),
                    resolvedScopeType: ScopeType.NONE
                })
            );
            epochPositions[candidate.feePolicyEpoch] = epochs.length;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function registerFee(uint256 epochSeed, uint8 scopeSeed, uint8 mode, uint16 buyerRate, uint16 sellerRate) external {
        RegistrationPlan memory plan = _registrationPlan(epochSeed, scopeSeed, mode, buyerRate, sellerRate);

        _prank(CONFIGURER);
        try REGISTRY.registerFeeVersion(plan.candidate) {
            if (!plan.expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            _recordFee(plan.candidate, FeeVersionStatus.REGISTERED);
            latestByScope[plan.epochNumber][uint8(plan.scopeType)] = plan.candidate.feeVersionId;
        } catch {
            if (plan.expectedValid) ++unexpectedReverts;
        }
    }

    function sealEpoch(uint256 seed, bool correctHash) external {
        (bool known, uint256 index, uint64 epochNumber) = _selectedEpoch(seed);
        bytes32 expectedHash = known ? epochs[index].config.configHash : bytes32(uint256(0xBAD1));
        if (!correctHash) expectedHash = bytes32(uint256(expectedHash) ^ 1);
        bool expectedValid = known && !epochs[index].isSealed && correctHash;

        _prank(GOVERNANCE);
        try REGISTRY.sealFeePolicyEpoch(epochNumber, expectedHash) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            epochs[index].isSealed = true;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function transitionFee(uint256 seed, uint8 action, bool correctHash, bool validEvidence) external {
        (bool known, uint256 index, bytes32 feeVersionId) = _selectedFee(seed);
        uint8 selectedAction = action % 4;
        FeeVersionStatus status = known ? feeStatuses[index] : FeeVersionStatus.NONE;
        uint256 epochIndex = known ? epochPositions[fees[index].feePolicyEpoch] - 1 : 0;
        bool epochIsSealed = known && epochs[epochIndex].isSealed;
        bytes32 expectedHash = known ? fees[index].configHash : bytes32(uint256(0xBAD2));
        if (!correctHash) expectedHash = bytes32(uint256(expectedHash) ^ 1);
        ReasonCode reason = validEvidence ? ReasonCode.GOVERNANCE_ACTION : ReasonCode.NONE;
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);

        if (selectedAction == 0) {
            bool expectedValid = known && epochIsSealed && epochs[epochIndex].status == FeePolicyEpochStatus.DRAFT
                && status == FeeVersionStatus.REGISTERED && correctHash;
            _prank(GOVERNANCE);
            try REGISTRY.activateFeeVersion(feeVersionId, expectedHash) {
                if (!expectedValid) {
                    ++unexpectedSuccesses;
                    return;
                }
                feeStatuses[index] = FeeVersionStatus.ACTIVE;
                _recordServingFee(epochIndex, fees[index]);
            } catch {
                if (expectedValid) ++unexpectedReverts;
            }
        } else if (selectedAction == 1) {
            bool expectedValid = known && epochIsSealed && status == FeeVersionStatus.ACTIVE && validEvidence;
            _prank(PAUSER);
            try REGISTRY.pauseFeeVersion(feeVersionId, reason, evidence) {
                _finishFeeTransition(expectedValid, index, FeeVersionStatus.PAUSED);
            } catch {
                if (expectedValid) ++unexpectedReverts;
            }
        } else if (selectedAction == 2) {
            bool expectedValid =
                known && epochIsSealed && status == FeeVersionStatus.PAUSED && correctHash && validEvidence;
            _prank(GOVERNANCE);
            try REGISTRY.unpauseFeeVersion(feeVersionId, expectedHash, reason, evidence) {
                _finishFeeTransition(expectedValid, index, FeeVersionStatus.ACTIVE);
            } catch {
                if (expectedValid) ++unexpectedReverts;
            }
        } else {
            // PAUSED 不再是 DEPRECATED 的入边：DEPRECATED 可结算而 PAUSED 不可，
            // 那条边等于把已停掉的费率重新放行且不可逆。
            bool expectedValid = known && epochIsSealed && status == FeeVersionStatus.ACTIVE && validEvidence;
            _prank(GOVERNANCE);
            try REGISTRY.deprecateFeeVersion(feeVersionId, reason, evidence) {
                _finishFeeTransition(expectedValid, index, FeeVersionStatus.DEPRECATED);
            } catch {
                if (expectedValid) ++unexpectedReverts;
            }
        }
    }

    function activateEpoch(uint256 seed, bool correctHash, bool advanceToWindow) external {
        (bool known, uint256 index, uint64 epochNumber) = _selectedEpoch(seed);
        if (known && advanceToWindow && block.timestamp < epochs[index].config.quoteValidFrom) {
            FeeVmAccess.vm().warp(epochs[index].config.quoteValidFrom);
        }
        bytes32 expectedHash = known ? epochs[index].config.configHash : bytes32(uint256(0xBAD3));
        if (!correctHash) expectedHash = bytes32(uint256(expectedHash) ^ 1);
        bool inWindow = known && block.timestamp >= epochs[index].config.quoteValidFrom
            && block.timestamp <= epochs[index].config.quoteValidUntil;
        bool expectedValid = known && epochs[index].isSealed && epochs[index].status == FeePolicyEpochStatus.DRAFT
            && correctHash && inWindow;

        _prank(GOVERNANCE);
        try REGISTRY.activateFeePolicyEpoch(epochNumber, expectedHash) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            for (uint256 i = 0; i < epochs.length; ++i) {
                if (epochs[i].status == FeePolicyEpochStatus.ACTIVE) {
                    epochs[i].status = FeePolicyEpochStatus.LEGACY_SERVING;
                }
            }
            epochs[index].status = FeePolicyEpochStatus.ACTIVE;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function moveEpochToLegacy(uint256 seed, bool validEvidence) external {
        (bool known, uint256 index, uint64 epochNumber) = _selectedEpoch(seed);
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && epochs[index].status == FeePolicyEpochStatus.ACTIVE && validEvidence
            && block.timestamp > epochs[index].config.quoteValidUntil;

        _prank(GOVERNANCE);
        try REGISTRY.moveFeePolicyEpochToLegacyServing(epochNumber, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            epochs[index].status = FeePolicyEpochStatus.LEGACY_SERVING;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function closeEpoch(uint256 seed, bool validEvidence) external {
        (bool known, uint256 index, uint64 epochNumber) = _selectedEpoch(seed);
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && epochs[index].status == FeePolicyEpochStatus.LEGACY_SERVING && validEvidence
            && block.timestamp > epochs[index].config.settlementValidUntil;

        _prank(GOVERNANCE);
        try REGISTRY.closeFeePolicyEpoch(epochNumber, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            epochs[index].status = FeePolicyEpochStatus.CLOSED;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function advanceTime(uint32 delta) external {
        FeeVmAccess.vm().warp(block.timestamp + uint256(delta % 7 days) + 1);
    }

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    function epochAt(uint256 index)
        external
        view
        returns (
            FeePolicyEpochConfig memory config,
            FeePolicyEpochStatus status,
            bool isSealed,
            bytes32 resolvedFeeVersionId,
            bytes32 resolvedScopeHash
        )
    {
        EpochShadow storage shadow = epochs[index];
        return (shadow.config, shadow.status, shadow.isSealed, shadow.resolvedFeeVersionId, shadow.resolvedScopeHash);
    }

    function feeCount() external view returns (uint256) {
        return fees.length;
    }

    function feeAt(uint256 index) external view returns (FeeConfig memory, FeeVersionStatus) {
        return (fees[index], feeStatuses[index]);
    }

    function assetVersionId() external view returns (bytes32) {
        return ASSET_VERSION_ID;
    }

    function _finishFeeTransition(bool expectedValid, uint256 index, FeeVersionStatus newStatus) private {
        if (!expectedValid) {
            ++unexpectedSuccesses;
            return;
        }
        feeStatuses[index] = newStatus;
    }

    function _recordFee(FeeConfig memory config, FeeVersionStatus status) private {
        fees.push(config);
        feeStatuses.push(status);
        feePositions[config.feeVersionId] = fees.length;
        latestByScope[config.feePolicyEpoch][uint8(config.scopeType)] = config.feeVersionId;
    }

    function _recordServingFee(uint256 epochIndex, FeeConfig memory config) private {
        EpochShadow storage shadow = epochs[epochIndex];
        if (uint8(config.scopeType) >= uint8(shadow.resolvedScopeType)) {
            shadow.resolvedFeeVersionId = config.feeVersionId;
            shadow.resolvedScopeHash = config.matchedScopeHash;
            shadow.resolvedScopeType = config.scopeType;
        }
    }

    function _selectedEpoch(uint256 seed) private view returns (bool known, uint256 index, uint64 epochNumber) {
        uint256 selected = seed % (epochs.length + 1);
        known = selected < epochs.length;
        index = known ? selected : 0;
        epochNumber = known ? epochs[index].config.feePolicyEpoch : 10_000;
    }

    function _selectedFee(uint256 seed) private view returns (bool known, uint256 index, bytes32 feeVersionId) {
        uint256 selected = seed % (fees.length + 1);
        known = selected < fees.length;
        index = known ? selected : 0;
        feeVersionId = known ? fees[index].feeVersionId : keccak256(abi.encode("unknown-fee", seed));
    }

    function _registrationPlan(uint256 epochSeed, uint8 scopeSeed, uint8 mode, uint16 buyerRate, uint16 sellerRate)
        private
        view
        returns (RegistrationPlan memory plan)
    {
        bool known;
        (known, plan.epochIndex, plan.epochNumber) = _selectedEpoch(epochSeed);
        plan.scopeType = ScopeType(uint8(scopeSeed % 5) + uint8(ScopeType.GLOBAL));
        FeePolicyEpochConfig memory epochConfig =
            known ? epochs[plan.epochIndex].config : _syntheticEpoch(plan.epochNumber);
        bytes32 latestId = latestByScope[plan.epochNumber][uint8(plan.scopeType)];
        uint32 revision = latestId == bytes32(0) ? 1 : fees[feePositions[latestId] - 1].revision + 1;
        // 费率空间保持完整以便探索超限路径，但模型必须知道：两档各自 ≤ 100%
        // 不代表组合合法，最坏可达聚合超过 MAX_AGGREGATE_FEE_BPS 的登记预期失败。
        // 最坏可达聚合是 2×较高的那一档，不是两档之和——(MAKER, MAKER) 成交时
        // 两腿共用 makerRateBps。
        uint16 boundedBuyerRate = uint16(uint256(buyerRate) % 10_001);
        uint16 boundedSellerRate = uint16(uint256(sellerRate) % 10_001);
        uint16 higherRate = boundedBuyerRate > boundedSellerRate ? boundedBuyerRate : boundedSellerRate;
        bool aggregateWithinCap = 2 * uint256(higherRate) <= FeeMath.MAX_AGGREGATE_FEE_BPS;
        plan.expectedValid =
            known && !epochs[plan.epochIndex].isSealed && mode % 4 == 0 && fees.length < MAX_FEES && aggregateWithinCap;

        bytes32 replacesId = latestId;
        if (mode % 4 == 1) {
            ++revision;
        } else if (mode % 4 == 2) {
            replacesId = bytes32(uint256(0xBADFEE));
        }
        plan.candidate = _newFee(
            epochConfig,
            plan.scopeType,
            _scopeKey(plan.scopeType),
            revision,
            replacesId,
            boundedBuyerRate,
            boundedSellerRate
        );
        if (mode % 4 == 3) plan.candidate.configHash = bytes32(uint256(plan.candidate.configHash) ^ 1);
        if (fees.length >= MAX_FEES && mode % 4 == 0) plan.candidate = fees[0];
    }

    function _newEpoch(uint64 epochNumber) private view returns (FeePolicyEpochConfig memory config) {
        config = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: epochNumber,
            chainId: block.chainid,
            quoteValidFrom: uint64(block.timestamp + 1 hours),
            quoteValidUntil: uint64(block.timestamp + 2 days),
            settlementValidUntil: uint64(block.timestamp + 4 days),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashFeePolicyEpochConfig(config);
    }

    function _syntheticEpoch(uint64 epochNumber) private view returns (FeePolicyEpochConfig memory config) {
        config = _newEpoch(epochNumber);
    }

    function _newFee(
        FeePolicyEpochConfig memory epoch,
        ScopeType scopeType,
        bytes32 scopeKeyHash,
        uint32 revision,
        bytes32 replacesId,
        uint16 buyerRate,
        uint16 sellerRate
    ) private view returns (FeeConfig memory config) {
        bytes32 matchedScopeHash = FeeScope.matchedHash(epoch.feePolicyEpoch, scopeType, scopeKeyHash);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, revision),
            revision: revision,
            chainId: block.chainid,
            feePolicyEpoch: epoch.feePolicyEpoch,
            scopeType: scopeType,
            scopeKeyHash: scopeKeyHash,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: buyerRate,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: sellerRate,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: SETTLEMENT_TOKEN,
            settlementTokenConfigId: SETTLEMENT_TOKEN_CONFIG_ID,
            settlementTokenConfigHash: SETTLEMENT_TOKEN_CONFIG_HASH,
            collector: address(0xC011),
            validFrom: epoch.quoteValidFrom,
            validUntil: epoch.settlementValidUntil,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: replacesId,
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
    }

    function _scopeKey(ScopeType scopeType) private view returns (bytes32) {
        if (scopeType == ScopeType.GLOBAL) return bytes32(0);
        if (scopeType == ScopeType.CHAIN) return bytes32(block.chainid);
        if (scopeType == ScopeType.ASSET_CLASS) return bytes32(uint256(ASSET_CLASS));
        if (scopeType == ScopeType.INSTRUMENT) return ECONOMIC_ASSET_ID_HASH;
        return ASSET_VERSION_ID;
    }

    function _prank(address actor) private {
        FeeVmAccess.vm().prank(actor);
    }
}

library FeeVmAccess {
    function vm() internal pure returns (FeeVmLike) {
        return FeeVmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}

interface FeeVmLike {
    function prank(address) external;
    function warp(uint256) external;
}

contract FeeRegistryStateMachineInvariantTest is FeeRegistryTestBase {
    FeeRegistryStateMachineHandler private handler;

    function setUp() public override {
        super.setUp();
        FeePolicyEpochConfig memory epoch = _createEpoch(1);
        FeeConfig memory fee = _feeConfig(1, ScopeType.GLOBAL, bytes32(0), 1, bytes32(0));
        _registerFee(fee);
        _sealEpoch(epoch);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(fee.feeVersionId, fee.configHash);
        _activateEpoch(epoch);

        FeeInvariantContext memory context = FeeInvariantContext({
            registry: feeRegistry,
            configurer: CONFIGURER,
            pauser: PAUSER,
            governance: address(timelock),
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            assetVersionId: assetVersionConfig.assetVersionId,
            economicAssetIdHash: ECONOMIC_ASSET_ID_HASH,
            assetClass: assetVersionConfig.assetClass
        });
        handler = new FeeRegistryStateMachineHandler(context, epoch, fee);
        targetContract(address(handler));
    }

    function invariantEpochsAreImmutableSealedAndAtMostOneIsActive() public view {
        uint256 activeCount;
        uint256 count = handler.epochCount();
        for (uint256 i = 0; i < count; ++i) {
            (FeePolicyEpochConfig memory expected, FeePolicyEpochStatus expectedStatus, bool expectedSealed,,) =
                handler.epochAt(i);
            FeePolicyEpochRecord memory actual = feeRegistry.getFeePolicyEpoch(expected.feePolicyEpoch);
            assertTrue(actual.exists);
            assertEq(actual.config.configHash, expected.configHash);
            assertEq(actual.config.quoteValidFrom, expected.quoteValidFrom);
            assertEq(actual.config.quoteValidUntil, expected.quoteValidUntil);
            assertEq(actual.config.settlementValidUntil, expected.settlementValidUntil);
            assertEq(actual.isSealed, expectedSealed);
            assertEq(uint8(actual.status), uint8(expectedStatus));
            if (actual.status == FeePolicyEpochStatus.ACTIVE) ++activeCount;
        }
        assertLe(activeCount, 1);
    }

    function invariantFeeHistoryAndRuntimeStatusesMatchModel() public view {
        uint256 count = handler.feeCount();
        for (uint256 i = 0; i < count; ++i) {
            (FeeConfig memory expected, FeeVersionStatus expectedStatus) = handler.feeAt(i);
            FeeVersionRecord memory actual = feeRegistry.getFeeVersion(expected.feeVersionId);
            assertTrue(actual.exists);
            assertEq(actual.config.configHash, expected.configHash);
            assertEq(actual.config.feeConstraintHash, expected.feeConstraintHash);
            assertEq(actual.config.matchedScopeHash, expected.matchedScopeHash);
            assertEq(actual.config.revision, expected.revision);
            assertEq(actual.config.replacesFeeVersionId, expected.replacesFeeVersionId);
            assertEq(uint8(actual.status), uint8(expectedStatus));
        }
    }

    function invariantResolverFollowsActivatedServingPointersAndEpochServiceability() public view {
        uint256 count = handler.epochCount();
        for (uint256 i = 0; i < count; ++i) {
            (
                FeePolicyEpochConfig memory epoch,
                FeePolicyEpochStatus status,,
                bytes32 expectedFeeVersionId,
                bytes32 expectedScopeHash
            ) = handler.epochAt(i);
            bool serviceable = status == FeePolicyEpochStatus.ACTIVE || status == FeePolicyEpochStatus.LEGACY_SERVING;
            bool reverted;
            bytes32 resolvedFeeVersionId;
            bytes32 resolvedScopeHash;
            try feeRegistry.resolveApplicableFee(epoch.feePolicyEpoch, handler.assetVersionId()) returns (
                bytes32 feeVersionId, bytes32 matchedScopeHash
            ) {
                resolvedFeeVersionId = feeVersionId;
                resolvedScopeHash = matchedScopeHash;
            } catch {
                reverted = true;
            }

            if (serviceable && expectedFeeVersionId != bytes32(0)) {
                assertFalse(reverted);
                assertEq(resolvedFeeVersionId, expectedFeeVersionId);
                assertEq(resolvedScopeHash, expectedScopeHash);
            } else {
                assertTrue(reverted);
            }
        }
    }

    function invariantIllegalEpochAndFeeEdgesNeverSucceed() public view {
        assertEq(handler.unexpectedSuccesses(), 0);
        assertEq(handler.unexpectedReverts(), 0);
    }
}
