// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployAndReport} from "script/DeployAndReport.s.sol";
import {CoreDeployment} from "script/DeployTypes.sol";

contract DeployAndReportTest is Test {
    address private constant BROADCAST_DEPLOYER = address(0xD3E10);
    string private constant SOURCE_CONFIG_PATH = "deploy/config.example.json";
    string private constant CONFIG_PATH = "deploy/out/deploy-and-report-config-integration.json";
    string private constant REPORT_PATH = "deploy/out/deploy-and-report-integration.json";

    function testRunFromFileDeploysAndWritesReportWithoutConsumingExtraBroadcastNonces() public {
        DeployAndReport script = new DeployAndReport();
        uint64 firstCreateNonce = uint64(vm.getNonce(BROADCAST_DEPLOYER));
        _writeConfig(firstCreateNonce);
        vm.deal(BROADCAST_DEPLOYER, 100 ether);
        assertEq(DeployAndReport.runFromFile.selector, bytes4(keccak256("runFromFile(string,string)")));

        CoreDeployment memory core = script.runFromFile(CONFIG_PATH, REPORT_PATH);

        assertEq(core.adapterRegistry.implementation, vm.computeCreateAddress(BROADCAST_DEPLOYER, firstCreateNonce));
        assertEq(core.dvp, vm.computeCreateAddress(BROADCAST_DEPLOYER, firstCreateNonce + 17));
        assertEq(vm.getNonce(BROADCAST_DEPLOYER), firstCreateNonce + 18);

        string memory json = vm.readFile(_repositoryPath(REPORT_PATH));
        assertEq(vm.parseJsonString(json, ".metadata.configPath"), CONFIG_PATH);
        assertEq(vm.parseJsonAddress(json, ".metadata.deployer"), BROADCAST_DEPLOYER);
        assertEq(vm.parseJsonUint(json, ".metadata.createNonceRange.first"), firstCreateNonce);
        assertEq(vm.parseJsonUint(json, ".metadata.createNonceRange.last"), firstCreateNonce + 17);
        assertEq(vm.parseJsonUint(json, ".metadata.createNonceRange.finalExclusive"), firstCreateNonce + 18);
        assertEq(vm.parseJsonAddress(json, ".dvp.address"), core.dvp);
        assertFalse(vm.parseJsonBool(json, ".verification.productionReady"));

        vm.removeFile(_repositoryPath(REPORT_PATH));
        vm.removeFile(_repositoryPath(CONFIG_PATH));
    }

    function _writeConfig(uint64 firstCreateNonce) private {
        string memory absolutePath = _repositoryPath(CONFIG_PATH);
        vm.writeFile(absolutePath, vm.readFile(_repositoryPath(SOURCE_CONFIG_PATH)));
        vm.writeJson(_quote(vm.toString(BROADCAST_DEPLOYER)), absolutePath, ".roles.deployer");
        vm.writeJson(vm.toString(uint256(firstCreateNonce)), absolutePath, ".expectedFirstCreateNonce");
    }

    function _repositoryPath(string memory relativePath) private view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../", relativePath);
    }

    function _quote(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }
}
