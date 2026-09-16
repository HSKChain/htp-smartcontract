// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AssetClass} from "../types/HTPTypes.sol";

/// @notice Asset-class principal and price-term calculator plug-in.
interface IPrincipalCalculator {
    function interfaceVersion() external pure returns (bytes32);
    function assetClass() external pure returns (AssetClass);

    /// @notice Derive price terms hash, quoted price, unit cash price, and cash principal from priceData.
    function calculate(bytes calldata priceData, uint256 executedQuantity, uint8 assetDecimals)
        external
        view
        returns (bytes32 calculatedPriceTermsHash, uint256 quotedPrice, uint256 unitCashPrice, uint256 cashPrincipal);
}
