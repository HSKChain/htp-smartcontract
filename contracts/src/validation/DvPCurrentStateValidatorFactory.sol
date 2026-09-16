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
        0x620b98f11361a4bacd813d365d250f021b27568c8094e39bdf0fd3a17a284e9c;
    bytes32 private constant STRICT_FAILURE_MAPPER_CODE_HASH =
        0xa3edd3c270dafc75bf98d1e7e53fe1e03cae42e5bbc655328f922447ae8ef583;

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
