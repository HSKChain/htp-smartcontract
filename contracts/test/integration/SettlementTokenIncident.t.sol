// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    PermitCapability,
    ReasonCode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    SettlementTokenConfig,
    SettlementTokenStatus,
    TokenDeploymentKind
} from "src/types/HTPTypes.sol";
import {IntegrationUpgradeableUsdyToken, IntegrationUpgradeableUsdyTokenV2} from "test/fixtures/IntegrationTokens.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract SettlementTokenIncidentTest is UsdySettlementFixture {
    uint64 private constant RECOVERY_EPOCH = 3;
    uint64 private constant RECOVERY_CREATED_AT = USDY_CREATED_AT + 1;

    function testSettlementProxyImplementationDriftRequiresMonitorAndNewConfig() public {
        IntegrationUpgradeableUsdyToken implementation = new IntegrationUpgradeableUsdyToken();
        IntegrationUpgradeableUsdyToken proxyToken = IntegrationUpgradeableUsdyToken(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        IntegrationUpgradeableUsdyToken.initialize, (address(0xB10C), address(0xA110), address(0x5A11))
                    )
                )
            )
        );
        SettlementTokenConfig memory initialConfig =
            _settlementProxyConfig(proxyToken, address(implementation), 1, bytes32(0));
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(initialConfig);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(initialConfig.configId, initialConfig.configHash);

        bytes32 approvedProxyCodeHash = address(proxyToken).codehash;
        IntegrationUpgradeableUsdyTokenV2 nextImplementation = new IntegrationUpgradeableUsdyTokenV2();
        proxyToken.upgradeImplementation(address(nextImplementation));

        assertEq(address(proxyToken).codehash, approvedProxyCodeHash);
        assertEq(proxyToken.implementationAddress(), address(nextImplementation));
        assertTrue(
            settlementTokenRegistry.isSettlementTokenConfigActive(initialConfig.configId, initialConfig.configHash)
        );

        vm.prank(REGISTRY_PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            initialConfig.configId, ReasonCode.IMPLEMENTATION_CHANGED, EVIDENCE_HASH
        );
        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        SettlementTokenConfig memory replacementConfig =
            _settlementProxyConfig(proxyToken, address(nextImplementation), 2, initialConfig.configId);
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(replacementConfig);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(replacementConfig.configId, replacementConfig.configHash);

        assertEq(
            uint8(settlementTokenRegistry.getSettlementToken(initialConfig.configId).status),
            uint8(SettlementTokenStatus.PAUSED)
        );
        assertEq(
            uint8(settlementTokenRegistry.getSettlementToken(replacementConfig.configId).status),
            uint8(SettlementTokenStatus.ACTIVE)
        );
        assertTrue(dvp.globalPaused());
    }

    function testSettlementTokenDriftPauseAndNewConfigurationRestoreSettlement() public {
        SettlementParams memory oldParams = _validUsdyBuyParams();
        bytes memory approvedRuntime = address(settlementToken).code;
        vm.etch(address(settlementToken), hex"00");
        vm.expectPartialRevert(HTPErrors.TokenCodeHashMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(oldParams);
        vm.etch(address(settlementToken), approvedRuntime);

        vm.prank(REGISTRY_PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            settlementTokenConfig.configId, ReasonCode.IMPLEMENTATION_CHANGED, EVIDENCE_HASH
        );
        vm.prank(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        vm.expectRevert(HTPErrors.ContractPaused.selector);
        vm.prank(EXECUTOR);
        dvp.settle(oldParams);

        SettlementTokenConfig memory replacementTokenConfig = _registerReplacementSettlementToken();
        AssetVersionConfig memory replacementAssetConfig = _registerReplacementAsset(replacementTokenConfig);
        FeeConfig memory replacementFeeConfig =
            _activateRecoveryFee(replacementAssetConfig.assetVersionId, replacementTokenConfig);
        MarketRuleConfig memory replacementMarketRule =
            _activateRecoveryMarketRule(replacementAssetConfig, replacementTokenConfig);
        _setEligibilityForAsset(replacementAssetConfig.assetVersionId, oldParams.snapshot.seller);
        _setEligibilityForAsset(replacementAssetConfig.assetVersionId, oldParams.snapshot.buyer);

        SettlementParams memory recoveryParams = _validUsdyBuyParams();
        _bindConfiguration(recoveryParams, replacementAssetConfig, usdyAdapterConfig, replacementFeeConfig);
        _bindSettlementToken(recoveryParams, replacementTokenConfig);
        _bindMarketRule(recoveryParams, replacementMarketRule);
        recoveryParams.snapshot.createdAt = RECOVERY_CREATED_AT;
        _resign(recoveryParams);

        vm.prank(address(timelock));
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        _settleUsdy(recoveryParams);

        assertTrue(dvp.usedQuoteHash(recoveryParams.tradeIntent.quoteHash));
        assertEq(
            uint8(settlementTokenRegistry.getSettlementToken(settlementTokenConfig.configId).status),
            uint8(SettlementTokenStatus.PAUSED)
        );
        assertEq(
            uint8(settlementTokenRegistry.getSettlementToken(replacementTokenConfig.configId).status),
            uint8(SettlementTokenStatus.ACTIVE)
        );
    }

    function _registerReplacementSettlementToken() private returns (SettlementTokenConfig memory replacement) {
        replacement = settlementTokenConfig;
        replacement.revision = 2;
        replacement.configId = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            1,
            block.chainid,
            bytes32(uint256(uint160(address(settlementToken)))),
            2
        );
        replacement.replacesConfigId = settlementTokenConfig.configId;
        replacement.configHash = bytes32(0);
        replacement.configHash = HTPHashing.hashSettlementTokenConfig(replacement);
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(replacement);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(replacement.configId, replacement.configHash);
    }

    function _registerReplacementAsset(SettlementTokenConfig memory replacementTokenConfig)
        private
        returns (AssetVersionConfig memory replacement)
    {
        replacement = usdyAssetVersionConfig;
        replacement.versionNo = 2;
        replacement.assetVersionId =
            ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 2);
        replacement.settlementTokenConfigId = replacementTokenConfig.configId;
        replacement.settlementTokenConfigHash = replacementTokenConfig.configHash;
        replacement.replacesAssetVersionId = usdyAssetVersionConfig.assetVersionId;
        replacement.configHash = bytes32(0);
        replacement.configHash = HTPHashing.hashAssetVersionConfig(replacement);
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(replacement);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(replacement.assetVersionId, replacement.configHash);
    }

    function _activateRecoveryFee(bytes32 assetVersionId, SettlementTokenConfig memory replacementTokenConfig)
        private
        returns (FeeConfig memory config)
    {
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: RECOVERY_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: RECOVERY_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash = FeeScope.matchedHash(RECOVERY_EPOCH, ScopeType.ASSET_VERSION, assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: RECOVERY_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: replacementTokenConfig.configId,
            settlementTokenConfigHash: replacementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: RECOVERY_CREATED_AT,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(config);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(RECOVERY_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(RECOVERY_CREATED_AT);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(RECOVERY_EPOCH, epoch.configHash);
    }

    function _bindSettlementToken(SettlementParams memory params, SettlementTokenConfig memory config) private pure {
        params.firmQuote.settlementTokenConfigId = config.configId;
        params.firmQuote.settlementTokenConfigHash = config.configHash;
        params.tradeIntent.settlementTokenConfigId = config.configId;
        params.tradeIntent.settlementTokenConfigHash = config.configHash;
        params.snapshot.settlementTokenConfigId = config.configId;
        params.snapshot.settlementTokenConfigHash = config.configHash;
    }

    function _activateRecoveryMarketRule(
        AssetVersionConfig memory assetConfig,
        SettlementTokenConfig memory tokenConfig
    ) private returns (MarketRuleConfig memory config) {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, assetConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: assetConfig.assetVersionId,
            settlementToken: tokenConfig.settlementToken,
            settlementTokenConfigId: tokenConfig.configId,
            settlementTokenConfigHash: tokenConfig.configHash,
            minCashPrincipal: 1,
            minExecutableQuantity: 1,
            quantityStep: 1,
            priceTick: 1,
            priceDecimals: tokenConfig.settlementTokenDecimals,
            quantityDecimals: assetConfig.assetDecimals,
            quoteValidFrom: RECOVERY_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashMarketRuleConfig(config);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(config);
        vm.startPrank(address(timelock));
        marketRuleRegistry.sealMarketRule(config.marketRuleConfigId, config.configHash);
        marketRuleRegistry.activateMarketRule(config.marketRuleConfigId, config.configHash);
        vm.stopPrank();
    }

    function _settlementProxyConfig(
        IntegrationUpgradeableUsdyToken proxyToken,
        address implementation,
        uint32 revision,
        bytes32 replacesConfigId
    ) private view returns (SettlementTokenConfig memory config) {
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
                1,
                block.chainid,
                bytes32(uint256(uint160(address(proxyToken)))),
                revision
            ),
            revision: revision,
            chainId: block.chainid,
            settlementToken: address(proxyToken),
            tokenDeploymentKind: TokenDeploymentKind.ERC1967_PROXY,
            settlementTokenDecimals: 18,
            tokenCodeHash: address(proxyToken).codehash,
            implementation: implementation,
            implementationCodeHash: implementation.codehash,
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: replacesConfigId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }
}
