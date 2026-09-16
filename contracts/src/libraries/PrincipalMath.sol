// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HTPErrors} from "../types/HTPErrors.sol";

/// @notice Cash principal from executed quantity and unit cash price.
library PrincipalMath {
    uint8 internal constant MAX_ASSET_DECIMALS = 36;

    /// @notice Compute cash principal; reverts on bad decimals or zero result.
    function calculate(uint256 executedQuantity, uint256 unitCashPrice, uint8 assetDecimals)
        internal
        pure
        returns (uint256 cashPrincipal)
    {
        if (assetDecimals > MAX_ASSET_DECIMALS) {
            revert HTPErrors.AssetDecimalsOutOfRange(assetDecimals);
        }

        cashPrincipal = Math.mulDiv(executedQuantity, unitCashPrice, 10 ** uint256(assetDecimals));

        if (cashPrincipal == 0) {
            revert HTPErrors.CashPrincipalZero();
        }
    }
}
