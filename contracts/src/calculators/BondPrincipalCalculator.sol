// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPrincipalCalculator} from "../interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {CalendarDate} from "../libraries/CalendarDate.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {PrincipalMath} from "../libraries/PrincipalMath.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {AssetClass, BondPriceTerms} from "../types/HTPTypes.sol";

contract BondPrincipalCalculator is IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.BOND;
    }

    /// @notice Computes bond cash principal from encoded clean/full price terms.
    function calculate(bytes calldata priceData, uint256 executedQuantity, uint8 assetDecimals)
        external
        pure
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal)
    {
        BondPriceTerms memory terms = _decodePriceData(priceData);

        if (terms.cleanPricePerUnit == 0) {
            revert HTPErrors.PriceDataMalformed(AssetClass.BOND);
        }

        if (terms.sourceHash == bytes32(0)) {
            revert HTPErrors.PriceDataMalformed(AssetClass.BOND);
        }

        CalendarDate.requireValid(terms.settlementDate);

        if (terms.accruedInterestPerUnit > type(uint256).max - terms.cleanPricePerUnit) {
            revert HTPErrors.BondFullPriceOverflow(terms.cleanPricePerUnit, terms.accruedInterestPerUnit);
        }

        calculatedPriceTermsHash = HTPHashing.hashBondPriceTerms(terms);

        quotedPrice = terms.cleanPricePerUnit;
        unitCashPrice = quotedPrice + terms.accruedInterestPerUnit;

        cashPrincipal = PrincipalMath.calculate(executedQuantity, unitCashPrice, assetDecimals);
    }

    function _decodePriceData(bytes calldata priceData) private pure returns (BondPriceTerms memory terms) {
        if (priceData.length != 128) {
            revert HTPErrors.PriceDataMalformed(AssetClass.BOND);
        }

        (uint256 cleanPrice, uint256 accruedInterest, uint256 settlementDateWord, bytes32 sourceHash) =
            abi.decode(priceData, (uint256, uint256, uint256, bytes32));

        if (settlementDateWord > type(uint32).max) {
            revert HTPErrors.PriceDataMalformed(AssetClass.BOND);
        }

        terms = BondPriceTerms({
            cleanPricePerUnit: cleanPrice,
            accruedInterestPerUnit: accruedInterest,
            settlementDate: SafeCast.toUint32(settlementDateWord),
            sourceHash: sourceHash
        });

        if (keccak256(priceData) != keccak256(abi.encode(terms))) {
            revert HTPErrors.PriceDataMalformed(AssetClass.BOND);
        }
    }
}
