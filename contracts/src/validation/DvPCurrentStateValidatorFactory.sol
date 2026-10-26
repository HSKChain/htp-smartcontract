// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPCurrentStateValidator} from "../interfaces/IDvPCurrentStateValidator.sol";
import {IDvPCurrentStateValidatorFactory} from "../interfaces/IDvPCurrentStateValidatorFactory.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {ConfigurationReferenceIntegrity} from "./ConfigurationReferenceIntegrity.sol";
import {DvPCurrentStateValidator} from "./DvPCurrentStateValidator.sol";
import {StrictSettlementFailureMapper} from "./StrictSettlementFailureMapper.sol";

contract DvPCurrentStateValidatorFactory is IDvPCurrentStateValidatorFactory {
    bytes32 private constant REFERENCE_INTEGRITY_CODE_HASH =
        0x114181354ab1dd58bcb5cde1665da547d659d177215e42cfacaa8f1eeb1608bf;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0x8b5e04167aa4e9ff9669108e0423144f56f57cc988c3b134b73fe53307a88a4e;

    ConfigurationReferenceIntegrity private referenceIntegrity;
    StrictSettlementFailureMapper private strictFailureMapper;

    constructor() {
        referenceIntegrity = new ConfigurationReferenceIntegrity();
        strictFailureMapper = new StrictSettlementFailureMapper();
    }

    /// @notice Deploys a per-DvP validator; caller must be the DvP address and helper code hashes must match.
    function deployValidator(address dvp) external override returns (IDvPCurrentStateValidator validator) {
        if (dvp == address(0) || msg.sender != dvp) {
            revert HTPErrors.InvalidChainOrContract(block.chainid, dvp);
        }
        ConfigurationReferenceIntegrity integrity = referenceIntegrity;
        if (address(integrity).codehash != REFERENCE_INTEGRITY_CODE_HASH) {
            revert HTPErrors.InvalidDvpValidator(address(integrity));
        }
        StrictSettlementFailureMapper mapper = strictFailureMapper;
        if (address(mapper).codehash != STRICT_FAILURE_MAPPER_CODE_HASH) {
            revert HTPErrors.InvalidDvpValidator(address(mapper));
        }
        validator = IDvPCurrentStateValidator(address(new DvPCurrentStateValidator(dvp, integrity, mapper)));
    }
}
