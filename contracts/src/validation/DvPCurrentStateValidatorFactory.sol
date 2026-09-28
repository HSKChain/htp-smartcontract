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
        0xde202537a4ce39d21eb536c4d61dfca34da1ea3ac747b3a1a381a6862061cce5;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0xf5d19d60dd027bef3ab96820bd9f00cbcfe26aa8821314b5b501d42d63db60ee;

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
