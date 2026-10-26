// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CoreDeploymentTopology} from "./CoreDeploymentTopology.sol";
import {
    CoreDeployment,
    DeploymentConfig,
    DeploymentRoles,
    ExampleAdapterInputs,
    ExampleImplementations
} from "./DeployTypes.sol";
import {ERC1404Adapter} from "../src/adapters/ERC1404Adapter.sol";
import {OndoGmTokenAdapter} from "../src/adapters/OndoGmTokenAdapter.sol";
import {UnrestrictedERC20Adapter} from "../src/adapters/UnrestrictedERC20Adapter.sol";
import {UsdyRestrictedAdapter} from "../src/adapters/UsdyRestrictedAdapter.sol";
import {BondPrincipalCalculator} from "../src/calculators/BondPrincipalCalculator.sol";
import {FundPrincipalCalculator} from "../src/calculators/FundPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "../src/calculators/StockPrincipalCalculator.sol";
import {ProtocolSecurityLimits} from "../src/libraries/ProtocolSecurityLimits.sol";

contract DeployHTP is Script, CoreDeploymentTopology {
    error CreateNoncePreflightFailed(address expected, address actual);
    error CreateNonceMismatch(address deployer, uint64 expected, uint64 actual);
    error CreateNoncePostflightMismatch(address deployer, uint64 expected, uint64 actual);
    error BroadcastNonceMismatch(address deployer, uint64 expected, uint64 actual);
    error DeploymentConfigFieldMissing(bytes32 field);
    error ExpectedCreateNonceOverflow(uint256 nonce);
    error InvalidConfigPath(bytes32 pathHash);
    error InvalidDeploymentChain(uint256 expected, uint256 actual);
    error InvalidDeploymentRole(address roleHolder);
    error InvalidFileDeploymentMode(bytes32 modeHash, bytes32 usageHash);

    event CoreDeployed(address indexed dvp, address indexed currentStateValidatorFactory);
    event ExampleImplementationsDeployed(
        address indexed unrestrictedAdapter,
        address indexed erc1404Adapter,
        address indexed usdyAdapter,
        address ondoGmAdapter
    );

    function deployCore(DeploymentConfig calldata config, uint64 expectedFirstCreateNonce)
        external
        returns (CoreDeployment memory deployment)
    {
        deployment = _deployCore(config, address(this), expectedFirstCreateNonce);
    }

    /// @notice Broadcast entrypoint for:
    /// forge script script/DeployHTP.s.sol:DeployHTP --sig
    /// "run(((address,address,address,address,address,address,address,address,address,address,address,address,address),bytes,uint256),address,uint64)"
    /// ...
    /// @dev expectedBroadcastDeployer must be the actual configured broadcaster.
    /// Its current CREATE nonce is checked before broadcast mode starts, so a
    /// stale expectation cannot enqueue or execute any deployment transaction.
    function run(DeploymentConfig calldata config, address expectedBroadcastDeployer, uint64 expectedFirstCreateNonce)
        external
        returns (CoreDeployment memory deployment)
    {
        deployment = _run(config, expectedBroadcastDeployer, expectedFirstCreateNonce);
    }

    /// @notice File-backed T352 -> T353 seam. The JSON must already have
    /// passed the Node schema validator and must remain LOCAL_TEST/LOCAL_ONLY.
    /// This function never reads environment variables or private keys.
    function runFromFile(string calldata configPath) external returns (CoreDeployment memory deployment) {
        (DeploymentConfig memory config, address expectedBroadcastDeployer, uint64 expectedFirstCreateNonce) =
            readConfigFile(configPath);
        deployment = _run(config, expectedBroadcastDeployer, expectedFirstCreateNonce);
    }

    function readConfigFile(string memory configPath)
        public
        view
        returns (DeploymentConfig memory config, address expectedBroadcastDeployer, uint64 expectedFirstCreateNonce)
    {
        _validateConfigPath(configPath);
        string memory json = vm.readFile(configPath);
        _requireJsonField(json, ".mode");
        _requireJsonField(json, ".usage");
        string memory mode = vm.parseJsonString(json, ".mode");
        string memory usage = vm.parseJsonString(json, ".usage");
        bytes32 modeHash = keccak256(bytes(mode));
        bytes32 usageHash = keccak256(bytes(usage));
        if (modeHash != keccak256("LOCAL_TEST") || usageHash != keccak256("LOCAL_ONLY")) {
            revert InvalidFileDeploymentMode(modeHash, usageHash);
        }

        _requireFileDeploymentFields(json);
        config.deploymentVersion = bytes(vm.parseJsonString(json, ".deploymentVersion"));
        config.chainId = vm.parseJsonUint(json, ".network.chainId");

        expectedBroadcastDeployer = vm.parseJsonAddress(json, ".roles.deployer");
        config.roles = DeploymentRoles({
            defaultAdmin: vm.parseJsonAddress(json, ".roles.defaultAdmin"),
            governance: vm.parseJsonAddress(json, ".roles.governance"),
            upgrader: vm.parseJsonAddress(json, ".roles.upgrader"),
            pauser: vm.parseJsonAddress(json, ".roles.pauser"),
            executor: vm.parseJsonAddress(json, ".roles.executor"),
            configurer: vm.parseJsonAddress(json, ".roles.configurer")
        });

        uint256 nonce = vm.parseJsonUint(json, ".expectedFirstCreateNonce");
        if (nonce > type(uint64).max) revert ExpectedCreateNonceOverflow(nonce);
        expectedFirstCreateNonce = uint64(nonce);

        _validateConfig(config);
        _validateCreateDeployer(expectedBroadcastDeployer);
        _validateExpectedNonceRange(expectedFirstCreateNonce);
    }

    function _run(DeploymentConfig memory config, address expectedBroadcastDeployer, uint64 expectedFirstCreateNonce)
        private
        returns (CoreDeployment memory deployment)
    {
        _validateConfig(config);
        _validateCreateDeployer(expectedBroadcastDeployer);
        _validateExpectedNonceRange(expectedFirstCreateNonce);
        uint64 actualNonce = uint64(vm.getNonce(expectedBroadcastDeployer));
        if (actualNonce != expectedFirstCreateNonce) {
            revert BroadcastNonceMismatch(expectedBroadcastDeployer, expectedFirstCreateNonce, actualNonce);
        }
        vm.startBroadcast(expectedBroadcastDeployer);
        deployment = _deployCore(config, expectedBroadcastDeployer, expectedFirstCreateNonce);
        vm.stopBroadcast();
    }

    function _deployCore(DeploymentConfig memory config, address createDeployer, uint64 expectedFirstCreateNonce)
        private
        returns (CoreDeployment memory deployment)
    {
        _validateConfig(config);
        _validateCreateDeployer(createDeployer);
        _validateExpectedNonceRange(expectedFirstCreateNonce);

        uint64 actualFirstCreateNonce = uint64(vm.getNonce(createDeployer));
        if (actualFirstCreateNonce != expectedFirstCreateNonce) {
            revert CreateNonceMismatch(createDeployer, expectedFirstCreateNonce, actualFirstCreateNonce);
        }

        address predictedFirstCreate = _computeCreateAddress(createDeployer, expectedFirstCreateNonce);
        address predictedDvp = _predictDvpAddress(createDeployer, expectedFirstCreateNonce);
        deployment = _deployCoreTopology(config, predictedDvp);
        if (deployment.adapterRegistry.implementation != predictedFirstCreate) {
            revert CreateNoncePreflightFailed(predictedFirstCreate, deployment.adapterRegistry.implementation);
        }

        uint64 expectedFinalNonce = expectedFirstCreateNonce + TOTAL_CORE_CREATES;
        uint64 actualFinalNonce = uint64(vm.getNonce(createDeployer));
        if (actualFinalNonce != expectedFinalNonce) {
            revert CreateNoncePostflightMismatch(createDeployer, expectedFinalNonce, actualFinalNonce);
        }

        emit CoreDeployed(deployment.dvp, deployment.currentStateValidatorFactory);
        _logUpgradeGatePending(deployment.dvp);
    }

    /// @dev 部署者不持有 GOVERNANCE，因此八笔 registerDependentDvp 无法并入本次广播。
    /// 在它们完成之前，八个 Registry 的升级门禁会以 NoDependentDvpRegistered 拒绝一切升级。
    /// 这是 fail-closed 的安全状态，但也意味着系统尚未具备热修复能力，必须显式收口。
    function _logUpgradeGatePending(address dvp) private pure {
        console2.log(unicode"");
        console2.log(unicode"=== 部署完成，但升级门禁尚未就位 ===");
        console2.log(unicode"八个 Registry 的依赖 DvP 集合当前为空，upgradeToAndCall 会一律 revert。");
        console2.log(unicode"下一步须由 GOVERNANCE 执行（脚本幂等，可安全重跑）：");
        console2.log(unicode"  forge script script/RegisterDependentDvps.s.sol:RegisterDependentDvps --broadcast");
        console2.log(unicode"待登记的 DvP:", dvp);
    }

    function predictDvpAddress(address createDeployer, uint64 expectedFirstCreateNonce)
        external
        pure
        returns (address)
    {
        return _predictDvpAddress(createDeployer, expectedFirstCreateNonce);
    }

    function deployExampleImplementations(address dvp, ExampleAdapterInputs calldata inputs)
        external
        returns (ExampleImplementations memory implementations)
    {
        implementations = _deployExampleImplementations(dvp, inputs);
    }

    function runExampleImplementations(address dvp, ExampleAdapterInputs calldata inputs)
        external
        returns (ExampleImplementations memory implementations)
    {
        vm.startBroadcast();
        implementations = _deployExampleImplementations(dvp, inputs);
        vm.stopBroadcast();
    }

    function _deployExampleImplementations(address dvp, ExampleAdapterInputs calldata inputs)
        private
        returns (ExampleImplementations memory implementations)
    {
        if (
            dvp.code.length == 0 || inputs.erc1404Token.code.length == 0 || inputs.usdyToken.code.length == 0
                || inputs.usdyBlocklist.code.length == 0 || inputs.usdyAllowlist.code.length == 0
                || inputs.usdySanctionsList.code.length == 0 || inputs.gmToken.code.length == 0
        ) {
            revert InvalidDeploymentRole(address(0));
        }
        ProtocolSecurityLimits.requireValidAdapterProviderCallGas(inputs.providerCallGas);
        implementations.stockCalculator = address(new StockPrincipalCalculator());
        implementations.fundCalculator = address(new FundPrincipalCalculator());
        implementations.bondCalculator = address(new BondPrincipalCalculator());
        implementations.unrestrictedAdapter = address(new UnrestrictedERC20Adapter(dvp));
        implementations.erc1404Adapter =
            address(new ERC1404Adapter(dvp, inputs.erc1404Token, inputs.erc1404Token.codehash, inputs.providerCallGas));
        implementations.usdyAdapter = address(
            new UsdyRestrictedAdapter(
                dvp,
                inputs.usdyToken,
                inputs.usdyToken.codehash,
                inputs.usdyBlocklist,
                inputs.usdyBlocklist.codehash,
                inputs.usdyAllowlist,
                inputs.usdyAllowlist.codehash,
                inputs.usdySanctionsList,
                inputs.usdySanctionsList.codehash,
                inputs.providerCallGas
            )
        );
        implementations.ondoGmAdapter =
            address(new OndoGmTokenAdapter(dvp, inputs.gmToken, inputs.gmToken.codehash, inputs.providerCallGas));
        emit ExampleImplementationsDeployed(
            implementations.unrestrictedAdapter,
            implementations.erc1404Adapter,
            implementations.usdyAdapter,
            implementations.ondoGmAdapter
        );
    }

    function _validateConfig(DeploymentConfig memory config) private view {
        if (config.chainId != block.chainid) {
            revert InvalidDeploymentChain(config.chainId, block.chainid);
        }
        DeploymentRoles memory roles = config.roles;
        address[6] memory holders =
            [roles.defaultAdmin, roles.governance, roles.upgrader, roles.pauser, roles.executor, roles.configurer];
        for (uint256 i = 0; i < holders.length; ++i) {
            if (holders[i] == address(0)) revert InvalidDeploymentRole(holders[i]);
        }
    }

    function _validateCreateDeployer(address createDeployer) private pure {
        if (createDeployer == address(0)) revert InvalidDeploymentRole(createDeployer);
    }

    function _requireFileDeploymentFields(string memory json) private view {
        _requireJsonField(json, ".deploymentVersion");
        _requireJsonField(json, ".expectedFirstCreateNonce");
        _requireJsonField(json, ".network.chainId");
        _requireJsonField(json, ".roles.deployer");
        _requireJsonField(json, ".roles.defaultAdmin");
        _requireJsonField(json, ".roles.governance");
        _requireJsonField(json, ".roles.upgrader");
        _requireJsonField(json, ".roles.pauser");
        _requireJsonField(json, ".roles.executor");
        _requireJsonField(json, ".roles.configurer");
    }

    function _validateExpectedNonceRange(uint64 expectedFirstCreateNonce) private pure {
        if (expectedFirstCreateNonce > type(uint64).max - TOTAL_CORE_CREATES) {
            revert ExpectedCreateNonceOverflow(expectedFirstCreateNonce);
        }
    }

    function _requireJsonField(string memory json, string memory key) private view {
        if (!vm.keyExistsJson(json, key)) revert DeploymentConfigFieldMissing(keccak256(bytes(key)));
    }

    function _validateConfigPath(string memory configPath) private pure {
        bytes memory path = bytes(configPath);
        if (
            path.length < 6 || path[path.length - 5] != bytes1(".") || path[path.length - 4] != bytes1("j")
                || path[path.length - 3] != bytes1("s") || path[path.length - 2] != bytes1("o")
                || path[path.length - 1] != bytes1("n")
        ) {
            revert InvalidConfigPath(keccak256(path));
        }
        for (uint256 i = 0; i < path.length; ++i) {
            if (path[i] == bytes1(0)) revert InvalidConfigPath(keccak256(path));
            if (i + 1 < path.length && path[i] == bytes1(".") && path[i + 1] == bytes1(".")) {
                revert InvalidConfigPath(keccak256(path));
            }
            if (
                i + 3 < path.length && path[i] == bytes1(".") && path[i + 1] == bytes1("e")
                    && path[i + 2] == bytes1("n") && path[i + 3] == bytes1("v")
            ) {
                revert InvalidConfigPath(keccak256(path));
            }
        }
    }
}
