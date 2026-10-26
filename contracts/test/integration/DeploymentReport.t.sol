// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {ConfigurationKind, CoreReportInput, WriteDeploymentReport} from "script/WriteDeploymentReport.s.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles} from "script/DeployTypes.sol";

contract WriteDeploymentReportHarness is WriteDeploymentReport {
    function statusLabel(ConfigurationKind kind, uint256 statusCode) external pure returns (string memory) {
        return _statusLabel(kind, statusCode);
    }
}

contract DeploymentReportTest is Test {
    address private constant ADMIN = address(0x7101);
    address private constant GOVERNANCE = address(0x7102);
    address private constant UPGRADER = address(0x7103);
    address private constant PAUSER = address(0x7104);
    address private constant EXECUTOR = address(0x7105);
    address private constant OPERATOR = address(0x7106);

    string private constant SOURCE_CONFIG_PATH = "deploy/config.example.json";
    string private constant CONFIG_PATH = "deploy/out/deployment-report-config.json";
    string private constant REPORT_PATH = "deploy/out/deployment-report-integration.json";

    function testLabelsDeprecatedPausedFeeVersion() public {
        WriteDeploymentReportHarness writer = new WriteDeploymentReportHarness();
        assertEq(writer.statusLabel(ConfigurationKind.FEE_VERSION, 5), "DEPRECATED_PAUSED");
        assertEq(writer.statusLabel(ConfigurationKind.ADAPTER, 5), "UNKNOWN");
    }

    function testWritesDirectRoleReportWithoutLegacyGovernanceFields() public {
        DeployHTP deployer = new DeployHTP();
        WriteDeploymentReport writer = new WriteDeploymentReport();
        DeploymentConfig memory config = _config();
        uint64 firstNonce = uint64(vm.getNonce(address(deployer)));
        CoreDeployment memory core = deployer.deployCore(config, firstNonce);
        _writeMatchingConfig(config, address(deployer), firstNonce);

        writer.writeCoreReport(
            REPORT_PATH,
            CONFIG_PATH,
            abi.encode(
                CoreReportInput({config: config, core: core, deployer: address(deployer), firstCreateNonce: firstNonce})
            )
        );

        string memory json = vm.readFile(_repositoryPath(REPORT_PATH));
        assertEq(vm.parseJsonAddress(json, ".registries.adapter.roles.defaultAdmin.account"), ADMIN);
        assertEq(vm.parseJsonAddress(json, ".registries.adapter.roles.governance.account"), GOVERNANCE);
        assertEq(vm.parseJsonAddress(json, ".registries.adapter.roles.upgrader.account"), UPGRADER);
        assertEq(vm.parseJsonAddress(json, ".dvp.roles.defaultAdmin.account"), ADMIN);
        assertEq(vm.parseJsonAddress(json, ".dvp.roles.governance.account"), GOVERNANCE);
        address currentStateValidator = vm.parseJsonAddress(json, ".dvp.validators.currentState.address");
        address expectedCurrentStateValidator = vm.computeCreateAddress(core.currentStateValidatorFactory, 3);
        assertEq(currentStateValidator, expectedCurrentStateValidator);
        assertNotEq(currentStateValidator, vm.computeCreateAddress(core.currentStateValidatorFactory, 1));
        assertNotEq(currentStateValidator, vm.computeCreateAddress(core.currentStateValidatorFactory, 2));
        assertEq(
            vm.parseJsonBytes32(json, ".dvp.validators.currentState.codeHash"), expectedCurrentStateValidator.codehash
        );
        assertTrue(vm.parseJsonBool(json, ".dvp.validators.currentState.verified"));
        assertTrue(vm.parseJsonBool(json, ".metadata.governanceReady"));
        assertTrue(vm.parseJsonBool(json, ".verification.governanceReady"));
        assertFalse(_contains(bytes(json), bytes("\"timelock\"")));
        assertFalse(_contains(bytes(json), bytes("\"governanceStatus\"")));
        assertFalse(_contains(bytes(json), bytes("HANDOFF")));

        vm.removeFile(_repositoryPath(REPORT_PATH));
        vm.removeFile(_repositoryPath(CONFIG_PATH));
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

    function _writeMatchingConfig(DeploymentConfig memory config, address deployer, uint64 firstNonce) private {
        string memory path = _repositoryPath(CONFIG_PATH);
        vm.writeFile(path, vm.readFile(_repositoryPath(SOURCE_CONFIG_PATH)));
        vm.writeJson(_quote(string(config.deploymentVersion)), path, ".deploymentVersion");
        vm.writeJson(vm.toString(uint256(firstNonce)), path, ".expectedFirstCreateNonce");
        vm.writeJson(vm.toString(config.chainId), path, ".network.chainId");
        vm.writeJson(_quote(vm.toString(deployer)), path, ".roles.deployer");
        vm.writeJson(_quote(vm.toString(config.roles.defaultAdmin)), path, ".roles.defaultAdmin");
        vm.writeJson(_quote(vm.toString(config.roles.governance)), path, ".roles.governance");
        vm.writeJson(_quote(vm.toString(config.roles.upgrader)), path, ".roles.upgrader");
        vm.writeJson(_quote(vm.toString(config.roles.pauser)), path, ".roles.pauser");
        vm.writeJson(_quote(vm.toString(config.roles.executor)), path, ".roles.executor");
        vm.writeJson(_quote(vm.toString(config.roles.configurer)), path, ".roles.configurer");
    }

    function _repositoryPath(string memory relative) private view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../", relative);
    }

    function _quote(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
