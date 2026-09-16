// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {MarketRuleConfig, MarketRuleRecord, MarketRuleStatus, ReasonCode} from "src/types/HTPTypes.sol";
import {DvPPreCheckTestBase} from "test/helpers/DvPPreCheckTestBase.sol";

contract MarketRuleRegistryTest is DvPPreCheckTestBase {
    function testRegistrationPersistsIdentityHashAndReferences() public {
        MarketRuleConfig memory next = _nextRule();

        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(next);

        MarketRuleRecord memory record = marketRuleRegistry.getMarketRule(next.marketRuleConfigId);
        assertTrue(record.exists);
        assertFalse(record.isSealed);
        assertFalse(record.paused);
        assertEq(uint8(record.status), uint8(MarketRuleStatus.DRAFT));
        assertEq(record.config.marketRuleConfigId, next.marketRuleConfigId);
        assertEq(record.config.configHash, next.configHash);
        assertEq(HTPHashing.hashMarketRuleConfig(record.config), next.configHash);
        assertEq(record.config.assetVersionId, assetVersionConfig.assetVersionId);
        assertEq(record.config.settlementToken, address(settlementToken));
        assertEq(record.config.settlementTokenConfigId, settlementTokenConfig.configId);
        assertEq(record.config.settlementTokenConfigHash, settlementTokenConfig.configHash);
    }

    function testRegistrationRejectsInvalidIdentityHashReferenceAndPrecision() public {
        MarketRuleConfig memory invalid = _nextRule();
        invalid.marketRuleConfigId = bytes32(uint256(0xBAD));
        invalid.configHash = bytes32(0);
        invalid.configHash = HTPHashing.hashMarketRuleConfig(invalid);
        vm.expectPartialRevert(HTPErrors.ConfigIdMismatch.selector);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(invalid);

        invalid = _nextRule();
        invalid.configHash = bytes32(uint256(0xBAD));
        vm.expectPartialRevert(HTPErrors.ConfigHashMismatch.selector);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(invalid);

        invalid = _nextRule();
        invalid.settlementTokenConfigHash = bytes32(uint256(0xBAD));
        invalid.configHash = bytes32(0);
        invalid.configHash = HTPHashing.hashMarketRuleConfig(invalid);
        vm.expectPartialRevert(HTPErrors.ConfigReferenceMismatch.selector);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(invalid);

        invalid = _nextRule();
        invalid.quantityStep = 1;
        invalid.configHash = bytes32(0);
        invalid.configHash = HTPHashing.hashMarketRuleConfig(invalid);
        vm.expectPartialRevert(HTPErrors.InvalidMarketRule.selector);
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(invalid);
    }

    // 登记只要求 Asset Version 存在且三元组一致，激活才要求 ACTIVE。
    // 支持「一批登记 + 一批激活」，同时覆盖登记后 Asset Version 被暂停的漂移场景。
    function testRegisterAcceptsNonActiveAssetVersionButActivationStillRequiresActive() public {
        MarketRuleConfig memory next = _nextRule();

        vm.prank(REGISTRY_PAUSER);
        assetVersionRegistry.pauseAssetVersion(
            assetVersionConfig.assetVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        // Asset Version 非 ACTIVE：登记仍然成功。
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(next);
        assertTrue(marketRuleRegistry.getMarketRule(next.marketRuleConfigId).exists);

        vm.prank(address(timelock));
        marketRuleRegistry.sealMarketRule(next.marketRuleConfigId, next.configHash);

        // 但激活必须因 Asset Version 非 ACTIVE 而失败。
        vm.expectPartialRevert(HTPErrors.ConfigReferenceMismatch.selector);
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(next.marketRuleConfigId, next.configHash);

        // Asset Version 恢复后，同一条市场规则即可激活。
        vm.prank(address(timelock));
        assetVersionRegistry.unpauseAssetVersion(
            assetVersionConfig.assetVersionId,
            assetVersionConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(next.marketRuleConfigId, next.configHash);
        assertEq(
            uint8(marketRuleRegistry.getMarketRule(next.marketRuleConfigId).status), uint8(MarketRuleStatus.ACTIVE)
        );
    }

    function testSealActivateLegacyPauseUnpauseAndCloseLifecycle() public {
        MarketRuleConfig memory next = _nextRule();
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(next);

        vm.prank(address(timelock));
        marketRuleRegistry.sealMarketRule(next.marketRuleConfigId, next.configHash);
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(next.marketRuleConfigId, next.configHash);

        MarketRuleRecord memory previous = marketRuleRegistry.getMarketRule(marketRuleConfig.marketRuleConfigId);
        MarketRuleRecord memory active = marketRuleRegistry.getMarketRule(next.marketRuleConfigId);
        assertEq(uint8(previous.status), uint8(MarketRuleStatus.LEGACY_SERVING));
        assertEq(uint8(active.status), uint8(MarketRuleStatus.ACTIVE));
        assertTrue(active.isSealed);

        vm.prank(REGISTRY_PAUSER);
        marketRuleRegistry.pauseMarketRule(next.marketRuleConfigId, ReasonCode.CONFIG_MISMATCH, EVIDENCE_HASH);
        assertTrue(marketRuleRegistry.getMarketRule(next.marketRuleConfigId).paused);

        vm.prank(address(timelock));
        marketRuleRegistry.unpauseMarketRule(
            next.marketRuleConfigId, next.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        assertFalse(marketRuleRegistry.getMarketRule(next.marketRuleConfigId).paused);

        vm.warp(marketRuleConfig.settlementValidUntil + 1);
        vm.prank(address(timelock));
        marketRuleRegistry.closeMarketRule(marketRuleConfig.marketRuleConfigId, EVIDENCE_HASH);
        previous = marketRuleRegistry.getMarketRule(marketRuleConfig.marketRuleConfigId);
        assertEq(uint8(previous.status), uint8(MarketRuleStatus.CLOSED));
        assertEq(
            marketRuleRegistry.getCurrentMarketRule(assetVersionConfig.assetVersionId).config.marketRuleConfigId,
            next.marketRuleConfigId
        );
    }

    function testLegacyRuleServiceabilityUsesSignedHistoricalWindow() public {
        MarketRuleConfig memory next = _nextRule();
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(next);
        vm.startPrank(address(timelock));
        marketRuleRegistry.sealMarketRule(next.marketRuleConfigId, next.configHash);
        marketRuleRegistry.activateMarketRule(next.marketRuleConfigId, next.configHash);
        vm.stopPrank();

        assertTrue(
            marketRuleRegistry.isMarketRuleServiceable(
                marketRuleConfig.marketRuleConfigId,
                marketRuleConfig.configHash,
                marketRuleConfig.assetVersionId,
                CREATED_AT,
                QUOTE_EXPIRES_AT,
                TRADE_DEADLINE
            )
        );
        assertFalse(
            marketRuleRegistry.isMarketRuleServiceable(
                marketRuleConfig.marketRuleConfigId,
                marketRuleConfig.configHash,
                marketRuleConfig.assetVersionId,
                QUOTE_VALID_FROM - 1,
                QUOTE_EXPIRES_AT,
                TRADE_DEADLINE
            )
        );
        assertFalse(
            marketRuleRegistry.isMarketRuleServiceable(
                marketRuleConfig.marketRuleConfigId,
                marketRuleConfig.configHash,
                marketRuleConfig.assetVersionId,
                CREATED_AT,
                marketRuleConfig.settlementValidUntil + 1,
                TRADE_DEADLINE
            )
        );
    }

    function _nextRule() private view returns (MarketRuleConfig memory next) {
        next = marketRuleConfig;
        next.revision = marketRuleConfig.revision + 1;
        next.replacesConfigId = marketRuleConfig.marketRuleConfigId;
        next.marketRuleConfigId = ConfigId.derive(
            ConfigId.MARKET_RULE_NAMESPACE, next.schemaVersion, block.chainid, next.assetVersionId, next.revision
        );
        next.configHash = bytes32(0);
        next.configHash = HTPHashing.hashMarketRuleConfig(next);
    }
}
