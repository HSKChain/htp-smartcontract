// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {CoreDeploymentTopology} from "script/CoreDeploymentTopology.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, RegistryDeployment} from "script/DeployTypes.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {Roles} from "src/libraries/Roles.sol";

contract DeploymentTopologyParityTest is Test, CoreDeploymentTopology {
    address private constant ADMIN = address(0x1001);
    address private constant GOVERNANCE = address(0x1002);
    address private constant UPGRADER = address(0x1003);
    address private constant PAUSER = address(0x1004);
    address private constant EXECUTOR = address(0x1005);
    address private constant OPERATOR = address(0x1006);

    function testProductionAdapterAndTopologyShareCreateOrderWiringAndRoles() public {
        DeploymentConfig memory config = _config();

        DeployHTP production = new DeployHTP();
        uint64 productionNonce = uint64(vm.getNonce(address(production)));
        CoreDeployment memory fromProduction = production.deployCore(config, productionNonce);

        uint64 topologyNonce = uint64(vm.getNonce(address(this)));
        address predictedTopologyDvp = _predictDvpAddress(address(this), topologyNonce);
        CoreDeployment memory fromTopology = _deployCoreTopology(config, predictedTopologyDvp);

        assertEq(CREATES_BEFORE_DVP, 17);
        assertEq(TOTAL_CORE_CREATES, 18);
        assertEq(fromTopology.dvp, predictedTopologyDvp);
        _assertCreateOrder(address(production), productionNonce, fromProduction);
        _assertCreateOrder(address(this), topologyNonce, fromTopology);
        _assertRolesAndWiring(fromProduction);
        _assertRolesAndWiring(fromTopology);
    }

    function _assertCreateOrder(address deployer, uint64 firstNonce, CoreDeployment memory core) private pure {
        RegistryDeployment[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            assertEq(registries[i].implementation, vm.computeCreateAddress(deployer, firstNonce + uint64(2 * i)));
            assertEq(registries[i].proxy, vm.computeCreateAddress(deployer, firstNonce + uint64(2 * i + 1)));
        }
        assertEq(core.currentStateValidatorFactory, vm.computeCreateAddress(deployer, firstNonce + 16));
        assertEq(core.dvp, vm.computeCreateAddress(deployer, firstNonce + 17));
    }

    function _assertRolesAndWiring(CoreDeployment memory core) private view {
        RegistryDeployment[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            IAccessControl access = IAccessControl(registries[i].proxy);
            assertTrue(access.hasRole(Roles.DEFAULT_ADMIN_ROLE, ADMIN));
            assertTrue(access.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
            assertTrue(access.hasRole(Roles.UPGRADER_ROLE, UPGRADER));
            assertTrue(access.hasRole(Roles.PAUSER_ROLE, PAUSER));
        }

        DvPSettlement dvp = DvPSettlement(core.dvp);
        assertEq(address(dvp.participantRegistry()), core.participantRegistry.proxy);
        assertEq(address(dvp.marketRuleRegistry()), core.marketRuleRegistry.proxy);
        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, ADMIN));
        assertTrue(dvp.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(dvp.hasRole(Roles.EXECUTOR_ROLE, EXECUTOR));
    }

    function _config() private view returns (DeploymentConfig memory) {
        return DeploymentConfig({
            roles: DeploymentRoles({
                defaultAdmin: ADMIN,
                governance: GOVERNANCE,
                upgrader: UPGRADER,
                pauser: PAUSER,
                executor: EXECUTOR,
                configurer: OPERATOR
            }),
            deploymentVersion: bytes("1.2.3"),
            chainId: block.chainid
        });
    }

    function _registries(CoreDeployment memory core) private pure returns (RegistryDeployment[8] memory registries) {
        registries[0] = core.adapterRegistry;
        registries[1] = core.calculatorRegistry;
        registries[2] = core.settlementTokenRegistry;
        registries[3] = core.assetVersionRegistry;
        registries[4] = core.eligibilityRegistry;
        registries[5] = core.marketRuleRegistry;
        registries[6] = core.feeRegistry;
        registries[7] = core.participantRegistry;
    }
}
