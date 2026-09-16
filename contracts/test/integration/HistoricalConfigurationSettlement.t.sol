// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterConfig,
    AdapterStatus,
    AssetClass,
    AssetVersionConfig,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochStatus,
    PrincipalCalculatorConfig,
    ReasonCode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    SettlementTokenConfig
} from "src/types/HTPTypes.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

contract HistoricalConfigurationSettlementTest is UsdySettlementFixture {
    uint64 private constant REPLACEMENT_EPOCH = 3;
    uint64 private constant REPLACEMENT_CREATED_AT = USDY_CREATED_AT + 1;

    function testAllCurrentConfigurationSwitchesPreserveActiveHistoricalSettlement() public {
        SettlementParams memory oldParams = _validUsdyBuyParams();
        _switchEveryCurrentConfiguration();

        _settleUsdy(oldParams);

        assertTrue(dvp.usedQuoteHash(oldParams.tradeIntent.quoteHash));
        assertEq(
            adapterRegistry.getAdapter(usdyAdapterConfig.adapterConfigId).config.configHash,
            usdyAdapterConfig.configHash
        );
        assertEq(
            uint8(feeRegistry.getFeePolicyEpoch(USDY_FEE_EPOCH).status), uint8(FeePolicyEpochStatus.LEGACY_SERVING)
        );
    }

    function testAllCurrentSwitchesStillFailWhenSignedHistoricalConfigBecomesInactive() public {
        SettlementParams memory oldParams = _validUsdyBuyParams();
        _switchEveryCurrentConfiguration();
        vm.prank(REGISTRY_PAUSER);
        adapterRegistry.pauseAdapter(usdyAdapterConfig.adapterConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        assertEq(
            uint8(adapterRegistry.getAdapter(usdyAdapterConfig.adapterConfigId).status), uint8(AdapterStatus.PAUSED)
        );
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.AdapterInactive.selector, usdyAdapterConfig.adapterConfigId));
        vm.prank(EXECUTOR);
        dvp.settle(oldParams);
        assertFalse(dvp.usedQuoteHash(oldParams.tradeIntent.quoteHash));
    }

    function _switchEveryCurrentConfiguration() private {
        AdapterConfig memory replacementAssetAdapter = _registerReplacementAssetAdapter();
        AdapterConfig memory replacementSettlementAdapter = _registerReplacementSettlementAdapter();
        PrincipalCalculatorConfig memory replacementCalculator = _registerReplacementCalculator();
        SettlementTokenConfig memory replacementSettlementToken =
            _registerReplacementSettlementToken(replacementSettlementAdapter);
        AssetVersionConfig memory replacementAsset =
            _registerReplacementAsset(replacementAssetAdapter, replacementCalculator, replacementSettlementToken);
        FeeConfig memory replacementFee = _registerReplacementFee(replacementAsset, replacementSettlementToken);

        assertEq(
            adapterRegistry.getCurrentAdapter(replacementAssetAdapter.capabilityHash).config.adapterConfigId,
            replacementAssetAdapter.adapterConfigId
        );
        assertEq(
            adapterRegistry.getCurrentAdapter(replacementSettlementAdapter.capabilityHash).config.adapterConfigId,
            replacementSettlementAdapter.adapterConfigId
        );
        assertEq(
            calculatorRegistry.getCurrentPrincipalCalculator(AssetClass.FUND).config.calculatorConfigId,
            replacementCalculator.calculatorConfigId
        );
        assertEq(
            settlementTokenRegistry.getCurrentSettlementToken(address(settlementToken)).config.configId,
            replacementSettlementToken.configId
        );
        assertEq(
            assetVersionRegistry.getCurrentAssetVersion(address(usdyToken)).config.assetVersionId,
            replacementAsset.assetVersionId
        );
        (bytes32 resolvedFeeVersionId, bytes32 resolvedMatchedScopeHash) =
            feeRegistry.resolveApplicableFee(REPLACEMENT_EPOCH, replacementAsset.assetVersionId);
        assertEq(resolvedFeeVersionId, replacementFee.feeVersionId);
        assertEq(resolvedMatchedScopeHash, replacementFee.matchedScopeHash);
    }

    function _registerReplacementAssetAdapter() private returns (AdapterConfig memory config) {
        IAssetAdapter replacement = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(dvp),
                    address(usdyToken),
                    address(usdyToken).codehash,
                    address(usdyBlocklist),
                    address(usdyBlocklist).codehash,
                    address(usdyAllowlist),
                    address(usdyAllowlist).codehash,
                    address(usdySanctions),
                    address(usdySanctions).codehash,
                    INTEGRATION_PROVIDER_CALL_GAS
                )
            )
        );
        config = _buildAdapterConfig(replacement, 2, usdyAdapterConfig.adapterConfigId);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(config);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(config.adapterConfigId, config.configHash);
    }

    function _registerReplacementSettlementAdapter() private returns (AdapterConfig memory config) {
        IAssetAdapter replacement = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dvp))));
        config = _buildAdapterConfig(replacement, 2, adapterConfig.adapterConfigId);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(config);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(config.adapterConfigId, config.configHash);
    }

    function _registerReplacementCalculator() private returns (PrincipalCalculatorConfig memory config) {
        IPrincipalCalculator replacement = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 2
            ),
            revision: 2,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(replacement),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(replacement).codehash,
            replacesId: calculatorConfig.calculatorConfigId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(config);
        vm.prank(address(timelock));
        calculatorRegistry.activatePrincipalCalculator(config.calculatorConfigId, config.configHash);
    }

    function _registerReplacementSettlementToken(AdapterConfig memory replacementSettlementAdapter)
        private
        returns (SettlementTokenConfig memory config)
    {
        config = settlementTokenConfig;
        config.configId = ConfigId.derive(
            ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
            1,
            block.chainid,
            bytes32(uint256(uint160(address(settlementToken)))),
            2
        );
        config.revision = 2;
        config.adapterConfigId = replacementSettlementAdapter.adapterConfigId;
        config.adapterConfigHash = replacementSettlementAdapter.configHash;
        config.replacesConfigId = settlementTokenConfig.configId;
        config.configHash = bytes32(0);
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(config);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(config.configId, config.configHash);
    }

    function _registerReplacementAsset(
        AdapterConfig memory replacementAssetAdapter,
        PrincipalCalculatorConfig memory replacementCalculator,
        SettlementTokenConfig memory replacementSettlementToken
    ) private returns (AssetVersionConfig memory config) {
        config = usdyAssetVersionConfig;
        config.assetVersionId =
            ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 2);
        config.versionNo = 2;
        config.principalCalculatorConfigId = replacementCalculator.calculatorConfigId;
        config.principalCalculatorConfigHash = replacementCalculator.configHash;
        config.adapterConfigId = replacementAssetAdapter.adapterConfigId;
        config.adapterConfigHash = replacementAssetAdapter.configHash;
        config.settlementTokenConfigId = replacementSettlementToken.configId;
        config.settlementTokenConfigHash = replacementSettlementToken.configHash;
        config.replacesAssetVersionId = usdyAssetVersionConfig.assetVersionId;
        config.configHash = bytes32(0);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(config);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(config.assetVersionId, config.configHash);
    }

    function _registerReplacementFee(
        AssetVersionConfig memory replacementAsset,
        SettlementTokenConfig memory replacementSettlementToken
    ) private returns (FeeConfig memory config) {
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: REPLACEMENT_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: REPLACEMENT_CREATED_AT,
            quoteValidUntil: QUOTE_EXPIRES_AT,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash =
            FeeScope.matchedHash(REPLACEMENT_EPOCH, ScopeType.ASSET_VERSION, replacementAsset.assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: REPLACEMENT_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: replacementAsset.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: replacementSettlementToken.configId,
            settlementTokenConfigHash: replacementSettlementToken.configHash,
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
        feeRegistry.sealFeePolicyEpoch(REPLACEMENT_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(config.feeVersionId, config.configHash);
        vm.warp(REPLACEMENT_CREATED_AT);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(REPLACEMENT_EPOCH, epoch.configHash);
    }
}
