// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {DeployHTP} from "script/DeployHTP.s.sol";
import {DeploymentOperationBuilder} from "script/DeploymentOperationBuilder.sol";
import {OfflineExampleBuilder} from "script/OfflineExampleBuilder.sol";
import {WriteDeploymentReport} from "script/WriteDeploymentReport.s.sol";
import {
    CoreDeployment,
    DeploymentConfig,
    DeploymentRoles,
    DirectOperation,
    ExampleAdapterInputs,
    ExampleBusinessInputs,
    ExampleConfigs,
    ExampleImplementations,
    RegistryDeployment
} from "script/DeployTypes.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {IAdapterRegistry} from "src/interfaces/IAdapterRegistry.sol";
import {Roles} from "src/libraries/Roles.sol";
import {UUPSRegistryBase} from "src/registry/UUPSRegistryBase.sol";
import {AdapterRecord, AdapterStatus} from "src/types/HTPTypes.sol";
import {AddressListMock, ERC1404TokenMock, UsdyTokenMock} from "test/fixtures/AdapterMocks.sol";
import {
    IntegrationOndoGmToken,
    OndoComplianceMock,
    OndoComplianceViewMock,
    OndoGmListMock,
    OndoGmPauseManagerMock
} from "test/fixtures/OndoGmMocks.sol";
import {IntegrationERC20Token} from "test/fixtures/IntegrationTokens.sol";

contract ExampleConfigurationReportHarness is WriteDeploymentReport {
    function exampleConfigurationJson(CoreDeployment memory core, ExampleConfigs memory configs)
        external
        view
        returns (string memory json, bool ready)
    {
        return _exampleConfigurationJson(core, configs);
    }
}

contract DeploymentScriptTest is Test {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant DEFAULT_ADMIN = address(0x1001);
    address private constant GOVERNANCE = address(0x1002);
    address private constant UPGRADER = address(0x1003);
    address private constant PAUSER = address(0x1004);
    address private constant EXECUTOR = address(0x1005);
    address private constant OPERATOR = address(0x1006);
    address private constant SHARED = address(0x9001);

    DeployHTP private orchestrator;

    function setUp() public {
        orchestrator = new DeployHTP();
    }

    function testDeployCoreAssignsConfiguredRolesDirectly() public {
        DeploymentConfig memory config = _config();
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        address predictedDvp = orchestrator.predictDvpAddress(address(orchestrator), firstNonce);

        CoreDeployment memory core = orchestrator.deployCore(config, firstNonce);

        assertEq(core.dvp, predictedDvp);
        assertEq(vm.getNonce(address(orchestrator)), firstNonce + 18);
        RegistryDeployment[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            _assertProxy(registries[i]);
            IAccessControl access = IAccessControl(registries[i].proxy);
            assertTrue(access.hasRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN));
            assertTrue(access.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
            assertTrue(access.hasRole(Roles.UPGRADER_ROLE, UPGRADER));
            assertTrue(access.hasRole(Roles.PAUSER_ROLE, PAUSER));
        }

        DvPSettlement dvp = DvPSettlement(core.dvp);
        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN));
        assertTrue(dvp.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, PAUSER));
        assertTrue(dvp.hasRole(Roles.EXECUTOR_ROLE, EXECUTOR));
        assertFalse(dvp.hasRole(Roles.UPGRADER_ROLE, UPGRADER));
    }

    function testOneAddressCanHoldEveryRoleAndAlsoBeDeployer() public {
        DeployHTP fresh = new DeployHTP();
        DeploymentConfig memory config = _config();
        config.roles = DeploymentRoles({
            defaultAdmin: SHARED,
            governance: SHARED,
            upgrader: SHARED,
            pauser: SHARED,
            executor: SHARED,
            configurer: SHARED
        });
        uint64 firstNonce = uint64(vm.getNonce(SHARED));
        vm.deal(SHARED, 100 ether);

        CoreDeployment memory core = fresh.run(config, SHARED, firstNonce);

        assertTrue(IAccessControl(core.dvp).hasRole(Roles.DEFAULT_ADMIN_ROLE, SHARED));
        assertTrue(IAccessControl(core.dvp).hasRole(Roles.GOVERNANCE_ROLE, SHARED));
        assertTrue(IAccessControl(core.dvp).hasRole(Roles.PAUSER_ROLE, SHARED));
        assertTrue(IAccessControl(core.dvp).hasRole(Roles.EXECUTOR_ROLE, SHARED));
        assertTrue(IAccessControl(core.adapterRegistry.proxy).hasRole(Roles.UPGRADER_ROLE, SHARED));
        assertTrue(IAccessControl(core.adapterRegistry.proxy).hasRole(Roles.CONFIGURER_ROLE, SHARED));
    }

    function testGovernanceOperationsAreReturnedForDirectExecution() public {
        DeploymentConfig memory config = _config();
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        CoreDeployment memory core = orchestrator.deployCore(config, firstNonce);
        DeploymentOperationBuilder builder = new DeploymentOperationBuilder();

        DirectOperation[] memory operations = builder.dependentDvpRegistration(core, keccak256("deployment"));
        assertEq(operations.length, 8);
        for (uint256 i = 0; i < operations.length; ++i) {
            vm.prank(GOVERNANCE);
            (bool success,) = operations[i].target.call(operations[i].data);
            assertTrue(success);
        }

        RegistryDeployment[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            UUPSRegistryBase registry = UUPSRegistryBase(registries[i].proxy);
            assertEq(registry.getDependentDvpCount(), 1);
            (address dependent,) = registry.getDependentDvp(0);
            assertEq(dependent, core.dvp);
        }
    }

    function testReadConfigFileLoadsDirectRoleTopology() public view {
        (DeploymentConfig memory config, address deployer, uint64 nonce) =
            orchestrator.readConfigFile(string.concat(_repositoryRoot(), "/deploy/config.example.json"));

        assertEq(deployer, address(0x1001));
        assertEq(nonce, 0);
        assertEq(config.roles.defaultAdmin, address(0x1002));
        assertEq(config.roles.governance, address(0x1002));
        assertEq(config.roles.upgrader, address(0x1002));
        assertEq(config.roles.pauser, address(0x1003));
        assertEq(config.roles.executor, address(0x1004));
    }

    function testDeployExampleImplementationsIncludesOndoGmAdapter() public {
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        CoreDeployment memory core = orchestrator.deployCore(_config(), firstNonce);
        IntegrationOndoGmToken gmToken = _deployGmToken();
        ExampleImplementations memory implementations =
            orchestrator.deployExampleImplementations(core.dvp, _exampleAdapterInputs(gmToken));

        assertTrue(implementations.ondoGmAdapter.code.length != 0);
    }

    function testFoundryOperationsActivateUsdyBeforeOndoGmRevision() public {
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        CoreDeployment memory core = orchestrator.deployCore(_config(), firstNonce);
        IntegrationOndoGmToken gmToken = _deployGmToken();
        ExampleImplementations memory implementations =
            orchestrator.deployExampleImplementations(core.dvp, _exampleAdapterInputs(gmToken));
        OfflineExampleBuilder configBuilder = new OfflineExampleBuilder();
        ExampleConfigs memory configs = configBuilder.buildConfigs(core, implementations, _exampleBusinessInputs());
        DeploymentOperationBuilder operationBuilder = new DeploymentOperationBuilder();

        DirectOperation[] memory dependencies =
            operationBuilder.dependentDvpRegistration(core, keccak256("DEPLOYMENT_SCRIPT_DEPENDENCY"));
        _executeAllAs(GOVERNANCE, dependencies);
        _executeAllAs(OPERATOR, operationBuilder.calculatorRegistrations(core, configs));
        _executeAllAs(OPERATOR, operationBuilder.adapterRegistrations(core, configs));
        DirectOperation[] memory baseActivations = operationBuilder.calculatorAdapterActivations(core, configs);
        _executeAllAs(GOVERNANCE, baseActivations);
        _executeAs(GOVERNANCE, operationBuilder.usdyAdapterActivation(core, configs));
        _executeAs(OPERATOR, operationBuilder.ondoGmAdapterRegistration(core, configs));
        _executeAs(GOVERNANCE, operationBuilder.ondoGmAdapterActivation(core, configs));
        _executeAs(OPERATOR, operationBuilder.settlementTokenRegistration(core, configs));
        _executeAs(GOVERNANCE, operationBuilder.settlementTokenActivation(core, configs));
        _executeAs(OPERATOR, operationBuilder.assetVersionRegistration(core, configs));
        _executeAs(GOVERNANCE, operationBuilder.assetVersionActivation(core, configs));
        _executeAllAs(OPERATOR, operationBuilder.participantRegistrations(core, configs));
        _executeAllAs(OPERATOR, operationBuilder.eligibilityUpdates(core, configs));
        _executeAs(GOVERNANCE, operationBuilder.feeEpochCreation(core, configs));
        _executeAs(OPERATOR, operationBuilder.feeVersionRegistration(core, configs));
        _executeAllAs(GOVERNANCE, operationBuilder.feeFinalization(core, configs));
        _executeAs(OPERATOR, operationBuilder.marketRuleRegistration(core, configs));
        _executeAllAs(GOVERNANCE, operationBuilder.marketRuleFinalization(core, configs));

        IAdapterRegistry registry = IAdapterRegistry(core.adapterRegistry.proxy);
        AdapterRecord memory usdy = registry.getAdapter(configs.adapters[2].adapterConfigId);
        AdapterRecord memory ondoGm = registry.getAdapter(configs.adapters[3].adapterConfigId);
        assertEq(uint8(usdy.status), uint8(AdapterStatus.ACTIVE));
        assertEq(uint8(ondoGm.status), uint8(AdapterStatus.ACTIVE));
        assertEq(ondoGm.config.revision, 2);
        assertEq(ondoGm.config.replacesId, usdy.config.adapterConfigId);
        assertEq(
            registry.getCurrentAdapter(ondoGm.config.capabilityHash).config.adapterConfigId,
            ondoGm.config.adapterConfigId
        );

        (string memory configurationJson, bool configurationReady) =
            new ExampleConfigurationReportHarness().exampleConfigurationJson(core, configs);
        assertTrue(configurationReady);
        assertEq(_countOccurrences(bytes(configurationJson), bytes('"kind":"ADAPTER"')), 4);
    }

    function _exampleAdapterInputs(IntegrationOndoGmToken gmToken)
        private
        returns (ExampleAdapterInputs memory inputs)
    {
        AddressListMock blocklist = new AddressListMock();
        AddressListMock allowlist = new AddressListMock();
        AddressListMock sanctions = new AddressListMock();
        UsdyTokenMock usdy = new UsdyTokenMock();
        usdy.configure(address(blocklist), address(allowlist), address(sanctions));
        inputs = ExampleAdapterInputs({
            erc1404Token: address(new ERC1404TokenMock()),
            usdyToken: address(usdy),
            usdyBlocklist: address(blocklist),
            usdyAllowlist: address(allowlist),
            usdySanctionsList: address(sanctions),
            gmToken: address(gmToken),
            providerCallGas: 100_000
        });
    }

    function _deployGmToken() private returns (IntegrationOndoGmToken gmToken) {
        address gmIdentifier = address(uint160(uint256(keccak256("global_markets"))));
        OndoGmListMock gmBlocklist = new OndoGmListMock();
        OndoGmListMock gmSanctions = new OndoGmListMock();
        OndoGmPauseManagerMock pauseManager = new OndoGmPauseManagerMock();
        OndoComplianceMock compliance = new OndoComplianceMock();
        OndoComplianceViewMock complianceView = new OndoComplianceViewMock(address(compliance), gmIdentifier);
        gmToken = new IntegrationOndoGmToken(address(complianceView), address(pauseManager));
        compliance.configure(gmIdentifier, address(gmBlocklist), address(gmSanctions));
    }

    function _exampleBusinessInputs() private returns (ExampleBusinessInputs memory inputs) {
        inputs = ExampleBusinessInputs({
            assetToken: address(new IntegrationERC20Token(18)),
            assetDecimals: 18,
            settlementToken: address(new IntegrationERC20Token(6)),
            settlementTokenDecimals: 6,
            economicAssetIdHash: keccak256("DEPLOYMENT_SCRIPT_ASSET"),
            maker: address(0xA001),
            requester: address(0xA002),
            collector: address(0xA003),
            quoteValidFrom: uint64(block.timestamp),
            quoteValidUntil: uint64(block.timestamp + 2 days),
            settlementValidUntil: uint64(block.timestamp + 3 days),
            evidenceHash: keccak256("DEPLOYMENT_SCRIPT_EVIDENCE")
        });
    }

    function _executeAs(address actor, DirectOperation memory operation) private {
        vm.prank(actor);
        (bool success, bytes memory returnData) = operation.target.call(operation.data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function _executeAllAs(address actor, DirectOperation[] memory operations) private {
        for (uint256 i = 0; i < operations.length; ++i) {
            _executeAs(actor, operations[i]);
        }
    }

    function _countOccurrences(bytes memory haystack, bytes memory needle) private pure returns (uint256 count) {
        if (needle.length == 0 || needle.length > haystack.length) return 0;
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }

    function testRejectsZeroRoleAddress() public {
        DeploymentConfig memory config = _config();
        config.roles.upgrader = address(0);
        uint64 firstNonce = uint64(vm.getNonce(address(orchestrator)));
        vm.expectRevert(abi.encodeWithSelector(DeployHTP.InvalidDeploymentRole.selector, address(0)));
        orchestrator.deployCore(config, firstNonce);
    }

    function _config() private view returns (DeploymentConfig memory) {
        return DeploymentConfig({
            roles: DeploymentRoles({
                defaultAdmin: DEFAULT_ADMIN,
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

    function _assertProxy(RegistryDeployment memory deployment) private view {
        assertTrue(deployment.implementation.code.length != 0);
        assertTrue(deployment.proxy.code.length != 0);
        assertEq(
            address(uint160(uint256(vm.load(deployment.proxy, ERC1967_IMPLEMENTATION_SLOT)))), deployment.implementation
        );
        assertEq(deployment.implementation.codehash, deployment.implementationCodeHash);
    }

    function _registries(CoreDeployment memory core) private pure returns (RegistryDeployment[8] memory registries) {
        registries[0] = core.adapterRegistry;
        registries[1] = core.calculatorRegistry;
        registries[2] = core.settlementTokenRegistry;
        registries[3] = core.assetVersionRegistry;
        registries[4] = core.eligibilityRegistry;
        registries[5] = core.feeRegistry;
        registries[6] = core.marketRuleRegistry;
        registries[7] = core.participantRegistry;
    }

    function _repositoryRoot() private view returns (string memory root) {
        bytes memory contractsRoot = bytes(vm.projectRoot());
        bytes memory suffix = bytes("/contracts");
        uint256 rootLength = contractsRoot.length - suffix.length;
        bytes memory result = new bytes(rootLength);
        for (uint256 i = 0; i < rootLength; ++i) {
            result[i] = contractsRoot[i];
        }
        root = string(result);
    }
}
