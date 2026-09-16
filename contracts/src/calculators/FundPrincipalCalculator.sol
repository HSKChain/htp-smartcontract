// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPrincipalCalculator} from "../interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {CalendarDate} from "../libraries/CalendarDate.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {PrincipalMath} from "../libraries/PrincipalMath.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {AssetClass, FundPriceTerms} from "../types/HTPTypes.sol";

contract FundPrincipalCalculator is IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    /// @notice Computes fund cash principal from encoded NAV price terms.
    function calculate(bytes calldata priceData, uint256 executedQuantity, uint8 assetDecimals)
        external
        pure
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal)
    {
        FundPriceTerms memory terms = _decodePriceData(priceData);

        if (terms.navPerUnit == 0 || terms.navSourceHash == bytes32(0)) {
            revert HTPErrors.PriceDataMalformed(AssetClass.FUND);
        }

        CalendarDate.requireValid(terms.navDate);

        calculatedPriceTermsHash = HTPHashing.hashFundPriceTerms(terms);

        quotedPrice = terms.navPerUnit;
        unitCashPrice = quotedPrice;

        cashPrincipal = PrincipalMath.calculate(executedQuantity, unitCashPrice, assetDecimals);
    }

    function _decodePriceData(bytes calldata priceData) private pure returns (FundPriceTerms memory terms) {
        if (priceData.length != 96) {
            revert HTPErrors.PriceDataMalformed(AssetClass.FUND);
        }

        (uint256 navPerUnit, uint256 navDateWord, bytes32 navSourceHash) =
            abi.decode(priceData, (uint256, uint256, bytes32));

        if (navDateWord > type(uint32).max) {
            revert HTPErrors.PriceDataMalformed(AssetClass.FUND);
        }

        terms = FundPriceTerms({
            navPerUnit: navPerUnit, navDate: SafeCast.toUint32(navDateWord), navSourceHash: navSourceHash
        });

        if (keccak256(priceData) != keccak256(abi.encode(terms))) {
            revert HTPErrors.PriceDataMalformed(AssetClass.FUND);
        }
    }
}
