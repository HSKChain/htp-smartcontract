// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IDvPGovernanceView} from "../../src/interfaces/IDvPGovernanceView.sol";

contract MockDvP is IDvPGovernanceView {
    bytes32 private immutable DEPLOYMENT_VERSION_HASH;

    bool public globalPaused;
    bool public retired;

    constructor(bytes32 deploymentVersionHash_) {
        DEPLOYMENT_VERSION_HASH = deploymentVersionHash_;
    }

    function deploymentVersionHash() external view returns (bytes32) {
        return DEPLOYMENT_VERSION_HASH;
    }

    function setGlobalPaused(bool value) external {
        globalPaused = value;
    }

    function setRetired(bool value) external {
        retired = value;
    }
}
