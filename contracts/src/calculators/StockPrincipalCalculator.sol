// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPrincipalCalculator} from "../interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {PrincipalMath} from "../libraries/PrincipalMath.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {AssetClass, StockPriceTerms} from "../types/HTPTypes.sol";

contract StockPrincipalCalculator is IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.STOCK;
    }

    /// @notice Computes stock cash principal from encoded unit price terms.
    function calculate(bytes calldata priceData, uint256 executedQuantity, uint8 assetDecimals)
        external
        pure
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal)
    {
        StockPriceTerms memory terms = _decodePriceData(priceData);

        if (
            terms.unitPrice == 0 || terms.priceAsOf == 0 || terms.referenceMarketHash == bytes32(0)
                || terms.priceSourceHash == bytes32(0)
        ) {
            revert HTPErrors.PriceDataMalformed(AssetClass.STOCK);
        }

        calculatedPriceTermsHash = HTPHashing.hashStockPriceTerms(terms);

        quotedPrice = terms.unitPrice;
        unitCashPrice = quotedPrice;

        cashPrincipal = PrincipalMath.calculate(executedQuantity, unitCashPrice, assetDecimals);
    }

    function _decodePriceData(bytes calldata priceData) private pure returns (StockPriceTerms memory terms) {
        if (priceData.length != 128) {
            revert HTPErrors.PriceDataMalformed(AssetClass.STOCK);
        }

        (uint256 unitPrice, uint256 priceAsOfWord, bytes32 referenceMarketHash, bytes32 priceSourceHash) =
            abi.decode(priceData, (uint256, uint256, bytes32, bytes32));

        if (priceAsOfWord > type(uint64).max) {
            revert HTPErrors.PriceDataMalformed(AssetClass.STOCK);
        }

        terms = StockPriceTerms({
            unitPrice: unitPrice,
            priceAsOf: SafeCast.toUint64(priceAsOfWord),
            referenceMarketHash: referenceMarketHash,
            priceSourceHash: priceSourceHash
        });

        if (keccak256(priceData) != keccak256(abi.encode(terms))) {
            revert HTPErrors.PriceDataMalformed(AssetClass.STOCK);
        }
    }
}
