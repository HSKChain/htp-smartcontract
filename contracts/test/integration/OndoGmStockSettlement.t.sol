// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {OndoGmTokenAdapter} from "src/adapters/OndoGmTokenAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {
    AdapterConfig,
    AdapterStatus,
    AssetClass,
    Decision,
    RestrictionMode,
    SettlementParams,
    StockPriceTerms,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {
    IntegrationOndoGmToken,
    OndoComplianceMock,
    OndoComplianceViewMock,
    OndoGmListMock,
    OndoGmPauseManagerMock
} from "test/fixtures/OndoGmMocks.sol";
import {CrossAssetSettlementFixture} from "test/helpers/CrossAssetSettlementFixture.sol";

contract OndoGmStockSettlementTest is CrossAssetSettlementFixture {
    address private constant GM_IDENTIFIER = address(uint160(uint256(keccak256("global_markets"))));

    function testOndoGmStockSettlesAgainstUsdy() public {
        (IntegrationOndoGmToken token, AdapterConfig memory gmAdapterConfig) = _deployAndActivateGmAdapter();
        SettlementParams memory params = _stockSettlement(token, gmAdapterConfig, 3);

        _settleUsdy(params);

        assertEq(token.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(token.balanceOf(params.snapshot.buyer), 10 ether);
        assertTrue(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
        assertTrue(adapterRegistry.isAdapterActive(usdyAdapterConfig.adapterConfigId));
        assertTrue(adapterRegistry.isAdapterActive(gmAdapterConfig.adapterConfigId));
        assertEq(
            uint8(adapterRegistry.getCurrentAdapter(gmAdapterConfig.capabilityHash).status), uint8(AdapterStatus.ACTIVE)
        );
    }

    function testSiblingStockUsesSameAdapterConfig() public {
        (, IntegrationOndoGmToken sibling, AdapterConfig memory gmAdapterConfig) = _deployFamilyAndActivateGmAdapter();
        SettlementParams memory params = _stockSettlement(sibling, gmAdapterConfig, 3);

        _settleUsdy(params);

        assertEq(params.snapshot.assetToken, address(sibling));
        assertEq(params.snapshot.adapterConfigId, gmAdapterConfig.adapterConfigId);
        assertEq(sibling.balanceOf(params.snapshot.seller), 90 ether);
        assertEq(sibling.balanceOf(params.snapshot.buyer), 10 ether);
    }

    function testIssuerRuleAddedAfterPrecheckRevertsSettlementAtomically() public {
        (IntegrationOndoGmToken token, AdapterConfig memory gmAdapterConfig) = _deployAndActivateGmAdapter();
        SettlementParams memory params = _stockSettlement(token, gmAdapterConfig, 3);

        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));

        uint256 sellerAsset = token.balanceOf(params.snapshot.seller);
        uint256 buyerAsset = token.balanceOf(params.snapshot.buyer);
        uint256 buyerCash = settlementToken.balanceOf(params.snapshot.buyer);
        uint256 sellerCash = settlementToken.balanceOf(params.snapshot.seller);
        token.setForceTransferRevert(true);

        vm.expectRevert();
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertEq(token.balanceOf(params.snapshot.seller), sellerAsset);
        assertEq(token.balanceOf(params.snapshot.buyer), buyerAsset);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), buyerCash);
        assertEq(settlementToken.balanceOf(params.snapshot.seller), sellerCash);
        assertFalse(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
    }

    function _deployAndActivateGmAdapter() private returns (IntegrationOndoGmToken token, AdapterConfig memory config) {
        (token,, config) = _deployFamilyAndActivateGmAdapter();
    }

    function _deployFamilyAndActivateGmAdapter()
        private
        returns (
            IntegrationOndoGmToken referenceToken,
            IntegrationOndoGmToken siblingToken,
            AdapterConfig memory config
        )
    {
        OndoGmListMock blocklist = new OndoGmListMock();
        OndoGmListMock sanctions = new OndoGmListMock();
        OndoGmPauseManagerMock pauseManager = new OndoGmPauseManagerMock();
        OndoComplianceMock compliance = new OndoComplianceMock();
        OndoComplianceViewMock complianceView = new OndoComplianceViewMock(address(compliance), GM_IDENTIFIER);
        referenceToken = new IntegrationOndoGmToken(address(complianceView), address(pauseManager));
        siblingToken = new IntegrationOndoGmToken(address(complianceView), address(pauseManager));
        compliance.configure(GM_IDENTIFIER, address(blocklist), address(sanctions));

        IAssetAdapter adapter = IAssetAdapter(
            address(
                new OndoGmTokenAdapter(address(dvp), address(referenceToken), address(referenceToken).codehash, 100_000)
            )
        );
        config = _buildAdapterConfig(adapter, 2, usdyAdapterConfig.adapterConfigId);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(config);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(config.adapterConfigId, config.configHash);
    }

    function _stockSettlement(IntegrationOndoGmToken token, AdapterConfig memory gmAdapterConfig, uint64 feeEpoch)
        private
        returns (SettlementParams memory)
    {
        StockPriceTerms memory terms = StockPriceTerms({
            unitPrice: 1_140_000,
            priceAsOf: USDY_CREATED_AT,
            referenceMarketHash: bytes32(uint256(0xAA0101)),
            priceSourceHash: bytes32(uint256(0xAA0102))
        });
        return _activateAndBuildAssetSettlement(
            AssetClass.STOCK,
            stockCalculator,
            token,
            gmAdapterConfig,
            TokenStandard.ERC20,
            RestrictionMode.TOKEN_ENFORCED,
            abi.encode(terms),
            HTPHashing.hashStockPriceTerms(terms),
            feeEpoch
        );
    }
}
