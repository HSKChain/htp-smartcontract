// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vm} from "forge-std/Vm.sol";
import {BondPrincipalCalculator} from "src/calculators/BondPrincipalCalculator.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {StockPrincipalCalculator} from "src/calculators/StockPrincipalCalculator.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetClass,
    CalculatorStatus,
    PrincipalCalculatorConfig,
    PrincipalCalculatorRecord,
    ReasonCode
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract PrincipalCalculatorRegistryV2 is PrincipalCalculatorRegistry {
    function phase7V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract WrongInterfaceCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return bytes32(uint256(0xBAD));
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    function calculate(bytes calldata, uint256, uint8) external pure returns (bytes32, uint256, uint256) {
        return (bytes32(uint256(1)), 1, 1);
    }
}

contract WrongAssetClassCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.STOCK;
    }

    function calculate(bytes calldata, uint256, uint8) external pure returns (bytes32, uint256, uint256) {
        return (bytes32(uint256(1)), 1, 1);
    }
}

contract MalformedReturnCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    function calculate(bytes calldata, uint256, uint8) external pure {
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

contract RevertingCalculator {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.PRINCIPAL_CALCULATOR_V1;
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }

    function calculate(bytes calldata, uint256, uint8) external pure returns (bytes32, uint256, uint256) {
        revert("CALCULATOR_REVERTED");
    }
}

contract PrincipalCalculatorRegistryTest is RegistryTestBase {
    struct PrincipalCalculatorRegisteredData {
        uint256 chainId;
        uint32 schemaVersion;
        uint32 revision;
        bytes32 interfaceVersion;
        bytes32 codeHash;
        bytes32 configHash;
        bytes32 replacesId;
    }

    struct PrincipalCalculatorStatusChangedData {
        uint256 chainId;
        CalculatorStatus oldStatus;
        CalculatorStatus newStatus;
        ReasonCode reason;
        bytes32 evidenceHash;
        address actor;
    }

    address internal constant PAUSER = address(0x2002);
    address internal constant CONFIGURER = address(0x3002);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE002));
    bytes32 internal constant REGISTERED_TOPIC = 0x7fef648451b23e8b21feab8b32105e09bf952649ea49682bb2692532dbc939b1;
    bytes32 internal constant STATUS_CHANGED_TOPIC = 0xada25fb531456a36e530352f04105287a1b1c97de6d199cdc22fd33d7eb1dcd2;
    bytes32 internal constant CURRENT_CHANGED_TOPIC =
        0x36ba3c02378da74815d54790dba93acefa41916a606cd7bd95c8ef2f7b7cc63c;

    PrincipalCalculatorRegistry internal registry;
    IPrincipalCalculator internal calculator;

    function setUp() public override {
        super.setUp();
        PrincipalCalculatorRegistry implementation = new PrincipalCalculatorRegistry();
        registry = PrincipalCalculatorRegistry(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    PrincipalCalculatorRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        calculator = IPrincipalCalculator(address(new FundPrincipalCalculator()));
    }

    function testRegisterStoresValidatedRegisteredHistoryWithoutChangingCurrent() public {
        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.FUND, 1, bytes32(0));

        vm.prank(CONFIGURER);
        registry.registerPrincipalCalculator(config);

        PrincipalCalculatorRecord memory stored = registry.getPrincipalCalculator(config.calculatorConfigId);
        PrincipalCalculatorRecord memory current = registry.getCurrentPrincipalCalculator(AssetClass.FUND);
        assertTrue(stored.exists);
        assertEq(uint8(stored.status), uint8(CalculatorStatus.REGISTERED));
        assertEq(stored.config.calculatorConfigId, config.calculatorConfigId);
        assertEq(stored.config.configHash, config.configHash);
        assertFalse(current.exists);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigAlreadyExists.selector, config.calculatorConfigId));
        _register(config);
        assertEq(registry.getPrincipalCalculator(config.calculatorConfigId).config.configHash, config.configHash);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testProductionRegistryDoesNotExposeSchemaOrTestVersionGetters() public view {
        (bool schemaGetterExists,) = address(registry).staticcall(abi.encodeWithSignature("SCHEMA_VERSION()"));
        (bool testVersionGetterExists,) =
            address(registry).staticcall(abi.encodeWithSignature("implementationVersion()"));
        assertFalse(schemaGetterExists);
        assertFalse(testVersionGetterExists);
    }

    function testRegisterAcceptsReviewedStockAndBondProbeReturnShapes() public {
        IPrincipalCalculator stock = IPrincipalCalculator(address(new StockPrincipalCalculator()));
        IPrincipalCalculator bond = IPrincipalCalculator(address(new BondPrincipalCalculator()));
        PrincipalCalculatorConfig memory stockConfig = _config(stock, AssetClass.STOCK, 1, bytes32(0));
        PrincipalCalculatorConfig memory bondConfig = _config(bond, AssetClass.BOND, 1, bytes32(0));

        _register(stockConfig);
        _register(bondConfig);

        assertEq(
            uint8(registry.getPrincipalCalculator(stockConfig.calculatorConfigId).status),
            uint8(CalculatorStatus.REGISTERED)
        );
        assertEq(
            uint8(registry.getPrincipalCalculator(bondConfig.calculatorConfigId).status),
            uint8(CalculatorStatus.REGISTERED)
        );
    }

    function testAssetClassSubjectFormsLinearRevisionsAndPreservesHistoricalBindings() public {
        PrincipalCalculatorConfig memory first = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        _register(first);
        bytes32 wrongExpectedHash = bytes32(uint256(first.configHash) ^ 1);
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigHashMismatch.selector, wrongExpectedHash, first.configHash)
        );
        vm.prank(address(timelock));
        registry.activatePrincipalCalculator(first.calculatorConfigId, wrongExpectedHash);
        assertEq(
            uint8(registry.getPrincipalCalculator(first.calculatorConfigId).status), uint8(CalculatorStatus.REGISTERED)
        );
        assertFalse(registry.getCurrentPrincipalCalculator(AssetClass.FUND).exists);
        assertEq(vm.getRecordedLogs().length, 0);
        _activate(first);

        IPrincipalCalculator replacement = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        PrincipalCalculatorConfig memory wrongSecond = _config(replacement, AssetClass.FUND, 2, bytes32(0));
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigReplacesMismatch.selector, first.calculatorConfigId, bytes32(0))
        );
        _register(wrongSecond);
        assertFalse(registry.getPrincipalCalculator(wrongSecond.calculatorConfigId).exists);
        assertEq(vm.getRecordedLogs().length, 0);

        PrincipalCalculatorConfig memory second = _config(replacement, AssetClass.FUND, 2, first.calculatorConfigId);
        _register(second);
        assertEq(
            registry.getCurrentPrincipalCalculator(AssetClass.FUND).config.calculatorConfigId, first.calculatorConfigId
        );

        _activate(second);
        assertEq(
            registry.getCurrentPrincipalCalculator(AssetClass.FUND).config.calculatorConfigId, second.calculatorConfigId
        );
        assertEq(registry.getPrincipalCalculator(first.calculatorConfigId).config.configHash, first.configHash);
        assertTrue(
            registry.isPrincipalCalculatorConfigActive(first.calculatorConfigId, first.configHash, AssetClass.FUND)
        );
        assertFalse(
            registry.isPrincipalCalculatorConfigActive(first.calculatorConfigId, second.configHash, AssetClass.FUND)
        );
    }

    function testRegisterRejectsNoneUnknownIdentityAndRuntimeMismatches() public {
        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.NONE, 1, bytes32(0));
        PrincipalCalculatorConfig memory validConfig = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        vm.recordLogs();

        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidAssetClass.selector, uint8(AssetClass.NONE)));
        _register(config);

        bytes memory malformedEnumCall =
            abi.encodeCall(PrincipalCalculatorRegistry.registerPrincipalCalculator, (config));
        assembly ("memory-safe") {
            mstore(add(malformedEnumCall, 0xa4), 0xff)
        }
        vm.prank(CONFIGURER);
        (bool unknownClassAccepted,) = address(registry).call(malformedEnumCall);
        assertFalse(unknownClassAccepted);

        config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        config.chainId += 1;
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigChainMismatch.selector, block.chainid, config.chainId));
        _register(config);

        config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        config.codeHash = bytes32(uint256(config.codeHash) ^ 1);
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.CalculatorCodeHashMismatch.selector, config.codeHash, address(calculator).codehash
            )
        );
        _register(config);

        IPrincipalCalculator wrongInterface = IPrincipalCalculator(address(new WrongInterfaceCalculator()));
        config = _config(wrongInterface, AssetClass.FUND, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.CalculatorInterfaceMismatch.selector, config.interfaceVersion, bytes32(uint256(0xBAD))
            )
        );
        _register(config);

        IPrincipalCalculator wrongClass = IPrincipalCalculator(address(new WrongAssetClassCalculator()));
        config = _config(wrongClass, AssetClass.FUND, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.CalculatorAssetClassMismatch.selector, AssetClass.FUND, AssetClass.STOCK)
        );
        _register(config);

        IPrincipalCalculator malformed = IPrincipalCalculator(address(new MalformedReturnCalculator()));
        config = _config(malformed, AssetClass.FUND, 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.CalculatorReturnMalformed.selector, config.calculatorConfigId));
        _register(config);

        IPrincipalCalculator reverting = IPrincipalCalculator(address(new RevertingCalculator()));
        config = _config(reverting, AssetClass.FUND, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.CalculatorStaticCallFailed.selector, config.calculatorConfigId)
        );
        _register(config);
        assertFalse(registry.getPrincipalCalculator(validConfig.calculatorConfigId).exists);
        assertFalse(registry.getCurrentPrincipalCalculator(AssetClass.FUND).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRegisterAndActivateRejectProxyAndRuntimeDrift() public {
        IPrincipalCalculator proxyCalculator = IPrincipalCalculator(
            address(new ERC1967Proxy(address(calculator), abi.encodeCall(IPrincipalCalculator.interfaceVersion, ())))
        );
        PrincipalCalculatorConfig memory proxyConfig = _config(proxyCalculator, AssetClass.FUND, 1, bytes32(0));
        IPrincipalCalculator cloneCalculator = IPrincipalCalculator(Clones.clone(address(calculator)));
        PrincipalCalculatorConfig memory cloneConfig = _config(cloneCalculator, AssetClass.FUND, 1, bytes32(0));

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.UpgradeableImplementationForbidden.selector, address(proxyCalculator))
        );
        _register(proxyConfig);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.UpgradeableImplementationForbidden.selector, address(cloneCalculator))
        );
        _register(cloneConfig);
        assertFalse(registry.getPrincipalCalculator(proxyConfig.calculatorConfigId).exists);
        assertEq(vm.getRecordedLogs().length, 0);

        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        _register(config);
        vm.etch(address(calculator), hex"00");
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.CalculatorCodeHashMismatch.selector, config.codeHash, address(calculator).codehash
            )
        );
        _activate(config);
        assertEq(
            uint8(registry.getPrincipalCalculator(config.calculatorConfigId).status), uint8(CalculatorStatus.REGISTERED)
        );
        assertFalse(registry.getCurrentPrincipalCalculator(AssetClass.FUND).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testLifecycleCurrentAndHistoricalGettersRemainFailClosed() public {
        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        _register(config);
        _activate(config);
        assertTrue(
            registry.isPrincipalCalculatorConfigActive(config.calculatorConfigId, config.configHash, AssetClass.FUND)
        );

        vm.prank(PAUSER);
        registry.pausePrincipalCalculator(config.calculatorConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertFalse(
            registry.isPrincipalCalculatorConfigActive(config.calculatorConfigId, config.configHash, AssetClass.FUND)
        );
        assertEq(uint8(registry.getCurrentPrincipalCalculator(AssetClass.FUND).status), uint8(CalculatorStatus.PAUSED));

        vm.prank(address(timelock));
        registry.unpausePrincipalCalculator(
            config.calculatorConfigId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        vm.prank(PAUSER);
        registry.pausePrincipalCalculator(config.calculatorConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecatePrincipalCalculator(config.calculatorConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        assertEq(
            uint8(registry.getPrincipalCalculator(config.calculatorConfigId).status), uint8(CalculatorStatus.DEPRECATED)
        );
        vm.expectRevert();
        vm.prank(address(timelock));
        registry.unpausePrincipalCalculator(
            config.calculatorConfigId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
    }

    function testStrongTypedEventsMatchLiteralTopicsAndReplayableFields() public {
        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        vm.recordLogs();
        _register(config);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        assertEq(registrationLogs[0].topics.length, 4);
        assertEq(registrationLogs[0].topics[0], REGISTERED_TOPIC);
        assertEq(registrationLogs[0].topics[1], config.calculatorConfigId);
        assertEq(registrationLogs[0].topics[2], bytes32(uint256(AssetClass.FUND)));
        assertEq(registrationLogs[0].topics[3], bytes32(uint256(uint160(config.calculator))));
        assertEq(registrationLogs[0].data.length, 7 * 32);
        PrincipalCalculatorRegisteredData memory registeredData =
            abi.decode(registrationLogs[0].data, (PrincipalCalculatorRegisteredData));
        assertEq(registeredData.chainId, block.chainid);
        assertEq(registeredData.schemaVersion, config.schemaVersion);
        assertEq(registeredData.revision, config.revision);
        assertEq(registeredData.interfaceVersion, config.interfaceVersion);
        assertEq(registeredData.codeHash, config.codeHash);
        assertEq(registeredData.configHash, config.configHash);
        assertEq(registeredData.replacesId, config.replacesId);

        vm.recordLogs();
        _activate(config);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();
        assertEq(activationLogs.length, 2);
        assertEq(activationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(activationLogs[0].topics[1], config.calculatorConfigId);
        PrincipalCalculatorStatusChangedData memory statusData =
            abi.decode(activationLogs[0].data, (PrincipalCalculatorStatusChangedData));
        assertEq(statusData.chainId, block.chainid);
        assertEq(uint8(statusData.oldStatus), uint8(CalculatorStatus.REGISTERED));
        assertEq(uint8(statusData.newStatus), uint8(CalculatorStatus.ACTIVE));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.NONE));
        assertEq(statusData.evidenceHash, bytes32(0));
        assertEq(statusData.actor, address(timelock));

        assertEq(activationLogs[1].topics[0], CURRENT_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics[1], bytes32(uint256(AssetClass.FUND)));
        assertEq(activationLogs[1].topics[2], bytes32(0));
        assertEq(activationLogs[1].topics[3], config.calculatorConfigId);
        (uint256 currentChainId, address currentActor) = abi.decode(activationLogs[1].data, (uint256, address));
        assertEq(currentChainId, block.chainid);
        assertEq(currentActor, address(timelock));

        vm.recordLogs();
        vm.prank(PAUSER);
        registry.pausePrincipalCalculator(config.calculatorConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        Vm.Log[] memory pauseLogs = vm.getRecordedLogs();
        assertEq(pauseLogs.length, 1);
        assertEq(pauseLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(pauseLogs[0].topics[1], config.calculatorConfigId);
        statusData = abi.decode(pauseLogs[0].data, (PrincipalCalculatorStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(CalculatorStatus.ACTIVE));
        assertEq(uint8(statusData.newStatus), uint8(CalculatorStatus.PAUSED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.SECURITY_INCIDENT));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, PAUSER);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.deprecatePrincipalCalculator(config.calculatorConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        Vm.Log[] memory deprecationLogs = vm.getRecordedLogs();
        assertEq(deprecationLogs.length, 1);
        assertEq(deprecationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(deprecationLogs[0].topics[1], config.calculatorConfigId);
        statusData = abi.decode(deprecationLogs[0].data, (PrincipalCalculatorStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(CalculatorStatus.PAUSED));
        assertEq(uint8(statusData.newStatus), uint8(CalculatorStatus.DEPRECATED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.PLANNED_MIGRATION));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, address(timelock));
    }

    function testUpgradePreservesConfigsCurrentRolesAndDependentDvps() public {
        PrincipalCalculatorConfig memory config = _config(calculator, AssetClass.FUND, 1, bytes32(0));
        _register(config);
        _activate(config);
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        PrincipalCalculatorRegistryV2 nextImplementation = new PrincipalCalculatorRegistryV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(PrincipalCalculatorRegistryV2(address(registry)).phase7V2Marker(), 2);
        assertEq(
            registry.getCurrentPrincipalCalculator(AssetClass.FUND).config.calculatorConfigId, config.calculatorConfigId
        );
        assertEq(registry.getPrincipalCalculator(config.calculatorConfigId).config.configHash, config.configHash);
        assertEq(registry.getDependentDvpCount(), 1);
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
    }

    function _register(PrincipalCalculatorConfig memory config) internal {
        vm.prank(CONFIGURER);
        registry.registerPrincipalCalculator(config);
    }

    function _activate(PrincipalCalculatorConfig memory config) internal {
        vm.prank(address(timelock));
        registry.activatePrincipalCalculator(config.calculatorConfigId, config.configHash);
    }

    function _config(IPrincipalCalculator candidate, AssetClass assetClass, uint32 revision, bytes32 replacesId)
        internal
        view
        returns (PrincipalCalculatorConfig memory config)
    {
        bytes32 subject = bytes32(uint256(assetClass));
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, subject, revision
            ),
            revision: revision,
            chainId: block.chainid,
            assetClass: assetClass,
            calculator: address(candidate),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(candidate).codehash,
            replacesId: replacesId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
    }
}
