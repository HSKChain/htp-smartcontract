// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {SettlementCoherenceResult, SettlementParamsValidation} from "src/libraries/SettlementParamsValidation.sol";
import {SettlementParams} from "src/types/HTPTypes.sol";

contract SettlementParamsValidationHarness {
    function inspect(SettlementParams calldata params)
        external
        pure
        returns (bytes32 invalidField, address buyer, address seller)
    {
        SettlementCoherenceResult memory result = SettlementParamsValidation.inspect(params);
        return (result.invalidField, result.buyer, result.seller);
    }

    function deriveParties(SettlementParams calldata params)
        external
        pure
        returns (bytes32 invalidField, address buyer, address seller)
    {
        SettlementCoherenceResult memory result = SettlementParamsValidation.deriveParties(params);
        return (result.invalidField, result.buyer, result.seller);
    }

    function hasRequiredStructure(SettlementParams calldata params) external pure returns (bool) {
        return SettlementParamsValidation.hasRequiredStructure(params);
    }
}
