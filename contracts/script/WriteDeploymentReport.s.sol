// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script} from "forge-std/Script.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, ExampleConfigs, RegistryDeployment} from "./DeployTypes.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "../src/interfaces/IAssetVersionRegistry.sol";
import {IDvPSettlement} from "../src/interfaces/IDvPSettlement.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {IFeeRegistry} from "../src/interfaces/IFeeRegistry.sol";
import {IMarketRuleRegistry} from "../src/interfaces/IMarketRuleRegistry.sol";
import {IParticipantRegistry} from "../src/interfaces/IParticipantRegistry.sol";
import {IPrincipalCalculatorRegistry} from "../src/interfaces/IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "../src/interfaces/ISettlementTokenRegistry.sol";
import {DeploymentVersion} from "../src/libraries/DeploymentVersion.sol";
import {HTPHashing} from "../src/libraries/HTPHashing.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {
    AdapterRecord,
    AssetVersionRecord,
    Decision,
    EligibilityRecord,
    FeePolicyEpochRecord,
    FeeVersionRecord,
    MarketRuleRecord,
    ParticipantRecord,
    PrincipalCalculatorRecord,
    SettlementTokenRecord
} from "../src/types/HTPTypes.sol";

interface IDeploymentReportRegistry is IAccessControl {
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
}

enum ConfigurationKind {
    CALCULATOR,
    ADAPTER,
    SETTLEMENT_TOKEN,
    ASSET_VERSION,
    FEE_POLICY_EPOCH,
    FEE_VERSION,
    PARTICIPANT,
    ELIGIBILITY,
    MARKET_RULE
}

/// @notice A non-sensitive, normalized configuration-graph report row.
/// @dev IDs and hashes may be zero for record types that do not define them.
/// `verificationPassed` is the result of the corresponding public verifier.
struct ConfigurationReportEntry {
    ConfigurationKind kind;
    bytes32 id;
    bytes32 configHash;
    uint256 statusCode;
    address subject;
    bytes32 subjectCodeHash;
    address dependentDvp;
    address collector;
    bool verificationPassed;
}

struct DvpReportFacts {
    address signedPayloadValidator;
    address currentStateValidator;
    bool defaultAdminValid;
    bool governanceValid;
    bool pauserValid;
    bool executorValid;
    bool registryBindingsValid;
    bool versionHashValid;
    bool validatorsValid;
    bool factoryValid;
    bool overall;
}

struct RegistryReportFacts {
    bool implementationAddressValid;
    bool implementationCodeHashValid;
    bool proxyCodeHashValid;
    bool defaultAdminValid;
    bool governanceValid;
    bool upgraderValid;
    bool pauserValid;
    bool configurerValid;
    bool coreDvpRegistered;
    bool deploymentIntegrity;
    bool overall;
}

struct CoreReportInput {
    DeploymentConfig config;
    CoreDeployment core;
    address deployer;
    uint64 firstCreateNonce;
}

struct ReadinessFacts {
    bool deploymentIntegrity;
    bool dependentRegistrationComplete;
    bool governanceReady;
    bool configurationReady;
    bool operationalReady;
    bool productionApprovalPresent;
    bool productionReady;
}

struct ConfigSourceFacts {
    string mode;
    string usage;
    string approvalStatus;
    bool productionApprovalPresent;
}

struct ExampleConfigurationReportInput {
    CoreDeployment core;
    ExampleConfigs configs;
}

struct TrustedConfigurationEntry {
    ConfigurationKind kind;
    bytes32 id;
    bytes32 configHash;
    uint256 statusCode;
    address subject;
    bytes32 subjectCodeHash;
    address dependentDvp;
    address collector;
    bool current;
    bool idValid;
    bool configHashValid;
    bool statusValid;
    bool currentValid;
    bool codeHashValid;
    bool collectorValid;
    bool dependentDvpValid;
}

/// @notice Writes a read-only deployment report without private keys, signatures,
/// RPC credentials, raw transactions, or identity fields.
/// @dev Paths are repository-relative and restricted to deploy/*.json. A core
/// report contains an empty configuration array; appendConfigurationReport
/// replaces that array in the same JSON document after phased configuration.
contract WriteDeploymentReport is Script {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint64 private constant CURRENT_STATE_VALIDATOR_CREATE_NONCE = 3;

    error InvalidReportPath(bytes32 pathHash);
    error ConfigBindingMismatch(bytes32 field);

    function writeCoreReport(string calldata reportPath, string calldata configPath, bytes calldata encodedInput)
        external
    {
        _validateConfigPath(configPath);
        _validateReportPath(reportPath);
        CoreReportInput memory input = abi.decode(encodedInput, (CoreReportInput));
        vm.writeJson(_buildCoreReportJson(configPath, input), _repositoryPath(reportPath));
    }

    function _buildCoreReportJson(string memory configPath, CoreReportInput memory input)
        private
        view
        returns (string memory json)
    {
        string memory configContents = vm.readFile(_repositoryPath(configPath));
        _validateConfigBinding(configContents, input);
        ConfigSourceFacts memory source = _configSourceFacts(configContents);
        ReadinessFacts memory readiness = _readinessFacts(input, source.productionApprovalPresent);
        string memory registriesJson = _registriesJson(input.core, input.config);
        string memory dvpJson = _dvpJson(input.core, input.config, input.deployer);
        json = string.concat(
            '{"metadata":',
            _metadataJson(input, configPath, keccak256(bytes(configContents)), source, readiness),
            ',"registries":',
            registriesJson
        );
        json = string.concat(json, ',"dvp":', dvpJson, ',"configuration":[],"verification":');
        json = string.concat(json, _readinessJson(readiness, false, false), "}");
    }

    function _validateConfigBinding(string memory json, CoreReportInput memory input) private pure {
        _requireConfig(
            keccak256(bytes(vm.parseJsonString(json, ".deploymentVersion")))
                == keccak256(bytes(input.config.deploymentVersion)),
            "deploymentVersion"
        );
        _requireConfig(vm.parseJsonUint(json, ".network.chainId") == input.config.chainId, "chainId");
        _requireConfig(
            vm.parseJsonUint(json, ".expectedFirstCreateNonce") == uint256(input.firstCreateNonce),
            "expectedFirstCreateNonce"
        );
        _requireConfig(vm.parseJsonAddress(json, ".roles.deployer") == input.deployer, "roles.deployer");
        _validateRoleBinding(json, input.config.roles);
    }

    function _validateRoleBinding(string memory json, DeploymentRoles memory roles) private pure {
        _requireConfig(vm.parseJsonAddress(json, ".roles.defaultAdmin") == roles.defaultAdmin, "roles.defaultAdmin");
        _requireConfig(vm.parseJsonAddress(json, ".roles.governance") == roles.governance, "roles.governance");
        _requireConfig(vm.parseJsonAddress(json, ".roles.upgrader") == roles.upgrader, "roles.upgrader");
        _requireConfig(vm.parseJsonAddress(json, ".roles.pauser") == roles.pauser, "roles.pauser");
        _requireConfig(vm.parseJsonAddress(json, ".roles.executor") == roles.executor, "roles.executor");
        _requireConfig(vm.parseJsonAddress(json, ".roles.configurer") == roles.configurer, "roles.configurer");
    }

    function _requireConfig(bool condition, string memory field) private pure {
        if (!condition) revert ConfigBindingMismatch(keccak256(bytes(field)));
    }

    function _configSourceFacts(string memory json) private pure returns (ConfigSourceFacts memory source) {
        source.mode = vm.parseJsonString(json, ".mode");
        source.usage = vm.parseJsonString(json, ".usage");
        source.approvalStatus = vm.parseJsonString(json, ".externalPolicy.approvalStatus");
        source.productionApprovalPresent = _productionApprovalPresent(source.mode, source.usage, source.approvalStatus);
    }

    function _productionApprovalPresent(string memory mode, string memory usage, string memory approvalStatus)
        private
        pure
        returns (bool)
    {
        return keccak256(bytes(mode)) == keccak256("PRODUCTION")
            && keccak256(bytes(usage)) == keccak256("PRODUCTION_DEPLOYMENT")
            && keccak256(bytes(approvalStatus)) == keccak256("APPROVED");
    }

    function appendConfigurationReport(string calldata reportPath, bytes calldata encodedEntries) external {
        _validateReportPath(reportPath);
        ConfigurationReportEntry[] memory entries = abi.decode(encodedEntries, (ConfigurationReportEntry[]));
        string memory absolutePath = _repositoryPath(reportPath);
        string memory existing = vm.readFile(absolutePath);
        if (!vm.keyExistsJson(existing, ".configuration")) {
            revert InvalidReportPath(keccak256(bytes(reportPath)));
        }
        vm.writeJson(_configurationJson(entries), absolutePath, ".configuration");
        vm.writeJson("true", absolutePath, ".verification.configurationReportPresent");
        vm.writeJson("false", absolutePath, ".verification.configurationTrusted");
        vm.writeJson("false", absolutePath, ".verification.configurationReady");
        vm.writeJson("false", absolutePath, ".verification.operationalReady");
        vm.writeJson("false", absolutePath, ".verification.productionReady");
    }

    function appendExampleConfigurationReport(string calldata reportPath, bytes calldata encodedInput) external {
        _validateReportPath(reportPath);
        ExampleConfigurationReportInput memory input = abi.decode(encodedInput, (ExampleConfigurationReportInput));
        string memory absolutePath = _repositoryPath(reportPath);
        string memory existing = vm.readFile(absolutePath);
        if (!vm.keyExistsJson(existing, ".configuration")) {
            revert InvalidReportPath(keccak256(bytes(reportPath)));
        }
        if (vm.parseJsonAddress(existing, ".dvp.address") != input.core.dvp) {
            revert InvalidReportPath(keccak256(bytes(reportPath)));
        }
        (string memory configurationJson, bool configurationReady) =
            _exampleConfigurationJson(input.core, input.configs);
        bool operationalReady = vm.parseJsonBool(existing, ".verification.deploymentIntegrity")
            && vm.parseJsonBool(existing, ".verification.dependentRegistrationComplete")
            && vm.parseJsonBool(existing, ".verification.governanceReady") && configurationReady;
        bool productionApprovalPresent = _productionApprovalPresent(
            vm.parseJsonString(existing, ".metadata.mode"),
            vm.parseJsonString(existing, ".metadata.usage"),
            vm.parseJsonString(existing, ".metadata.productionApprovalStatus")
        );
        bool productionReady = operationalReady && productionApprovalPresent;
        vm.writeJson(configurationJson, absolutePath, ".configuration");
        vm.writeJson("true", absolutePath, ".verification.configurationReportPresent");
        vm.writeJson("true", absolutePath, ".verification.configurationTrusted");
        vm.writeJson(_bool(configurationReady), absolutePath, ".verification.configurationReady");
        vm.writeJson(_bool(operationalReady), absolutePath, ".verification.operationalReady");
        vm.writeJson(_bool(productionApprovalPresent), absolutePath, ".verification.productionApprovalPresent");
        vm.writeJson(_bool(productionReady), absolutePath, ".verification.productionReady");
    }

    function _metadataJson(
        CoreReportInput memory input,
        string memory configPath,
        bytes32 configContentHash,
        ConfigSourceFacts memory source,
        ReadinessFacts memory readiness
    ) private view returns (string memory json) {
        json = string.concat(
            "{",
            _metadataIdentityFields(input.config, configPath, configContentHash, input.deployer),
            ',"mode":"',
            source.mode
        );
        json = string.concat(
            json,
            '","usage":"',
            source.usage,
            '","productionApprovalStatus":"',
            source.approvalStatus,
            '","productionApprovalPresent":',
            _bool(source.productionApprovalPresent),
            ',"createNonceRange":',
            _nonceRangeJson(input.firstCreateNonce)
        );
        json = string.concat(
            json,
            ',"blockNumber":',
            vm.toString(block.number),
            ',"governanceReady":',
            _bool(readiness.governanceReady),
            "}"
        );
    }

    function _metadataIdentityFields(
        DeploymentConfig memory config,
        string memory configPath,
        bytes32 configContentHash,
        address deployer
    ) private pure returns (string memory json) {
        bytes32 versionHash = DeploymentVersion.hash(config.deploymentVersion);
        json = string.concat(
            '"chainId":', vm.toString(config.chainId), ',"deploymentVersion":"', string(config.deploymentVersion)
        );
        json = string.concat(json, '","deploymentVersionHash":"', vm.toString(versionHash), '","configPath":"');
        json = string.concat(json, configPath, '","configPathHash":"', vm.toString(keccak256(bytes(configPath))));
        json = string.concat(json, '","configContentHash":"', vm.toString(configContentHash), '","deployer":"');
        json = string.concat(json, vm.toString(deployer), '"');
    }

    function _nonceRangeJson(uint64 firstCreateNonce) private pure returns (string memory json) {
        json = string.concat(
            '{"first":', vm.toString(uint256(firstCreateNonce)), ',"last":', vm.toString(uint256(firstCreateNonce) + 17)
        );
        json = string.concat(json, ',"finalExclusive":', vm.toString(uint256(firstCreateNonce) + 18), "}");
    }

    // 八个 Registry 的角色拓扑完全一致（同一 defaultAdmin/governance/upgrader/pauser/configurer），
    // 因此只按 JSON 键名区分，不再逐个透传角色参数。
    function _registriesJson(CoreDeployment memory core, DeploymentConfig memory config)
        private
        view
        returns (string memory json)
    {
        DeploymentRoles memory roles = config.roles;
        address dvp = core.dvp;
        json = string.concat('{"adapter":', _registryJson(core.adapterRegistry, roles, dvp));
        json = string.concat(json, ',"calculator":', _registryJson(core.calculatorRegistry, roles, dvp));
        json = string.concat(json, ',"settlementToken":', _registryJson(core.settlementTokenRegistry, roles, dvp));
        json = string.concat(json, ',"assetVersion":', _registryJson(core.assetVersionRegistry, roles, dvp));
        json = string.concat(json, ',"eligibility":', _registryJson(core.eligibilityRegistry, roles, dvp));
        json = string.concat(json, ',"fee":', _registryJson(core.feeRegistry, roles, dvp));
        json = string.concat(json, ',"marketRule":', _registryJson(core.marketRuleRegistry, roles, dvp));
        json = string.concat(json, ',"participant":', _registryJson(core.participantRegistry, roles, dvp), "}");
    }

    function _registryJson(RegistryDeployment memory deployment, DeploymentRoles memory roles, address dvp)
        private
        view
        returns (string memory)
    {
        IDeploymentReportRegistry registry = IDeploymentReportRegistry(deployment.proxy);
        RegistryReportFacts memory facts = _registryFacts(deployment, roles, dvp);
        string memory json = string.concat(
            '{"implementation":"', vm.toString(deployment.implementation), '","proxy":"', vm.toString(deployment.proxy)
        );
        json = string.concat(
            json, '","implementationCodeHash":"', vm.toString(deployment.implementation.codehash), '","proxyCodeHash":"'
        );
        json = string.concat(json, vm.toString(deployment.proxy.codehash), '","roles":');
        json = string.concat(json, _registryRolesJson(roles, facts), ',"dependentDvps":', _dependentDvpsJson(registry));
        json = string.concat(json, ',"coreDvpRegistered":', _bool(facts.coreDvpRegistered), ',"verification":');
        json = string.concat(json, _registryVerificationJson(facts), "}");
        return json;
    }

    function _registryFacts(RegistryDeployment memory deployment, DeploymentRoles memory roles, address dvp)
        private
        view
        returns (RegistryReportFacts memory facts)
    {
        IDeploymentReportRegistry registry = IDeploymentReportRegistry(deployment.proxy);
        facts.implementationAddressValid = _slotImplementation(deployment.proxy) == deployment.implementation;
        facts.implementationCodeHashValid = deployment.implementation.codehash == deployment.implementationCodeHash
            && deployment.implementation.code.length != 0;
        facts.proxyCodeHashValid = deployment.proxy.code.length != 0;
        facts.defaultAdminValid = registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin);
        facts.governanceValid = registry.hasRole(Roles.GOVERNANCE_ROLE, roles.governance);
        facts.upgraderValid = registry.hasRole(Roles.UPGRADER_ROLE, roles.upgrader);
        facts.pauserValid = registry.hasRole(Roles.PAUSER_ROLE, roles.pauser);
        facts.configurerValid = registry.hasRole(Roles.CONFIGURER_ROLE, roles.configurer);
        facts.coreDvpRegistered = _containsDependentDvp(registry, dvp);
        facts.deploymentIntegrity = facts.implementationAddressValid && facts.implementationCodeHashValid
            && facts.proxyCodeHashValid && facts.defaultAdminValid && facts.governanceValid && facts.upgraderValid
            && facts.pauserValid && facts.configurerValid;
        facts.overall = facts.deploymentIntegrity && facts.coreDvpRegistered;
    }

    function _registryRolesJson(DeploymentRoles memory roles, RegistryReportFacts memory facts)
        private
        pure
        returns (string memory json)
    {
        json = string.concat(
            '{"defaultAdmin":{"account":"',
            vm.toString(roles.defaultAdmin),
            '","verified":',
            _bool(facts.defaultAdminValid)
        );
        json = string.concat(json, '},"governance":{"account":"', vm.toString(roles.governance), '","verified":');
        json = string.concat(json, _bool(facts.governanceValid), '},"upgrader":{"account":"');
        json = string.concat(json, vm.toString(roles.upgrader), '","verified":', _bool(facts.upgraderValid));
        json = string.concat(json, '},"pauser":{"account":"', vm.toString(roles.pauser), '","verified":');
        json =
            string.concat(json, _bool(facts.pauserValid), '},"configurer":{"account":"', vm.toString(roles.configurer));
        json = string.concat(json, '","role":"', vm.toString(Roles.CONFIGURER_ROLE), '","verified":');
        json = string.concat(json, _bool(facts.configurerValid), "}}");
    }

    function _registryVerificationJson(RegistryReportFacts memory facts) private pure returns (string memory json) {
        json = string.concat(
            '{"implementationAddress":',
            _bool(facts.implementationAddressValid),
            ',"implementationCodeHash":',
            _bool(facts.implementationCodeHashValid)
        );
        json = string.concat(json, ',"proxyCodeHash":', _bool(facts.proxyCodeHashValid), ',"defaultAdmin":');
        json = string.concat(json, _bool(facts.defaultAdminValid), ',"governance":', _bool(facts.governanceValid));
        json = string.concat(json, ',"upgrader":', _bool(facts.upgraderValid), ',"pauser":');
        json = string.concat(json, _bool(facts.pauserValid), ',"configurer":', _bool(facts.configurerValid));
        json = string.concat(json, ',"deploymentIntegrity":', _bool(facts.deploymentIntegrity));
        json = string.concat(
            json,
            ',"dependentRegistrationComplete":',
            _bool(facts.coreDvpRegistered),
            ',"overall":',
            _bool(facts.overall),
            "}"
        );
    }

    function _dvpJson(CoreDeployment memory core, DeploymentConfig memory config, address deployer)
        private
        view
        returns (string memory json)
    {
        DvpReportFacts memory facts = _dvpFacts(core, config, deployer);
        json = string.concat('{"address":"', vm.toString(core.dvp), '","codeHash":"', vm.toString(core.dvp.codehash));
        json = string.concat(
            json,
            '","deploymentVersionHash":"',
            vm.toString(IDvPSettlement(core.dvp).deploymentVersionHash()),
            '","roles":'
        );
        json = string.concat(json, _dvpRolesJson(config, deployer, facts), ',"registries":');
        json = string.concat(
            json, _dvpRegistriesJson(core, facts.registryBindingsValid), ',"currentStateValidatorFactory":'
        );
        json = string.concat(
            json,
            _currentStateValidatorFactoryJson(core.currentStateValidatorFactory, facts.factoryValid),
            ',"validators":'
        );
        json = string.concat(json, _validatorsJson(facts), ',"verification":');
        json = string.concat(json, _dvpVerificationJson(core, facts), "}");
    }

    function _dvpFacts(CoreDeployment memory core, DeploymentConfig memory config, address)
        private
        view
        returns (DvpReportFacts memory facts)
    {
        facts.signedPayloadValidator = _computeCreateAddress(core.dvp, 1);
        facts.currentStateValidator =
            _computeCreateAddress(core.currentStateValidatorFactory, CURRENT_STATE_VALIDATOR_CREATE_NONCE);
        facts.defaultAdminValid = IAccessControl(core.dvp).hasRole(Roles.DEFAULT_ADMIN_ROLE, config.roles.defaultAdmin);
        facts.governanceValid = IAccessControl(core.dvp).hasRole(Roles.GOVERNANCE_ROLE, config.roles.governance);
        facts.pauserValid = IAccessControl(core.dvp).hasRole(Roles.PAUSER_ROLE, config.roles.pauser);
        facts.executorValid = IAccessControl(core.dvp).hasRole(Roles.EXECUTOR_ROLE, config.roles.executor);
        facts.registryBindingsValid = _dvpRegistryBindings(core);
        facts.versionHashValid =
            IDvPSettlement(core.dvp).deploymentVersionHash() == DeploymentVersion.hash(config.deploymentVersion);
        facts.validatorsValid =
            facts.signedPayloadValidator.code.length != 0 && facts.currentStateValidator.code.length != 0;
        facts.factoryValid = core.currentStateValidatorFactory.code.length != 0;
        facts.overall = core.dvp.code.length != 0 && facts.defaultAdminValid && facts.governanceValid
            && facts.pauserValid && facts.executorValid && facts.registryBindingsValid && facts.versionHashValid
            && facts.validatorsValid && facts.factoryValid;
    }

    function _dvpRolesJson(DeploymentConfig memory config, address, DvpReportFacts memory facts)
        private
        pure
        returns (string memory json)
    {
        json = string.concat(
            '{"defaultAdmin":{"account":"',
            vm.toString(config.roles.defaultAdmin),
            '","verified":',
            _bool(facts.defaultAdminValid)
        );
        json = string.concat(json, '},"governance":{"account":"', vm.toString(config.roles.governance), '","verified":');
        json = string.concat(json, _bool(facts.governanceValid), '},"pauser":{"account":"');
        json = string.concat(json, vm.toString(config.roles.pauser), '","verified":', _bool(facts.pauserValid));
        json = string.concat(json, '},"executor":{"account":"', vm.toString(config.roles.executor), '","verified":');
        json = string.concat(json, _bool(facts.executorValid), "}}");
    }

    function _dvpRegistriesJson(CoreDeployment memory core, bool verified) private view returns (string memory json) {
        IDvPSettlement dvp = IDvPSettlement(core.dvp);
        json = string.concat(
            '{"adapter":"',
            vm.toString(address(dvp.adapterRegistry())),
            '","calculator":"',
            vm.toString(address(dvp.principalCalculatorRegistry()))
        );
        json = string.concat(
            json, '","settlementToken":"', vm.toString(address(dvp.settlementTokenRegistry())), '","assetVersion":"'
        );
        json = string.concat(json, vm.toString(address(dvp.assetVersionRegistry())), '","eligibility":"');
        json = string.concat(json, vm.toString(address(dvp.eligibilityRegistry())), '","fee":"');
        json = string.concat(json, vm.toString(address(dvp.feeRegistry())), '","marketRule":"');
        json = string.concat(json, vm.toString(address(dvp.marketRuleRegistry())), '","participant":"');
        json =
            string.concat(json, vm.toString(address(dvp.participantRegistry())), '","verified":', _bool(verified), "}");
    }

    function _currentStateValidatorFactoryJson(address currentStateValidatorFactory, bool verified)
        private
        view
        returns (string memory json)
    {
        json = string.concat(
            '{"address":"',
            vm.toString(currentStateValidatorFactory),
            '","codeHash":"',
            vm.toString(currentStateValidatorFactory.codehash)
        );
        json = string.concat(json, '","verified":', _bool(verified), "}");
    }

    function _validatorsJson(DvpReportFacts memory facts) private view returns (string memory json) {
        json = string.concat(
            '{"signedPayload":{"address":"',
            vm.toString(facts.signedPayloadValidator),
            '","codeHash":"',
            vm.toString(facts.signedPayloadValidator.codehash)
        );
        json = string.concat(json, '","verified":', _bool(facts.signedPayloadValidator.code.length != 0));
        json = string.concat(
            json, '},"currentState":{"address":"', vm.toString(facts.currentStateValidator), '","codeHash":"'
        );
        json = string.concat(json, vm.toString(facts.currentStateValidator.codehash), '","verified":');
        json = string.concat(json, _bool(facts.currentStateValidator.code.length != 0), "}}");
    }

    function _dvpVerificationJson(CoreDeployment memory core, DvpReportFacts memory facts)
        private
        view
        returns (string memory json)
    {
        json = string.concat(
            '{"codeHash":', _bool(core.dvp.code.length != 0), ',"deploymentVersionHash":', _bool(facts.versionHashValid)
        );
        json = string.concat(json, ',"defaultAdmin":', _bool(facts.defaultAdminValid), ',"governance":');
        json = string.concat(json, _bool(facts.governanceValid), ',"pauser":', _bool(facts.pauserValid));
        json = string.concat(json, ',"executor":', _bool(facts.executorValid), ',"registryBindings":');
        json = string.concat(json, _bool(facts.registryBindingsValid), ',"validators":', _bool(facts.validatorsValid));
        json = string.concat(json, ',"overall":');
        json = string.concat(json, _bool(facts.overall), "}");
    }

    function _configurationJson(ConfigurationReportEntry[] memory entries) private view returns (string memory json) {
        json = "[";
        for (uint256 i = 0; i < entries.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, _configurationEntryJson(entries[i]));
        }
        json = string.concat(json, "]");
    }

    function _configurationEntryJson(ConfigurationReportEntry memory entry) private view returns (string memory json) {
        bool subjectCodeHash = entry.subject == address(0)
            ? entry.subjectCodeHash == bytes32(0)
            : entry.subject.codehash == entry.subjectCodeHash && entry.subject.code.length != 0;
        bool overall;
        json = string.concat('{"kind":"', _kind(entry.kind), '","id":"', vm.toString(entry.id));
        json = string.concat(json, '","configHash":"', vm.toString(entry.configHash), '","statusCode":');
        json = string.concat(
            json, vm.toString(entry.statusCode), ',"status":"', _statusLabel(entry.kind, entry.statusCode)
        );
        json = string.concat(json, '","subject":"', vm.toString(entry.subject));
        json = string.concat(json, '","subjectCodeHash":"', vm.toString(entry.subjectCodeHash), '","dependentDvp":"');
        json = string.concat(json, vm.toString(entry.dependentDvp), '","collector":"', vm.toString(entry.collector));
        json = string.concat(
            json,
            '","verification":{"untrustedReported":true,"reportedVerification":',
            _bool(entry.verificationPassed),
            ',"subjectCodeHash":'
        );
        json = string.concat(json, _bool(subjectCodeHash), ',"overall":', _bool(overall), "}}");
    }

    function _exampleConfigurationJson(CoreDeployment memory core, ExampleConfigs memory configs)
        internal
        view
        returns (string memory json, bool ready)
    {
        json = "[";
        ready = true;
        for (uint256 i = 0; i < 3; ++i) {
            (string memory entry, bool valid) = _calculatorEntry(core, configs, i);
            json = _appendJsonEntry(json, entry);
            if (!valid) ready = false;
        }
        for (uint256 i = 0; i < configs.adapters.length; ++i) {
            (string memory entry, bool valid) = _adapterEntry(core, configs, i);
            json = _appendJsonEntry(json, entry);
            if (!valid) ready = false;
        }
        (string memory settlementEntry, bool settlementValid) = _settlementTokenEntry(core, configs);
        json = _appendJsonEntry(json, settlementEntry);
        if (!settlementValid) ready = false;
        (string memory assetEntry, bool assetValid) = _assetVersionEntry(core, configs);
        json = _appendJsonEntry(json, assetEntry);
        if (!assetValid) ready = false;
        (json, ready) = _appendMarketRuleConfiguration(json, ready, core, configs);
        (string memory epochEntry, bool epochValid, string memory feeEntry, bool feeValid) = _feeEntries(core, configs);
        json = _appendJsonEntry(json, epochEntry);
        json = _appendJsonEntry(json, feeEntry);
        if (!epochValid || !feeValid) ready = false;
        for (uint256 i = 0; i < 2; ++i) {
            (string memory entry, bool valid) = _participantEntry(core, configs, i);
            json = _appendJsonEntry(json, entry);
            if (!valid) ready = false;
        }
        for (uint256 i = 0; i < 2; ++i) {
            (string memory entry, bool valid) = _eligibilityEntry(core, configs, i);
            json = _appendJsonEntry(json, entry);
            if (!valid) ready = false;
        }
        json = string.concat(json, "]");
    }

    function _calculatorEntry(CoreDeployment memory core, ExampleConfigs memory configs, uint256 index)
        private
        view
        returns (string memory json, bool valid)
    {
        IPrincipalCalculatorRegistry registry = IPrincipalCalculatorRegistry(core.calculatorRegistry.proxy);
        PrincipalCalculatorRecord memory record =
            registry.getPrincipalCalculator(configs.calculators[index].calculatorConfigId);
        PrincipalCalculatorRecord memory current = registry.getCurrentPrincipalCalculator(record.config.assetClass);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.CALCULATOR;
        entry.id = record.config.calculatorConfigId;
        entry.configHash = record.config.configHash;
        entry.statusCode = uint256(record.status);
        entry.subject = record.config.calculator;
        entry.subjectCodeHash = record.config.codeHash;
        entry.dependentDvp = core.dvp;
        entry.current = current.config.calculatorConfigId == entry.id;
        entry.idValid = record.exists && entry.id == configs.calculators[index].calculatorConfigId;
        entry.configHashValid = entry.configHash == configs.calculators[index].configHash
            && entry.configHash == HTPHashing.hashPrincipalCalculatorConfig(record.config);
        entry.statusValid = entry.statusCode == 2;
        entry.currentValid = entry.current;
        entry.codeHashValid = entry.subject.codehash == entry.subjectCodeHash && entry.subject.code.length != 0;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.calculatorRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _adapterEntry(CoreDeployment memory core, ExampleConfigs memory configs, uint256 index)
        private
        view
        returns (string memory json, bool valid)
    {
        IAdapterRegistry registry = IAdapterRegistry(core.adapterRegistry.proxy);
        AdapterRecord memory record = registry.getAdapter(configs.adapters[index].adapterConfigId);
        AdapterRecord memory current = registry.getCurrentAdapter(record.config.capabilityHash);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.ADAPTER;
        entry.id = record.config.adapterConfigId;
        entry.configHash = record.config.configHash;
        entry.statusCode = uint256(record.status);
        entry.subject = record.config.adapter;
        entry.subjectCodeHash = record.config.codeHash;
        entry.dependentDvp = core.dvp;
        entry.current = current.config.adapterConfigId == entry.id;
        entry.idValid = record.exists && entry.id == configs.adapters[index].adapterConfigId;
        entry.configHashValid = entry.configHash == configs.adapters[index].configHash
            && entry.configHash == HTPHashing.hashAdapterConfig(record.config);
        bool superseded = index == 2;
        entry.statusValid = entry.statusCode == 2;
        entry.currentValid = entry.current != superseded;
        entry.codeHashValid = entry.subject.codehash == entry.subjectCodeHash && entry.subject.code.length != 0;
        entry.collectorValid = true;
        entry.dependentDvpValid = _containsDependentDvp(IDeploymentReportRegistry(core.adapterRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _settlementTokenEntry(CoreDeployment memory core, ExampleConfigs memory configs)
        private
        view
        returns (string memory json, bool valid)
    {
        ISettlementTokenRegistry registry = ISettlementTokenRegistry(core.settlementTokenRegistry.proxy);
        SettlementTokenRecord memory record = registry.getSettlementToken(configs.settlementToken.configId);
        SettlementTokenRecord memory current = registry.getCurrentSettlementToken(record.config.settlementToken);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.SETTLEMENT_TOKEN;
        entry.id = record.config.configId;
        entry.configHash = record.config.configHash;
        entry.statusCode = uint256(record.status);
        entry.subject = record.config.settlementToken;
        entry.subjectCodeHash = record.config.tokenCodeHash;
        entry.dependentDvp = core.dvp;
        entry.current = current.config.configId == entry.id;
        entry.idValid = record.exists && entry.id == configs.settlementToken.configId;
        entry.configHashValid = entry.configHash == configs.settlementToken.configHash
            && entry.configHash == HTPHashing.hashSettlementTokenConfig(record.config);
        entry.statusValid = entry.statusCode == 2;
        entry.currentValid = entry.current;
        entry.codeHashValid = entry.subject.codehash == entry.subjectCodeHash && entry.subject.code.length != 0;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.settlementTokenRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _assetVersionEntry(CoreDeployment memory core, ExampleConfigs memory configs)
        private
        view
        returns (string memory json, bool valid)
    {
        IAssetVersionRegistry registry = IAssetVersionRegistry(core.assetVersionRegistry.proxy);
        AssetVersionRecord memory record = registry.getAssetVersion(configs.assetVersion.assetVersionId);
        AssetVersionRecord memory current = registry.getCurrentAssetVersion(record.config.assetToken);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.ASSET_VERSION;
        entry.id = record.config.assetVersionId;
        entry.configHash = record.config.configHash;
        entry.statusCode = uint256(record.status);
        entry.subject = record.config.assetToken;
        entry.subjectCodeHash = record.config.tokenCodeHash;
        entry.dependentDvp = core.dvp;
        entry.current = current.config.assetVersionId == entry.id;
        entry.idValid = record.exists && entry.id == configs.assetVersion.assetVersionId;
        entry.configHashValid = entry.configHash == configs.assetVersion.configHash
            && entry.configHash == HTPHashing.hashAssetVersionConfig(record.config);
        entry.statusValid = entry.statusCode == 2;
        entry.currentValid = entry.current;
        entry.codeHashValid = entry.subject.codehash == entry.subjectCodeHash && entry.subject.code.length != 0;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.assetVersionRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _feeEntries(CoreDeployment memory core, ExampleConfigs memory configs)
        private
        view
        returns (string memory epochJson, bool epochValid, string memory feeJson, bool feeValid)
    {
        IFeeRegistry registry = IFeeRegistry(core.feeRegistry.proxy);
        bool dependent = _containsDependentDvp(IDeploymentReportRegistry(core.feeRegistry.proxy), core.dvp);
        FeePolicyEpochRecord memory epoch = registry.getFeePolicyEpoch(configs.feeEpoch.feePolicyEpoch);
        TrustedConfigurationEntry memory epochEntry;
        epochEntry.kind = ConfigurationKind.FEE_POLICY_EPOCH;
        epochEntry.id = bytes32(uint256(epoch.config.feePolicyEpoch));
        epochEntry.configHash = epoch.config.configHash;
        epochEntry.statusCode = uint256(epoch.status);
        epochEntry.subject = core.feeRegistry.proxy;
        epochEntry.subjectCodeHash = core.feeRegistry.proxy.codehash;
        epochEntry.dependentDvp = core.dvp;
        epochEntry.current = epochEntry.statusCode == 2;
        epochEntry.idValid = epoch.exists && epoch.config.feePolicyEpoch == configs.feeEpoch.feePolicyEpoch;
        epochEntry.configHashValid = epochEntry.configHash == configs.feeEpoch.configHash
            && epochEntry.configHash == HTPHashing.hashFeePolicyEpochConfig(epoch.config);
        epochEntry.statusValid = epochEntry.statusCode == 2;
        epochEntry.currentValid = epochEntry.current;
        epochEntry.codeHashValid = epochEntry.subject.codehash == epochEntry.subjectCodeHash;
        epochEntry.collectorValid = true;
        epochEntry.dependentDvpValid = dependent;
        epochValid = _trustedEntryOverall(epochEntry);
        epochJson = _trustedEntryJson(epochEntry, epochValid);

        FeeVersionRecord memory fee = registry.getFeeVersion(configs.fee.feeVersionId);
        (bytes32 currentId,) =
            registry.resolveApplicableFee(configs.fee.feePolicyEpoch, configs.assetVersion.assetVersionId);
        TrustedConfigurationEntry memory feeEntry;
        feeEntry.kind = ConfigurationKind.FEE_VERSION;
        feeEntry.id = fee.config.feeVersionId;
        feeEntry.configHash = fee.config.configHash;
        feeEntry.statusCode = uint256(fee.status);
        feeEntry.subject = fee.config.settlementToken;
        feeEntry.subjectCodeHash = fee.config.settlementToken.codehash;
        feeEntry.dependentDvp = core.dvp;
        feeEntry.collector = fee.config.collector;
        feeEntry.current = currentId == feeEntry.id;
        feeEntry.idValid = fee.exists && feeEntry.id == configs.fee.feeVersionId;
        feeEntry.configHashValid = feeEntry.configHash == configs.fee.configHash
            && feeEntry.configHash == HTPHashing.hashFeeConfig(fee.config);
        feeEntry.statusValid = feeEntry.statusCode == 2;
        feeEntry.currentValid = feeEntry.current;
        feeEntry.codeHashValid = feeEntry.subject.code.length != 0;
        feeEntry.collectorValid = feeEntry.collector == configs.fee.collector && feeEntry.collector != address(0);
        feeEntry.dependentDvpValid = dependent;
        feeValid = _trustedEntryOverall(feeEntry);
        feeJson = _trustedEntryJson(feeEntry, feeValid);
    }

    function _marketRuleEntry(CoreDeployment memory core, ExampleConfigs memory configs)
        private
        view
        returns (string memory json, bool valid)
    {
        IMarketRuleRegistry registry = IMarketRuleRegistry(core.marketRuleRegistry.proxy);
        MarketRuleRecord memory record = registry.getMarketRule(configs.marketRule.marketRuleConfigId);
        MarketRuleRecord memory current = registry.getCurrentMarketRule(configs.marketRule.assetVersionId);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.MARKET_RULE;
        entry.id = record.config.marketRuleConfigId;
        entry.configHash = record.config.configHash;
        entry.statusCode = uint256(record.status);
        entry.subject = record.config.settlementToken;
        entry.subjectCodeHash = record.config.settlementToken.codehash;
        entry.dependentDvp = core.dvp;
        entry.current = current.config.marketRuleConfigId == entry.id;
        entry.idValid = record.exists && entry.id == configs.marketRule.marketRuleConfigId;
        entry.configHashValid = entry.configHash == configs.marketRule.configHash
            && entry.configHash == HTPHashing.hashMarketRuleConfig(record.config);
        entry.statusValid = entry.statusCode == 2 && record.isSealed && !record.paused;
        entry.currentValid = entry.current;
        entry.codeHashValid = entry.subject.code.length != 0;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.marketRuleRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _appendMarketRuleConfiguration(
        string memory json,
        bool ready,
        CoreDeployment memory core,
        ExampleConfigs memory configs
    ) private view returns (string memory, bool) {
        (string memory entry, bool valid) = _marketRuleEntry(core, configs);
        return (_appendJsonEntry(json, entry), ready && valid);
    }

    function _participantEntry(CoreDeployment memory core, ExampleConfigs memory configs, uint256 index)
        private
        view
        returns (string memory json, bool valid)
    {
        IParticipantRegistry registry = IParticipantRegistry(core.participantRegistry.proxy);
        ParticipantRecord memory record = registry.getParticipant(configs.participants[index].wallet);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.PARTICIPANT;
        entry.id = keccak256(abi.encode(block.chainid, record.wallet));
        entry.configHash = _participantSafeHash(record);
        entry.statusCode = uint256(record.status);
        entry.subject = record.wallet;
        entry.dependentDvp = core.dvp;
        entry.current = entry.statusCode == 1;
        entry.idValid = record.wallet == configs.participants[index].wallet;
        entry.configHashValid = record.participantType == configs.participants[index].participantType
            && record.validUntil == configs.participants[index].validUntil && record.version == 1;
        entry.statusValid = entry.statusCode == 1;
        entry.currentValid = entry.current;
        entry.codeHashValid = true;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.participantRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _eligibilityEntry(CoreDeployment memory core, ExampleConfigs memory configs, uint256 index)
        private
        view
        returns (string memory json, bool valid)
    {
        IEligibilityRegistry registry = IEligibilityRegistry(core.eligibilityRegistry.proxy);
        bytes32 eligibilityKey = keccak256(
            abi.encode(block.chainid, configs.eligibilities[index].wallet, configs.eligibilities[index].assetVersionId)
        );
        EligibilityRecord memory record = registry.getEligibility(eligibilityKey);
        TrustedConfigurationEntry memory entry;
        entry.kind = ConfigurationKind.ELIGIBILITY;
        entry.id = record.eligibilityKey;
        entry.configHash = _eligibilitySafeHash(record);
        entry.statusCode = record.revoked ? 3 : (record.paused ? 2 : (record.recordVersion == 0 ? 0 : 1));
        entry.subject = record.wallet;
        entry.dependentDvp = core.dvp;
        entry.current = entry.statusCode == 1;
        entry.idValid = record.eligibilityKey == eligibilityKey;
        entry.configHashValid = record.wallet == configs.eligibilities[index].wallet
            && record.assetVersionId == configs.eligibilities[index].assetVersionId
            && record.decision == configs.eligibilities[index].decision && record.recordVersion == 1;
        entry.statusValid = entry.statusCode == 1 && record.decision == Decision.PASS;
        entry.currentValid = entry.current;
        entry.codeHashValid = true;
        entry.collectorValid = true;
        entry.dependentDvpValid =
            _containsDependentDvp(IDeploymentReportRegistry(core.eligibilityRegistry.proxy), core.dvp);
        valid = _trustedEntryOverall(entry);
        json = _trustedEntryJson(entry, valid);
    }

    function _trustedEntryJson(TrustedConfigurationEntry memory entry, bool overall)
        private
        pure
        returns (string memory json)
    {
        json = string.concat('{"kind":"', _kind(entry.kind), '","id":"', vm.toString(entry.id));
        json = string.concat(json, '","configHash":"', vm.toString(entry.configHash), '","statusCode":');
        json = string.concat(
            json, vm.toString(entry.statusCode), ',"status":"', _statusLabel(entry.kind, entry.statusCode)
        );
        json = string.concat(json, '","subject":"', vm.toString(entry.subject), '","subjectCodeHash":"');
        json = string.concat(json, vm.toString(entry.subjectCodeHash), '","current":', _bool(entry.current));
        json = string.concat(json, ',"dependentDvp":"', vm.toString(entry.dependentDvp), '","collector":"');
        json = string.concat(json, vm.toString(entry.collector), '","verification":{"trustedOnchain":true,"id":');
        json = string.concat(json, _bool(entry.idValid), ',"configHash":', _bool(entry.configHashValid));
        json = string.concat(json, ',"status":', _bool(entry.statusValid), ',"current":');
        json = string.concat(json, _bool(entry.currentValid), ',"codeHash":', _bool(entry.codeHashValid));
        json = string.concat(json, ',"collector":', _bool(entry.collectorValid), ',"dependentDvp":');
        json = string.concat(json, _bool(entry.dependentDvpValid), ',"overall":', _bool(overall), "}}");
    }

    function _trustedEntryOverall(TrustedConfigurationEntry memory entry) private pure returns (bool) {
        return entry.idValid && entry.configHashValid && entry.statusValid && entry.currentValid && entry.codeHashValid
            && entry.collectorValid && entry.dependentDvpValid;
    }

    function _appendJsonEntry(string memory json, string memory entry) private pure returns (string memory) {
        if (bytes(json).length != 1) return string.concat(json, ",", entry);
        return string.concat(json, entry);
    }

    function _participantSafeHash(ParticipantRecord memory record) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(record.wallet, record.participantType, record.status, record.validUntil, record.version)
            );
    }

    function _eligibilitySafeHash(EligibilityRecord memory record) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                record.eligibilityKey,
                record.wallet,
                record.assetVersionId,
                record.decision,
                record.validFrom,
                record.validUntil,
                record.recordVersion,
                record.paused,
                record.revoked
            )
        );
    }

    function _readinessFacts(CoreReportInput memory input, bool productionApprovalPresent)
        private
        view
        returns (ReadinessFacts memory facts)
    {
        facts.deploymentIntegrity = _coreIntegrity(input.core, input.config);
        facts.dependentRegistrationComplete = _dependentRegistrationComplete(input.core);
        facts.governanceReady = _roleTopologyReady(input.core, input.config.roles);
        facts.configurationReady = false;
        facts.operationalReady = false;
        facts.productionApprovalPresent = productionApprovalPresent;
        facts.productionReady = false;
    }

    function _readinessJson(ReadinessFacts memory facts, bool configurationPresent, bool configurationTrusted)
        private
        pure
        returns (string memory json)
    {
        json = string.concat(
            '{"deploymentIntegrity":',
            _bool(facts.deploymentIntegrity),
            ',"dependentRegistrationComplete":',
            _bool(facts.dependentRegistrationComplete)
        );
        json = string.concat(json, ',"governanceReady":', _bool(facts.governanceReady), ',"configurationReady":');
        json =
            string.concat(json, _bool(facts.configurationReady), ',"operationalReady":', _bool(facts.operationalReady));
        json = string.concat(
            json,
            ',"productionApprovalPresent":',
            _bool(facts.productionApprovalPresent),
            ',"productionReady":',
            _bool(facts.productionReady)
        );
        json = string.concat(
            json, ',"configurationReportPresent":', _bool(configurationPresent), ',"configurationTrusted":'
        );
        json = string.concat(json, _bool(configurationTrusted), "}");
    }

    function _dependentRegistrationComplete(CoreDeployment memory core) private view returns (bool) {
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.adapterRegistry.proxy), core.dvp)) return false;
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.calculatorRegistry.proxy), core.dvp)) return false;
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.settlementTokenRegistry.proxy), core.dvp)) {
            return false;
        }
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.assetVersionRegistry.proxy), core.dvp)) return false;
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.eligibilityRegistry.proxy), core.dvp)) return false;
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.feeRegistry.proxy), core.dvp)) return false;
        if (!_containsDependentDvp(IDeploymentReportRegistry(core.marketRuleRegistry.proxy), core.dvp)) return false;
        return _containsDependentDvp(IDeploymentReportRegistry(core.participantRegistry.proxy), core.dvp);
    }

    function _roleTopologyReady(CoreDeployment memory core, DeploymentRoles memory roles) private view returns (bool) {
        address[8] memory registries = [
            core.adapterRegistry.proxy,
            core.calculatorRegistry.proxy,
            core.settlementTokenRegistry.proxy,
            core.assetVersionRegistry.proxy,
            core.eligibilityRegistry.proxy,
            core.feeRegistry.proxy,
            core.marketRuleRegistry.proxy,
            core.participantRegistry.proxy
        ];
        for (uint256 i = 0; i < registries.length; ++i) {
            IAccessControl access = IAccessControl(registries[i]);
            if (
                !access.hasRole(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin)
                    || !access.hasRole(Roles.GOVERNANCE_ROLE, roles.governance)
                    || !access.hasRole(Roles.UPGRADER_ROLE, roles.upgrader)
            ) return false;
        }
        IAccessControl dvpAccess = IAccessControl(core.dvp);
        return dvpAccess.hasRole(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin)
            && dvpAccess.hasRole(Roles.GOVERNANCE_ROLE, roles.governance)
            && !dvpAccess.hasRole(Roles.UPGRADER_ROLE, roles.upgrader);
    }

    function _coreIntegrity(CoreDeployment memory core, DeploymentConfig memory config) private view returns (bool) {
        if (!_registryOverall(
                core.adapterRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.calculatorRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.settlementTokenRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.assetVersionRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.eligibilityRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                true
            )) return false;
        if (!_registryOverall(
                core.feeRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.marketRuleRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        if (!_registryOverall(
                core.participantRegistry,
                config.roles,
                config.roles.pauser,
                config.roles.configurer,
                Roles.CONFIGURER_ROLE,
                core.dvp,
                false
            )) return false;
        return _dvpOverall(core, config);
    }

    function _registryOverall(
        RegistryDeployment memory deployment,
        DeploymentRoles memory roles,
        address pauser,
        address configurer,
        bytes32 configurerRole,
        address,
        bool
    ) private view returns (bool) {
        IDeploymentReportRegistry registry = IDeploymentReportRegistry(deployment.proxy);
        return _slotImplementation(deployment.proxy) == deployment.implementation
            && deployment.implementation.codehash == deployment.implementationCodeHash
            && deployment.implementation.code.length != 0 && deployment.proxy.code.length != 0
            && registry.hasRole(Roles.DEFAULT_ADMIN_ROLE, roles.defaultAdmin)
            && registry.hasRole(Roles.GOVERNANCE_ROLE, roles.governance)
            && registry.hasRole(Roles.UPGRADER_ROLE, roles.upgrader) && registry.hasRole(Roles.PAUSER_ROLE, pauser)
            && registry.hasRole(configurerRole, configurer);
    }

    function _dvpOverall(CoreDeployment memory core, DeploymentConfig memory config) private view returns (bool) {
        return core.dvp.code.length != 0 && core.currentStateValidatorFactory.code.length != 0
            && _computeCreateAddress(core.dvp, 1).code.length != 0
            && _computeCreateAddress(core.currentStateValidatorFactory, CURRENT_STATE_VALIDATOR_CREATE_NONCE).code
                    .length != 0
            && IAccessControl(core.dvp).hasRole(Roles.DEFAULT_ADMIN_ROLE, config.roles.defaultAdmin)
            && IAccessControl(core.dvp).hasRole(Roles.GOVERNANCE_ROLE, config.roles.governance)
            && IAccessControl(core.dvp).hasRole(Roles.PAUSER_ROLE, config.roles.pauser)
            && IAccessControl(core.dvp).hasRole(Roles.EXECUTOR_ROLE, config.roles.executor)
            && _dvpRegistryBindings(core)
            && IDvPSettlement(core.dvp).deploymentVersionHash() == DeploymentVersion.hash(config.deploymentVersion);
    }

    function _dvpRegistryBindings(CoreDeployment memory core) private view returns (bool) {
        IDvPSettlement dvp = IDvPSettlement(core.dvp);
        return address(dvp.adapterRegistry()) == core.adapterRegistry.proxy
            && address(dvp.principalCalculatorRegistry()) == core.calculatorRegistry.proxy
            && address(dvp.settlementTokenRegistry()) == core.settlementTokenRegistry.proxy
            && address(dvp.assetVersionRegistry()) == core.assetVersionRegistry.proxy
            && address(dvp.eligibilityRegistry()) == core.eligibilityRegistry.proxy
            && address(dvp.feeRegistry()) == core.feeRegistry.proxy
            && address(dvp.marketRuleRegistry()) == core.marketRuleRegistry.proxy
            && address(dvp.participantRegistry()) == core.participantRegistry.proxy;
    }

    function _dependentDvpsJson(IDeploymentReportRegistry registry) private view returns (string memory json) {
        json = "[";
        uint256 count = registry.getDependentDvpCount();
        for (uint256 i = 0; i < count; ++i) {
            if (i != 0) json = string.concat(json, ",");
            (address dependentDvp, bool retiredExempt) = registry.getDependentDvp(i);
            json = string.concat(json, '{"address":"', vm.toString(dependentDvp), '","codeHash":"');
            json = string.concat(json, vm.toString(dependentDvp.codehash), '","retiredExempt":');
            json = string.concat(json, _bool(retiredExempt), "}");
        }
        json = string.concat(json, "]");
    }

    function _containsDependentDvp(IDeploymentReportRegistry registry, address expected) private view returns (bool) {
        uint256 count = registry.getDependentDvpCount();
        for (uint256 i = 0; i < count; ++i) {
            (address dependentDvp,) = registry.getDependentDvp(i);
            if (dependentDvp == expected) return true;
        }
        return false;
    }

    function _slotImplementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _kind(ConfigurationKind kind) private pure returns (string memory) {
        if (kind == ConfigurationKind.CALCULATOR) return "CALCULATOR";
        if (kind == ConfigurationKind.ADAPTER) return "ADAPTER";
        if (kind == ConfigurationKind.SETTLEMENT_TOKEN) return "SETTLEMENT_TOKEN";
        if (kind == ConfigurationKind.ASSET_VERSION) return "ASSET_VERSION";
        if (kind == ConfigurationKind.FEE_POLICY_EPOCH) return "FEE_POLICY_EPOCH";
        if (kind == ConfigurationKind.FEE_VERSION) return "FEE_VERSION";
        if (kind == ConfigurationKind.PARTICIPANT) return "PARTICIPANT";
        if (kind == ConfigurationKind.MARKET_RULE) return "MARKET_RULE";
        return "ELIGIBILITY";
    }

    function _statusLabel(ConfigurationKind kind, uint256 statusCode) internal pure returns (string memory) {
        if (kind == ConfigurationKind.FEE_POLICY_EPOCH || kind == ConfigurationKind.MARKET_RULE) {
            if (statusCode == 0) return "NONE";
            if (statusCode == 1) return "DRAFT";
            if (statusCode == 2) return "ACTIVE";
            if (statusCode == 3) return "LEGACY_SERVING";
            if (statusCode == 4) return "CLOSED";
            return "UNKNOWN";
        }
        if (kind == ConfigurationKind.PARTICIPANT) {
            if (statusCode == 0) return "NONE";
            if (statusCode == 1) return "ACTIVE";
            if (statusCode == 2) return "PAUSED";
            if (statusCode == 3) return "REVOKED";
            return "UNKNOWN";
        }
        if (kind == ConfigurationKind.ELIGIBILITY) {
            if (statusCode == 0) return "NONE";
            if (statusCode == 1) return "ACTIVE";
            if (statusCode == 2) return "PAUSED";
            if (statusCode == 3) return "REVOKED";
            return "UNKNOWN";
        }
        if (statusCode == 0) return "NONE";
        if (statusCode == 1) return "REGISTERED";
        if (statusCode == 2) return "ACTIVE";
        if (statusCode == 3) return "PAUSED";
        if (statusCode == 4) return "DEPRECATED";
        if (kind == ConfigurationKind.FEE_VERSION && statusCode == 5) return "DEPRECATED_PAUSED";
        return "UNKNOWN";
    }

    function _validateConfigPath(string memory path) private pure {
        if (!_safeJsonPath(path, bytes("deploy/"))) revert InvalidReportPath(keccak256(bytes(path)));
    }

    function _validateReportPath(string memory path) private pure {
        if (!_safeJsonPath(path, bytes("deploy/out/"))) revert InvalidReportPath(keccak256(bytes(path)));
    }

    function _safeJsonPath(string memory path, bytes memory prefix) private pure returns (bool) {
        bytes memory value = bytes(path);
        if (value.length <= prefix.length + 5) return false;
        if (!_hasPrefix(value, prefix) || !_hasJsonSuffix(value)) return false;
        for (uint256 i = 0; i < value.length; ++i) {
            bytes1 character = value[i];
            if (!_isSafePathCharacter(character)) return false;
            if (i + 1 < value.length && character == bytes1(".") && value[i + 1] == bytes1(".")) return false;
        }
        return true;
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
        return string.concat(vm.projectRoot(), "/../", relativePath);
    }

    function _bool(bool value) private pure returns (string memory) {
        return value ? "true" : "false";
    }

    function _computeCreateAddress(address deployer, uint64 nonce) private pure returns (address) {
        bytes memory rlp;
        if (nonce == 0) {
            rlp = abi.encodePacked(hex"d694", deployer, hex"80");
        } else if (nonce <= 0x7f) {
            rlp = abi.encodePacked(hex"d694", deployer, uint8(nonce));
        } else if (nonce <= type(uint8).max) {
            rlp = abi.encodePacked(hex"d794", deployer, hex"81", uint8(nonce));
        } else if (nonce <= type(uint16).max) {
            rlp = abi.encodePacked(hex"d894", deployer, hex"82", uint16(nonce));
        } else if (nonce <= 0xffffff) {
            rlp = abi.encodePacked(hex"d994", deployer, hex"83", bytes3(uint24(nonce)));
        } else if (nonce <= type(uint32).max) {
            rlp = abi.encodePacked(hex"da94", deployer, hex"84", uint32(nonce));
        } else if (nonce <= 0xffffffffff) {
            rlp = abi.encodePacked(hex"db94", deployer, hex"85", bytes5(uint40(nonce)));
        } else if (nonce <= 0xffffffffffff) {
            rlp = abi.encodePacked(hex"dc94", deployer, hex"86", bytes6(uint48(nonce)));
        } else if (nonce <= 0xffffffffffffff) {
            rlp = abi.encodePacked(hex"dd94", deployer, hex"87", bytes7(uint56(nonce)));
        } else {
            rlp = abi.encodePacked(hex"de94", deployer, hex"88", nonce);
        }
        return address(uint160(uint256(keccak256(rlp))));
    }
}
