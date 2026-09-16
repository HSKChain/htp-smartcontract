// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DeployHTP} from "./DeployHTP.s.sol";
import {CoreDeployment, DeploymentConfig} from "./DeployTypes.sol";
import {RegisterDependentDvps} from "./RegisterDependentDvps.s.sol";
import {CoreReportInput, WriteDeploymentReport} from "./WriteDeploymentReport.s.sol";

/// @notice Deploys the core contracts from validated JSON and writes the core
/// deployment report after broadcast mode has stopped.
/// @dev Example:
/// forge script script/DeployAndReport.s.sol:DeployAndReport \
///   --sig "runFromFile(string,string)" \
///   "deploy/config.example.json" "deploy/out/core-deployment.json" \
///   --rpc-url "$RPC_URL" --broadcast
///
/// DeployHTP and WriteDeploymentReport are script-local contracts. Their CREATEs
/// are outside startBroadcast, so only the 18 core CREATEs consume broadcaster
/// nonces. Trusted configuration details can later be appended to the same file.
contract DeployAndReport is Script {
    error InvalidPath(bytes32 pathHash);
    error InvalidProjectRoot(bytes32 pathHash);

    function runFromFile(string calldata configPath, string calldata reportPath)
        external
        returns (CoreDeployment memory deployment)
    {
        _validatePath(configPath, bytes("deploy/"));
        _validatePath(reportPath, bytes("deploy/out/"));

        DeployHTP deployer = new DeployHTP();
        string memory absoluteConfigPath = _repositoryPath(configPath);
        (DeploymentConfig memory config, address broadcastDeployer, uint64 firstCreateNonce) =
            deployer.readConfigFile(absoluteConfigPath);

        deployment = deployer.runFromFile(absoluteConfigPath);

        // DeployHTP has already called stopBroadcast. Creating and invoking the
        // writer here cannot consume a broadcaster nonce.
        WriteDeploymentReport writer = new WriteDeploymentReport();
        writer.writeCoreReport(
            reportPath,
            configPath,
            abi.encode(
                CoreReportInput({
                    config: config, core: deployment, deployer: broadcastDeployer, firstCreateNonce: firstCreateNonce
                })
            )
        );
        _reportUpgradeGateStatus(deployment);
    }

    /// @dev 把「升级门禁是否就位」作为部署收尾的显式结论输出，而不是留给人去记。
    /// 部署者不持有 GOVERNANCE，所以这里只能报告状态、不能代为登记。
    function _reportUpgradeGateStatus(CoreDeployment memory deployment) private {
        address[] memory pending = new RegisterDependentDvps().pendingRegistrations(deployment);
        if (pending.length == 0) {
            console2.log(unicode"升级门禁：八个 Registry 均已登记依赖 DvP，无待办。");
            return;
        }
        console2.log(unicode"升级门禁：待登记 Registry 数量 =", pending.length);
        for (uint256 i = 0; i < pending.length; ++i) {
            console2.log(unicode"  待登记:", pending[i]);
        }
        console2.log(unicode"在 GOVERNANCE 跑完 RegisterDependentDvps 之前，这些 Registry 不可升级。");
    }

    function _validatePath(string memory path, bytes memory prefix) private pure {
        bytes memory value = bytes(path);
        if (value.length <= prefix.length + 5 || !_hasPrefix(value, prefix) || !_hasJsonSuffix(value)) {
            revert InvalidPath(keccak256(value));
        }
        for (uint256 i = 0; i < value.length; ++i) {
            if (!_isSafePathCharacter(value[i])) revert InvalidPath(keccak256(value));
            if (i + 1 < value.length && value[i] == bytes1(".") && value[i + 1] == bytes1(".")) {
                revert InvalidPath(keccak256(value));
            }
        }
    }

    function _hasPrefix(bytes memory value, bytes memory prefix) private pure returns (bool) {
        for (uint256 i = 0; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) return false;
        }
        return true;
    }

    function _hasJsonSuffix(bytes memory value) private pure returns (bool) {
        uint256 length = value.length;
        return value[length - 5] == bytes1(".") && value[length - 4] == bytes1("j") && value[length - 3] == bytes1("s")
            && value[length - 2] == bytes1("o") && value[length - 1] == bytes1("n");
    }

    function _isSafePathCharacter(bytes1 character) private pure returns (bool) {
        return (character >= bytes1("a") && character <= bytes1("z"))
            || (character >= bytes1("A") && character <= bytes1("Z"))
            || (character >= bytes1("0") && character <= bytes1("9")) || character == bytes1("/")
            || character == bytes1(".") || character == bytes1("-") || character == bytes1("_");
    }

    function _repositoryPath(string memory relativePath) private view returns (string memory) {
        bytes memory contractsRoot = bytes(vm.projectRoot());
        bytes memory suffix = bytes("/contracts");
        if (contractsRoot.length <= suffix.length) revert InvalidProjectRoot(keccak256(contractsRoot));
        uint256 repositoryRootLength = contractsRoot.length - suffix.length;
        for (uint256 i = 0; i < suffix.length; ++i) {
            if (contractsRoot[repositoryRootLength + i] != suffix[i]) {
                revert InvalidProjectRoot(keccak256(contractsRoot));
            }
        }
        bytes memory repositoryPath = new bytes(repositoryRootLength + 1 + bytes(relativePath).length);
        for (uint256 i = 0; i < repositoryRootLength; ++i) {
            repositoryPath[i] = contractsRoot[i];
        }
        repositoryPath[repositoryRootLength] = bytes1("/");
        bytes memory relative = bytes(relativePath);
        for (uint256 i = 0; i < relative.length; ++i) {
            repositoryPath[repositoryRootLength + 1 + i] = relative[i];
        }
        return string(repositoryPath);
    }
}
