// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {DirectOperation} from "script/DeployTypes.sol";
import {MigrateDvP} from "script/MigrateDvP.s.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {DvPRegistries, DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IFeeRegistry} from "src/interfaces/IFeeRegistry.sol";
import {IMarketRuleRegistry} from "src/interfaces/IMarketRuleRegistry.sol";
import {ISettlementTokenRegistry} from "src/interfaces/ISettlementTokenRegistry.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    AdapterConfig,
    AssetVersionConfig,
    Decision,
    EligibilityInput,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    ReasonCode,
    ScopeType,
    SettlementParams,
    SettlementTokenConfig
} from "src/types/HTPTypes.sol";
import {DvPCurrentStateValidatorFactory} from "src/validation/DvPCurrentStateValidatorFactory.sol";
import {DeployFixture} from "test/helpers/DeployFixture.sol";

contract DvPMigrationRunbookTest is DeployFixture {
    bytes private constant NEW_DEPLOYMENT_VERSION = bytes("2.0.0");

    MigrateDvP private runbook;
    DvPSettlement private newDvp;
    MarketRuleConfig private migrationMarketRuleConfig;

    function setUp() public override {
        super.setUp();
        runbook = new MigrateDvP();
        newDvp = new DvPSettlement(
            DvPRoles({
                defaultAdmin: address(timelock), governance: address(timelock), pauser: DVP_PAUSER, executor: EXECUTOR
            }),
            DvPRegistries({
                participant: address(participantRegistry),
                assetVersion: address(assetVersionRegistry),
                eligibility: address(eligibilityRegistry),
                fee: address(feeRegistry),
                marketRule: address(marketRuleRegistry),
                settlementToken: address(settlementTokenRegistry),
                adapter: address(adapterRegistry),
                principalCalculator: address(calculatorRegistry)
            }),
            block.chainid,
            NEW_DEPLOYMENT_VERSION,
            address(new DvPCurrentStateValidatorFactory())
        );

        vm.startPrank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        newDvp.pauseGlobal(ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.stopPrank();
    }

    function testStrictMigrationOrderRejectsDoubleConsumerUnpauseAndOldDomainSignatures() public {
        (AdapterConfig memory nextAdapterConfig, SettlementTokenConfig memory nextSettlementConfig) =
            _prepareNewDvpBoundConfigs();
        AssetVersionConfig memory nextConfig = _nextAssetVersion(nextAdapterConfig, nextSettlementConfig);
        bytes32[] memory oldAssetVersionIds = new bytes32[](1);
        oldAssetVersionIds[0] = assetVersionConfig.assetVersionId;
        bytes32 incorrectAssetVersionId = keccak256("incorrect-asset-version");
        bytes32[] memory emptyOldAssetVersionIds = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateDvP.MigrationOrderViolation.selector, bytes32("OLD_ASSET_LIST_EMPTY"), address(dvp)
            )
        );
        runbook.buildPauseOldAssetVersions(
            address(dvp), address(assetVersionRegistry), emptyOldAssetVersionIds, EVIDENCE_HASH
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateDvP.MigrationOrderViolation.selector,
                bytes32("NEW_DVP_NOT_REGISTERED"),
                address(eligibilityRegistry)
            )
        );
        runbook.buildRegisterNewAssetVersion(
            address(dvp), address(newDvp), address(eligibilityRegistry), address(assetVersionRegistry), nextConfig
        );

        _execute(
            runbook.buildAuthorizeNewDvp(
                address(dvp),
                address(newDvp),
                address(eligibilityRegistry),
                _registries(),
                newDvp.deploymentVersionHash(),
                EVIDENCE_HASH
            )
        );

        DirectOperation memory registration = runbook.buildRegisterNewAssetVersion(
            address(dvp), address(newDvp), address(eligibilityRegistry), address(assetVersionRegistry), nextConfig
        );
        vm.prank(CONFIGURER);
        (bool registered,) = registration.target.call(registration.data);
        assertTrue(registered);
        runbook.verifyNewConsumerAuthorization(address(eligibilityRegistry), address(newDvp), nextConfig.assetVersionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateDvP.MigrationOrderViolation.selector,
                bytes32("OLD_ASSET_NOT_DEPRECATED"),
                address(assetVersionRegistry)
            )
        );
        runbook.buildUnpauseNewDvp(
            address(dvp),
            address(newDvp),
            address(eligibilityRegistry),
            address(assetVersionRegistry),
            oldAssetVersionIds,
            nextConfig.assetVersionId,
            incorrectAssetVersionId,
            EVIDENCE_HASH
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateDvP.MigrationOrderViolation.selector, bytes32("NEW_DVP_NOT_LIVE"), address(newDvp)
            )
        );
        runbook.buildRetireOldDvp(address(dvp), address(newDvp), address(eligibilityRegistry), EVIDENCE_HASH);

        DirectOperation[] memory pauseOperations = runbook.buildPauseOldAssetVersions(
            address(dvp), address(assetVersionRegistry), oldAssetVersionIds, EVIDENCE_HASH
        );
        for (uint256 i = 0; i < pauseOperations.length; ++i) {
            vm.prank(REGISTRY_PAUSER);
            (bool paused,) = pauseOperations[i].target.call(pauseOperations[i].data);
            assertTrue(paused);
        }

        _execute(
            runbook.buildActivateDeprecateAndRevokeOldConsumer(
                address(dvp),
                address(newDvp),
                address(eligibilityRegistry),
                address(assetVersionRegistry),
                oldAssetVersionIds,
                nextConfig.assetVersionId,
                nextConfig.configHash,
                EVIDENCE_HASH
            )
        );
        runbook.verifyConsumerCutover(
            address(dvp),
            address(newDvp),
            address(eligibilityRegistry),
            address(assetVersionRegistry),
            oldAssetVersionIds,
            nextConfig.assetVersionId,
            incorrectAssetVersionId
        );
        FeeConfig memory nextFeeConfig = _completeNewDvpGraph(nextConfig, nextSettlementConfig);

        vm.expectRevert(
            abi.encodeWithSelector(
                MigrateDvP.MigrationOrderViolation.selector, bytes32("EVIDENCE_REQUIRED"), address(newDvp)
            )
        );
        runbook.buildUnpauseNewDvp(
            address(dvp),
            address(newDvp),
            address(eligibilityRegistry),
            address(assetVersionRegistry),
            oldAssetVersionIds,
            nextConfig.assetVersionId,
            incorrectAssetVersionId,
            bytes32(0)
        );
        _execute(
            runbook.buildUnpauseNewDvp(
                address(dvp),
                address(newDvp),
                address(eligibilityRegistry),
                address(assetVersionRegistry),
                oldAssetVersionIds,
                nextConfig.assetVersionId,
                incorrectAssetVersionId,
                EVIDENCE_HASH
            )
        );

        SettlementParams memory oldDomainParams = _validPreCheckParams();
        assertNotEq(dvp.domainSeparatorV4(), newDvp.domainSeparatorV4());
        (Decision decision,) = newDvp.preCheck(oldDomainParams);
        assertEq(uint8(decision), uint8(Decision.BLOCK), "old-domain signatures must not migrate");

        SettlementParams memory newDomainParams = _newDomainParams(nextConfig, nextSettlementConfig, nextFeeConfig);
        (Decision newDecision, bytes4 newReason) = newDvp.preCheck(newDomainParams);
        assertEq(uint8(newDecision), uint8(Decision.PASS), "new DvP graph must be settlement-ready");
        assertEq(newReason, bytes4(0));
        vm.prank(EXECUTOR);
        newDvp.settle(newDomainParams);
        assertTrue(newDvp.usedTradeIdHash(newDomainParams.tradeIntent.tradeIdHash));

        _execute(runbook.buildRetireOldDvp(address(dvp), address(newDvp), address(eligibilityRegistry), EVIDENCE_HASH));
        assertTrue(dvp.globalPaused());
        assertTrue(dvp.retired());
        assertFalse(newDvp.globalPaused());
        assertFalse(newDvp.retired());
    }

    function _prepareNewDvpBoundConfigs()
        private
        returns (AdapterConfig memory nextAdapterConfig, SettlementTokenConfig memory nextSettlementConfig)
    {
        IAssetAdapter nextAdapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(newDvp))));
        nextAdapterConfig = adapterConfig;
        nextAdapterConfig.revision = adapterConfig.revision + 1;
        nextAdapterConfig.adapter = address(nextAdapter);
        nextAdapterConfig.codeHash = address(nextAdapter).codehash;
        nextAdapterConfig.providerHash = nextAdapter.providerHash();
        nextAdapterConfig.replacesId = adapterConfig.adapterConfigId;
        nextAdapterConfig.adapterConfigId = ConfigId.derive(
            ConfigId.ADAPTER_NAMESPACE,
            nextAdapterConfig.schemaVersion,
            block.chainid,
            nextAdapterConfig.capabilityHash,
            nextAdapterConfig.revision
        );
        nextAdapterConfig.configHash = bytes32(0);
        nextAdapterConfig.configHash = HTPHashing.hashAdapterConfig(nextAdapterConfig);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(nextAdapterConfig);
        _execute(
            _single(
                address(adapterRegistry),
                abi.encodeCall(
                    IAdapterRegistry.activateAdapter, (nextAdapterConfig.adapterConfigId, nextAdapterConfig.configHash)
                ),
                keccak256("activate-new-dvp-adapter")
            )
        );

        nextSettlementConfig = settlementTokenConfig;
        nextSettlementConfig.revision = settlementTokenConfig.revision + 1;
        nextSettlementConfig.adapterConfigId = nextAdapterConfig.adapterConfigId;
        nextSettlementConfig.adapterConfigHash = nextAdapterConfig.configHash;
        nextSettlementConfig.replacesConfigId = settlementTokenConfig.configId;
        nextSettlementConfig.configId = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            nextSettlementConfig.schemaVersion,
            block.chainid,
            bytes32(uint256(uint160(nextSettlementConfig.settlementToken))),
            nextSettlementConfig.revision
        );
        nextSettlementConfig.configHash = bytes32(0);
        nextSettlementConfig.configHash = HTPHashing.hashSettlementTokenConfig(nextSettlementConfig);
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(nextSettlementConfig);
        _execute(
            _single(
                address(settlementTokenRegistry),
                abi.encodeCall(
                    ISettlementTokenRegistry.activateSettlementToken,
                    (nextSettlementConfig.configId, nextSettlementConfig.configHash)
                ),
                keccak256("activate-new-settlement-config")
            )
        );
    }

    function _nextAssetVersion(
        AdapterConfig memory nextAdapterConfig,
        SettlementTokenConfig memory nextSettlementConfig
    ) private view returns (AssetVersionConfig memory config) {
        config = assetVersionConfig;
        config.versionNo = assetVersionConfig.versionNo + 1;
        config.replacesAssetVersionId = assetVersionConfig.assetVersionId;
        config.dvpContract = address(newDvp);
        config.deploymentVersionHash = newDvp.deploymentVersionHash();
        config.adapterConfigId = nextAdapterConfig.adapterConfigId;
        config.adapterConfigHash = nextAdapterConfig.configHash;
        config.settlementTokenConfigId = nextSettlementConfig.configId;
        config.settlementTokenConfigHash = nextSettlementConfig.configHash;
        config.assetVersionId = ConfigId.assetVersion(
            config.schemaVersion, config.economicAssetIdHash, block.chainid, config.assetToken, config.versionNo
        );
        config.configHash = bytes32(0);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }

    function _completeNewDvpGraph(
        AssetVersionConfig memory nextAssetConfig,
        SettlementTokenConfig memory nextSettlementConfig
    ) private returns (FeeConfig memory nextFeeConfig) {
        uint64 validFrom = uint64(block.timestamp);
        FeePolicyEpochConfig memory nextEpoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: FEE_EPOCH + 1,
            chainId: block.chainid,
            quoteValidFrom: validFrom,
            quoteValidUntil: validFrom + 30 days,
            settlementValidUntil: validFrom + 60 days,
            configHash: bytes32(0)
        });
        nextEpoch.configHash = HTPHashing.hashFeePolicyEpochConfig(nextEpoch);
        _execute(
            _single(
                address(feeRegistry),
                abi.encodeCall(IFeeRegistry.createFeePolicyEpoch, (nextEpoch)),
                keccak256("create-migration-fee-epoch")
            )
        );

        nextFeeConfig = feeConfig;
        nextFeeConfig.feePolicyEpoch = nextEpoch.feePolicyEpoch;
        nextFeeConfig.scopeKeyHash = nextAssetConfig.assetVersionId;
        nextFeeConfig.matchedScopeHash =
            FeeScope.matchedHash(nextEpoch.feePolicyEpoch, ScopeType.ASSET_VERSION, nextAssetConfig.assetVersionId);
        nextFeeConfig.feeVersionId = ConfigId.derive(
            ConfigId.FEE_NAMESPACE, nextFeeConfig.schemaVersion, block.chainid, nextFeeConfig.matchedScopeHash, 1
        );
        nextFeeConfig.revision = 1;
        nextFeeConfig.settlementTokenConfigId = nextSettlementConfig.configId;
        nextFeeConfig.settlementTokenConfigHash = nextSettlementConfig.configHash;
        nextFeeConfig.validFrom = nextEpoch.quoteValidFrom;
        nextFeeConfig.validUntil = nextEpoch.settlementValidUntil;
        nextFeeConfig.replacesFeeVersionId = bytes32(0);
        nextFeeConfig.feeConstraintHash = bytes32(0);
        nextFeeConfig.feeConstraintHash = HTPHashing.hashFeeConstraint(nextFeeConfig);
        nextFeeConfig.configHash = bytes32(0);
        nextFeeConfig.configHash = HTPHashing.hashFeeConfig(nextFeeConfig);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(nextFeeConfig);

        migrationMarketRuleConfig = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, nextAssetConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: nextAssetConfig.assetVersionId,
            settlementToken: nextSettlementConfig.settlementToken,
            settlementTokenConfigId: nextSettlementConfig.configId,
            settlementTokenConfigHash: nextSettlementConfig.configHash,
            minCashPrincipal: 1,
            minExecutableQuantity: 1,
            quantityStep: 1,
            priceTick: 1,
            priceDecimals: nextSettlementConfig.settlementTokenDecimals,
            quantityDecimals: nextAssetConfig.assetDecimals,
            quoteValidFrom: nextEpoch.quoteValidFrom,
            quoteValidUntil: nextEpoch.quoteValidUntil,
            settlementValidUntil: nextEpoch.settlementValidUntil,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        migrationMarketRuleConfig.configHash = HTPHashing.hashMarketRuleConfig(migrationMarketRuleConfig);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(migrationMarketRuleConfig);

        address[] memory feeTargets = new address[](3);
        bytes[] memory feePayloads = new bytes[](3);
        feeTargets[0] = address(feeRegistry);
        feePayloads[0] =
            abi.encodeCall(IFeeRegistry.sealFeePolicyEpoch, (nextEpoch.feePolicyEpoch, nextEpoch.configHash));
        feeTargets[1] = address(feeRegistry);
        feePayloads[1] =
            abi.encodeCall(IFeeRegistry.activateFeeVersion, (nextFeeConfig.feeVersionId, nextFeeConfig.configHash));
        feeTargets[2] = address(feeRegistry);
        feePayloads[2] =
            abi.encodeCall(IFeeRegistry.activateFeePolicyEpoch, (nextEpoch.feePolicyEpoch, nextEpoch.configHash));
        _execute(_batch(feeTargets, feePayloads, keccak256("finalize-migration-fees")));
        address[] memory marketRuleTargets = new address[](2);
        bytes[] memory marketRulePayloads = new bytes[](2);
        marketRuleTargets[0] = address(marketRuleRegistry);
        marketRulePayloads[0] = abi.encodeCall(
            IMarketRuleRegistry.sealMarketRule,
            (migrationMarketRuleConfig.marketRuleConfigId, migrationMarketRuleConfig.configHash)
        );
        marketRuleTargets[1] = address(marketRuleRegistry);
        marketRulePayloads[1] = abi.encodeCall(
            IMarketRuleRegistry.activateMarketRule,
            (migrationMarketRuleConfig.marketRuleConfigId, migrationMarketRuleConfig.configHash)
        );
        _execute(_batch(marketRuleTargets, marketRulePayloads, keccak256("finalize-migration-market-rule")));

        _setNewEligibility(vm.addr(MAKER_KEY), nextAssetConfig.assetVersionId, validFrom);
        _setNewEligibility(vm.addr(REQUESTER_KEY), nextAssetConfig.assetVersionId, validFrom);

        assetToken.setAllowance(vm.addr(MAKER_KEY), address(newDvp), 10 ether);
        settlementToken.setAllowance(vm.addr(REQUESTER_KEY), address(newDvp), 11_428_500);
    }

    function _setNewEligibility(address wallet, bytes32 assetVersionId, uint64 validFrom) private {
        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: wallet,
                assetVersionId: assetVersionId,
                decision: Decision.PASS,
                validFrom: validFrom,
                validUntil: validFrom + 60 days,
                kycDecisionVersion: keccak256("migration-kyc"),
                permissionVersion: keccak256("migration-permission"),
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _newDomainParams(
        AssetVersionConfig memory nextAssetConfig,
        SettlementTokenConfig memory nextSettlementConfig,
        FeeConfig memory nextFeeConfig
    ) private view returns (SettlementParams memory params) {
        params = _validPreCheckParams();
        uint64 createdAt = uint64(block.timestamp);
        // 单笔成交的窗口受 ProtocolSecurityLimits.MAX_QUOTE_LIFETIME 约束，
        // 与迁移编排本身的时间尺度无关：这里只需要一份能结算的报价。
        uint64 tradeDeadline = createdAt + 30 minutes;
        uint64 quoteExpiresAt = createdAt + 45 minutes;
        params.firmQuote.assetVersionId = nextAssetConfig.assetVersionId;
        params.firmQuote.adapterConfigId = nextAssetConfig.adapterConfigId;
        params.firmQuote.adapterConfigHash = nextAssetConfig.adapterConfigHash;
        params.firmQuote.settlementTokenConfigId = nextSettlementConfig.configId;
        params.firmQuote.settlementTokenConfigHash = nextSettlementConfig.configHash;
        params.firmQuote.marketRuleConfigId = migrationMarketRuleConfig.marketRuleConfigId;
        params.firmQuote.marketRuleConfigHash = migrationMarketRuleConfig.configHash;
        params.firmQuote.feePolicyEpoch = nextFeeConfig.feePolicyEpoch;
        params.firmQuote.feeVersionId = nextFeeConfig.feeVersionId;
        params.firmQuote.matchedScopeHash = nextFeeConfig.matchedScopeHash;
        params.firmQuote.feeConstraintHash = nextFeeConfig.feeConstraintHash;
        params.firmQuote.expiresAt = quoteExpiresAt;

        params.snapshot.dvpContract = address(newDvp);
        params.snapshot.assetVersionId = nextAssetConfig.assetVersionId;
        params.snapshot.adapterConfigId = nextAssetConfig.adapterConfigId;
        params.snapshot.adapterConfigHash = nextAssetConfig.adapterConfigHash;
        params.snapshot.settlementTokenConfigId = nextSettlementConfig.configId;
        params.snapshot.settlementTokenConfigHash = nextSettlementConfig.configHash;
        params.snapshot.marketRuleConfigId = migrationMarketRuleConfig.marketRuleConfigId;
        params.snapshot.marketRuleConfigHash = migrationMarketRuleConfig.configHash;
        params.snapshot.feePolicyEpoch = nextFeeConfig.feePolicyEpoch;
        params.snapshot.feeVersionId = nextFeeConfig.feeVersionId;
        params.snapshot.matchedScopeHash = nextFeeConfig.matchedScopeHash;
        params.snapshot.feeConstraintHash = nextFeeConfig.feeConstraintHash;
        params.snapshot.createdAt = createdAt;
        params.snapshot.tradeDeadline = tradeDeadline;
        params.snapshot.quoteExpiresAt = quoteExpiresAt;

        params.tradeIntent.assetVersionId = nextAssetConfig.assetVersionId;
        params.tradeIntent.adapterConfigId = nextAssetConfig.adapterConfigId;
        params.tradeIntent.adapterConfigHash = nextAssetConfig.adapterConfigHash;
        params.tradeIntent.settlementTokenConfigId = nextSettlementConfig.configId;
        params.tradeIntent.settlementTokenConfigHash = nextSettlementConfig.configHash;
        params.tradeIntent.marketRuleConfigId = migrationMarketRuleConfig.marketRuleConfigId;
        params.tradeIntent.marketRuleConfigHash = migrationMarketRuleConfig.configHash;
        params.tradeIntent.feePolicyEpoch = nextFeeConfig.feePolicyEpoch;
        params.tradeIntent.feeVersionId = nextFeeConfig.feeVersionId;
        params.tradeIntent.matchedScopeHash = nextFeeConfig.matchedScopeHash;
        params.tradeIntent.feeConstraintHash = nextFeeConfig.feeConstraintHash;
        params.tradeIntent.deadline = tradeDeadline;

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(newDvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.snapshotHash = snapshotHash;
        params.quotingMakerSignature = _signature(MAKER_KEY, quoteDigest);
        params.requesterSignature =
            _signature(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(newDvp.domainSeparatorV4(), params.tradeIntent));
    }

    function _signature(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _single(address target, bytes memory payload, bytes32 salt)
        private
        pure
        returns (DirectOperation[] memory operations)
    {
        salt;
        operations = new DirectOperation[](1);
        operations[0] = DirectOperation({target: target, data: payload});
    }

    function _batch(address[] memory targets, bytes[] memory payloads, bytes32 salt)
        private
        pure
        returns (DirectOperation[] memory operations)
    {
        salt;
        operations = new DirectOperation[](targets.length);
        for (uint256 i = 0; i < targets.length; ++i) {
            operations[i] = DirectOperation({target: targets[i], data: payloads[i]});
        }
    }

    function _registries() private view returns (address[] memory registries) {
        registries = new address[](8);
        registries[0] = address(participantRegistry);
        registries[1] = address(assetVersionRegistry);
        registries[2] = address(eligibilityRegistry);
        registries[3] = address(feeRegistry);
        registries[4] = address(settlementTokenRegistry);
        registries[5] = address(adapterRegistry);
        registries[6] = address(calculatorRegistry);
        registries[7] = address(marketRuleRegistry);
    }

    function _execute(DirectOperation[] memory operations) private {
        for (uint256 i = 0; i < operations.length; ++i) {
            _execute(operations[i]);
        }
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
}
