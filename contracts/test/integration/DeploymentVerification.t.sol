// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {DeploymentOperationBuilder} from "script/DeploymentOperationBuilder.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, DirectOperation} from "script/DeployTypes.sol";
import {VerifyDeployment} from "script/VerifyDeployment.s.sol";
import {VerifyRoles} from "script/VerifyRoles.s.sol";
import {DeploymentVersion} from "src/libraries/DeploymentVersion.sol";

contract DeploymentVerificationTest is Test {
    address private constant ADMIN = address(0x1801);
    address private constant GOVERNANCE = address(0x1802);
    address private constant UPGRADER = address(0x1803);
    address private constant PAUSER = address(0x1804);
    address private constant EXECUTOR = address(0x1805);
    address private constant OPERATOR = address(0x1806);
    bytes private constant DEPLOYMENT_VERSION = bytes("1.2.3");

    DeployHTP private deployer;
    CoreDeployment private core;
    DeploymentRoles private roles;

    function setUp() public {
        deployer = new DeployHTP();
        roles = DeploymentRoles({
            defaultAdmin: ADMIN,
            governance: GOVERNANCE,
            upgrader: UPGRADER,
            pauser: PAUSER,
            executor: EXECUTOR,
            configurer: OPERATOR
        });
        DeploymentConfig memory config =
            DeploymentConfig({roles: roles, deploymentVersion: DEPLOYMENT_VERSION, chainId: block.chainid});
        core = deployer.deployCore(config, uint64(vm.getNonce(address(deployer))));
    }

    function testPublicPostDeploymentVerificationCoversCoreRolesAndDependents() public {
        VerifyDeployment deploymentVerifier = new VerifyDeployment();
        VerifyRoles roleVerifier = new VerifyRoles();
        DeploymentOperationBuilder operationBuilder = new DeploymentOperationBuilder();

        deploymentVerifier.verifyCore(core, core.dvp.codehash, DeploymentVersion.hash(DEPLOYMENT_VERSION));
        roleVerifier.verifyTopology(core, roles);

        DirectOperation[] memory operations = operationBuilder.dependentDvpRegistration(core, keccak256("phase18"));
        for (uint256 i = 0; i < operations.length; ++i) {
            vm.prank(GOVERNANCE);
            (bool success,) = operations[i].target.call(operations[i].data);
            assertTrue(success);
        }
        deploymentVerifier.verifyDependentDvpRegistrations(core);
    }
}
