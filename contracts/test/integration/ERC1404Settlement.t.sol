// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IERC1404Restriction} from "src/adapters/ERC1404Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterConfig,
    AssetClass,
    Decision,
    FundPriceTerms,
    RequesterSide,
    RestrictionMode,
    SettlementParams,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {CrossAssetSettlementFixture} from "test/helpers/CrossAssetSettlementFixture.sol";
import {SchemaFixtures} from "test/generated/SchemaFixtures.sol";

contract ERC1404SettlementTest is CrossAssetSettlementFixture {
    AdapterConfig private erc1404AdapterConfig;

    function testErc1404BuyUsesExactAssetDirection() public {
        SettlementParams memory buyParams = _buildErc1404Buy();
        erc1404Token.configureExpectedTransfer(
            buyParams.snapshot.seller, buyParams.snapshot.buyer, buyParams.snapshot.executedQuantity, true
        );
        _expectExactAdapterLegs(buyParams);
        _assertPreCheckPass(buyParams);
        _expectExactAdapterLegs(buyParams);
        _settleUsdy(buyParams);
        assertEq(erc1404Token.balanceOf(buyParams.snapshot.buyer), 10 ether);
    }

    function testErc1404SellUsesExactAssetDirection() public {
        SettlementParams memory sellParams = _buildErc1404Sell();
        erc1404Token.configureExpectedTransfer(
            sellParams.snapshot.seller, sellParams.snapshot.buyer, sellParams.snapshot.executedQuantity, true
        );
        _expectExactAdapterLegs(sellParams);
        _assertPreCheckPass(sellParams);
        _expectExactAdapterLegs(sellParams);
        _settleUsdy(sellParams);
        assertEq(erc1404Token.balanceOf(sellParams.snapshot.seller), 90 ether);
    }

    function testErc1404NonZeroRestrictionBlocksAndRollsBack() public {
        SettlementParams memory params = _buildErc1404Buy();
        erc1404Token.setRestrictionCode(7);

        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);

        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(erc1404Token.balanceOf(params.snapshot.seller), 100 ether);
        assertEq(erc1404Token.balanceOf(params.snapshot.buyer), 0);
    }

    function testErc1404UnknownAndRevertFailClosed() public {
        SettlementParams memory params = _buildErc1404Buy();
        bytes memory checkCall = abi.encodeCall(
            IERC1404Restriction.detectTransferRestriction,
            (params.snapshot.seller, params.snapshot.buyer, params.snapshot.executedQuantity)
        );
        vm.mockCallRevert(address(erc1404Token), checkCall, bytes("UNAVAILABLE"));

        vm.expectPartialRevert(HTPErrors.ExternalCallFailed.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);

        vm.clearMockedCalls();
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
    }

    function testErc1404ReversedDirectionIsBlocked() public {
        SettlementParams memory params = _buildErc1404Buy();
        erc1404Token.configureExpectedTransfer(
            params.snapshot.buyer, params.snapshot.seller, params.snapshot.executedQuantity, true
        );

        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedTradeIdHash(params.snapshot.tradeIdHash));
    }

    function _buildErc1404Buy() private returns (SettlementParams memory params) {
        erc1404AdapterConfig = _buildAdapterConfig(erc1404Adapter, 1, bytes32(0));
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(erc1404AdapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(erc1404AdapterConfig.adapterConfigId, erc1404AdapterConfig.configHash);

        bytes memory priceData = SchemaFixtures.priceData();
        FundPriceTerms memory terms = abi.decode(priceData, (FundPriceTerms));
        params = _activateAndBuildAssetSettlement(
            AssetClass.FUND,
            fundCalculator,
            erc1404Token,
            erc1404AdapterConfig,
            TokenStandard.ERC1404,
            RestrictionMode.ISSUER_EXTERNAL,
            priceData,
            HTPHashing.hashFundPriceTerms(terms),
            3
        );
    }

    function _buildErc1404Sell() private returns (SettlementParams memory params) {
        params = _buildErc1404Buy();
        address maker = params.firmQuote.quotingMaker;
        address requester = params.firmQuote.requester;
        params.firmQuote.requesterSide = RequesterSide.SELL;
        params.tradeIntent.requesterSide = RequesterSide.SELL;
        params.snapshot.requesterSide = RequesterSide.SELL;
        params.tradeIntent.buyer = maker;
        params.snapshot.buyer = maker;
        params.tradeIntent.seller = requester;
        params.snapshot.seller = requester;
        _applyIdentityFeeAmounts(params, integrationFeeConfig);
        erc1404Token.setBalance(requester, 100 ether);
        erc1404Token.setAllowance(requester, address(dvp), params.snapshot.executedQuantity);
        settlementToken.setBalance(maker, 100_000_000);
        settlementToken.setAllowance(maker, address(dvp), params.snapshot.buyerDebit);
        _resign(params);
    }

    function _assertPreCheckPass(SettlementParams memory params) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
    }

    function _expectExactAdapterLegs(SettlementParams memory params) private {
        vm.expectCall(
            address(erc1404Adapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    address(erc1404Token),
                    params.snapshot.seller,
                    params.snapshot.buyer,
                    params.snapshot.executedQuantity,
                    TransferLeg.ASSET,
                    params.tradeIntent.snapshotHash
                )
            )
        );
        vm.expectCall(
            address(adapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    address(settlementToken),
                    params.snapshot.buyer,
                    params.snapshot.seller,
                    params.snapshot.sellerCredit,
                    TransferLeg.SETTLEMENT_TO_SELLER,
                    params.tradeIntent.snapshotHash
                )
            )
        );
        vm.expectCall(
            address(adapter),
            abi.encodeCall(
                IAssetAdapter.preCheck,
                (
                    address(settlementToken),
                    params.snapshot.buyer,
                    params.snapshot.collector,
                    params.snapshot.collectorCredit,
                    TransferLeg.SETTLEMENT_TO_COLLECTOR,
                    params.tradeIntent.snapshotHash
                )
            )
        );
    }
}
