// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterConfig,
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    RoundingMode,
    ScopeType,
    SettlementParams
} from "src/types/HTPTypes.sol";
import {AddressListMock} from "test/fixtures/AdapterMocks.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract UsdyConfigurationDriftTest is UsdySettlementFixture {
    uint64 private constant REPLACEMENT_FEE_EPOCH = 3;
    uint64 private constant REPLACEMENT_CREATED_AT = USDY_CREATED_AT + 1;

    function testProviderDriftFailsOldGraphAndNewAdapterAssetVersionRestoresSettlement() public {
        SettlementParams memory oldParams = _validUsdyBuyParams();
        AddressListMock nextBlocklist = new AddressListMock();
        AddressListMock nextAllowlist = new AddressListMock();
        AddressListMock nextSanctions = new AddressListMock();
        nextAllowlist.setAllowed(oldParams.snapshot.seller, true);
        nextAllowlist.setAllowed(oldParams.snapshot.buyer, true);
        nextAllowlist.setAllowed(address(dvp), true);
        usdyToken.configureProviders(address(nextBlocklist), address(nextAllowlist), address(nextSanctions));

        vm.expectPartialRevert(HTPErrors.ExternalCallFailed.selector);
        vm.prank(EXECUTOR);
        dvp.settle(oldParams);
        assertFalse(dvp.usedQuoteHash(oldParams.tradeIntent.quoteHash));

        IAssetAdapter nextAdapter = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(dvp),
                    address(usdyToken),
                    address(usdyToken).codehash,
                    address(nextBlocklist),
                    address(nextBlocklist).codehash,
                    address(nextAllowlist),
                    address(nextAllowlist).codehash,
                    address(nextSanctions),
                    address(nextSanctions).codehash,
                    INTEGRATION_PROVIDER_CALL_GAS
                )
            )
        );
        AdapterConfig memory nextAdapterConfig = _buildAdapterConfig(nextAdapter, 2, usdyAdapterConfig.adapterConfigId);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(nextAdapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(nextAdapterConfig.adapterConfigId, nextAdapterConfig.configHash);

        AssetVersionConfig memory nextAssetConfig = usdyAssetVersionConfig;
        nextAssetConfig.versionNo = 2;
        nextAssetConfig.assetVersionId =
            ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 2);
        nextAssetConfig.adapterConfigId = nextAdapterConfig.adapterConfigId;
        nextAssetConfig.adapterConfigHash = nextAdapterConfig.configHash;
        nextAssetConfig.replacesAssetVersionId = usdyAssetVersionConfig.assetVersionId;
        nextAssetConfig.configHash = bytes32(0);
        nextAssetConfig.configHash = HTPHashing.hashAssetVersionConfig(nextAssetConfig);
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(nextAssetConfig);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(nextAssetConfig.assetVersionId, nextAssetConfig.configHash);

        _setEligibilityForAsset(nextAssetConfig.assetVersionId, oldParams.snapshot.seller);
        _setEligibilityForAsset(nextAssetConfig.assetVersionId, oldParams.snapshot.buyer);

        FeeConfig memory nextFeeConfig = _activateReplacementFee(nextAssetConfig.assetVersionId);
        MarketRuleConfig memory nextMarketRule = _activateReplacementMarketRule(nextAssetConfig);
        SettlementParams memory nextParams = _validUsdyBuyParams();
        _bindConfiguration(nextParams, nextAssetConfig, nextAdapterConfig, nextFeeConfig);
        _bindMarketRule(nextParams, nextMarketRule);
        nextParams.snapshot.createdAt = REPLACEMENT_CREATED_AT;
        _resign(nextParams);

        _settleUsdy(nextParams);
        assertTrue(dvp.usedQuoteHash(nextParams.tradeIntent.quoteHash));
        assertEq(usdyToken.balanceOf(nextParams.snapshot.buyer), 10 ether);
    }

    function _activateReplacementFee(bytes32 assetVersionId) private returns (FeeConfig memory config) {
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: REPLACEMENT_FEE_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: REPLACEMENT_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash = FeeScope.matchedHash(REPLACEMENT_FEE_EPOCH, ScopeType.ASSET_VERSION, assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: REPLACEMENT_FEE_EPOCH,
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
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: REPLACEMENT_CREATED_AT,
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
        feeRegistry.sealFeePolicyEpoch(REPLACEMENT_FEE_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(REPLACEMENT_CREATED_AT);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(REPLACEMENT_FEE_EPOCH, epoch.configHash, config.feeVersionId);
    }

    function _activateReplacementMarketRule(AssetVersionConfig memory assetConfig)
        private
        returns (MarketRuleConfig memory config)
    {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, assetConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: assetConfig.assetVersionId,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            minCashPrincipal: 1,
            minExecutableQuantity: 1,
            quantityStep: 1,
            priceTick: 1,
            priceDecimals: settlementTokenConfig.settlementTokenDecimals,
            quantityDecimals: assetConfig.assetDecimals,
            quoteValidFrom: REPLACEMENT_CREATED_AT,
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
}
