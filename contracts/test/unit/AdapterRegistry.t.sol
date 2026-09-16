// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vm} from "forge-std/Vm.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AdapterRecord,
    AdapterStatus,
    PrecheckMethod,
    ReasonCode,
    RestrictionMode,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract AdapterRegistryV2 is AdapterRegistry {
    function phase7V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract AdapterRegistryTest is RegistryTestBase {
    struct AdapterRegisteredData {
        uint256 chainId;
        uint32 schemaVersion;
        uint32 revision;
        bytes32 interfaceVersion;
        bytes32 codeHash;
        TokenStandard tokenStandard;
        RestrictionMode restrictionMode;
        PrecheckMethod precheckMethod;
        uint256 transferLegMask;
        bytes32 providerHash;
        bytes32 configHash;
        bytes32 replacesId;
    }

    struct AdapterStatusChangedData {
        uint256 chainId;
        AdapterStatus oldStatus;
        AdapterStatus newStatus;
        ReasonCode reason;
        bytes32 evidenceHash;
        address actor;
    }

    address internal constant PAUSER = address(0x2001);
    address internal constant CONFIGURER = address(0x3001);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE001));
    bytes32 internal constant REGISTERED_TOPIC = 0x122780b981e58872670ab9f040e77097f023094586d0811c82b5ee22a2ba7c82;
    bytes32 internal constant STATUS_CHANGED_TOPIC = 0xe1317d54c1629b2df318c1b00461f27a1c97a82f2b5c78520ccf3ee55daaece3;
    bytes32 internal constant CURRENT_CHANGED_TOPIC =
        0xd350bc5a64342d5ab48b2cf142e372ad54c4bc2beb346f2918771d36dbf72d7f;

    AdapterRegistry internal registry;
    IAssetAdapter internal adapter;

    function setUp() public override {
        super.setUp();
        AdapterRegistry implementation = new AdapterRegistry();
        registry = AdapterRegistry(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    AdapterRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        adapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dependentDvp))));
    }

    function testRegisterStoresValidatedRegisteredHistoryWithoutChangingCurrent() public {
        AdapterConfig memory config = _config(adapter, 1, bytes32(0));

        vm.prank(CONFIGURER);
        registry.registerAdapter(config);

        AdapterRecord memory stored = registry.getAdapter(config.adapterConfigId);
        AdapterRecord memory current = registry.getCurrentAdapter(config.capabilityHash);
        assertTrue(stored.exists);
        assertEq(uint8(stored.status), uint8(AdapterStatus.REGISTERED));
        assertEq(stored.config.adapterConfigId, config.adapterConfigId);
        assertEq(stored.config.configHash, config.configHash);
        assertEq(stored.config.capabilityHash, config.capabilityHash);
        assertEq(stored.config.providerHash, config.providerHash);
        assertFalse(current.exists);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigAlreadyExists.selector, config.adapterConfigId));
        _register(config);
        assertEq(registry.getAdapter(config.adapterConfigId).config.configHash, config.configHash);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testProductionRegistryDoesNotExposeSchemaOrTestVersionGetters() public view {
        (bool schemaGetterExists,) = address(registry).staticcall(abi.encodeWithSignature("SCHEMA_VERSION()"));
        (bool testVersionGetterExists,) =
            address(registry).staticcall(abi.encodeWithSignature("implementationVersion()"));
        assertFalse(schemaGetterExists);
        assertFalse(testVersionGetterExists);
    }

    function testCapabilitySubjectFormsLinearRevisionsAndCurrentChangesOnlyOnActivation() public {
        AdapterConfig memory first = _config(adapter, 1, bytes32(0));
        _register(first);
        bytes32 wrongExpectedHash = bytes32(uint256(first.configHash) ^ 1);
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigHashMismatch.selector, wrongExpectedHash, first.configHash)
        );
        vm.prank(address(timelock));
        registry.activateAdapter(first.adapterConfigId, wrongExpectedHash);
        assertEq(uint8(registry.getAdapter(first.adapterConfigId).status), uint8(AdapterStatus.REGISTERED));
        assertFalse(registry.getCurrentAdapter(first.capabilityHash).exists);
        assertEq(vm.getRecordedLogs().length, 0);
        _activate(first);

        IAssetAdapter replacement = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(0xD002))));
        AdapterConfig memory wrongSecond = _config(replacement, 2, bytes32(0));
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigReplacesMismatch.selector, first.adapterConfigId, bytes32(0))
        );
        _register(wrongSecond);
        assertFalse(registry.getAdapter(wrongSecond.adapterConfigId).exists);
        assertEq(vm.getRecordedLogs().length, 0);

        AdapterConfig memory second = _config(replacement, 2, first.adapterConfigId);
        _register(second);

        AdapterRecord memory currentBefore = registry.getCurrentAdapter(first.capabilityHash);
        assertEq(currentBefore.config.adapterConfigId, first.adapterConfigId);
        assertEq(uint8(registry.getAdapter(second.adapterConfigId).status), uint8(AdapterStatus.REGISTERED));

        _activate(second);
        AdapterRecord memory currentAfter = registry.getCurrentAdapter(first.capabilityHash);
        assertEq(currentAfter.config.adapterConfigId, second.adapterConfigId);
        assertEq(registry.getAdapter(first.adapterConfigId).config.configHash, first.configHash);
    }

    function testRegisterRejectsWrongIdentityCodeInterfaceCapabilitiesAndProvider() public {
        AdapterConfig memory config = _config(adapter, 1, bytes32(0));
        bytes32 validConfigId = config.adapterConfigId;
        bytes32 validCapabilityHash = config.capabilityHash;
        vm.recordLogs();

        config.chainId += 1;
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigChainMismatch.selector, block.chainid, config.chainId));
        _register(config);

        config = _config(adapter, 1, bytes32(0));
        config.adapterConfigId = bytes32(uint256(config.adapterConfigId) ^ 1);
        config.configHash = HTPHashing.hashAdapterConfig(config);
        vm.expectRevert();
        _register(config);

        config = _config(adapter, 1, bytes32(0));
        config.codeHash = bytes32(uint256(config.codeHash) ^ 1);
        config.configHash = HTPHashing.hashAdapterConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AdapterCodeHashMismatch.selector, config.codeHash, address(adapter).codehash
            )
        );
        _register(config);

        config = _config(adapter, 1, bytes32(0));
        config.interfaceVersion = bytes32(uint256(config.interfaceVersion) ^ 1);
        config.configHash = HTPHashing.hashAdapterConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AdapterInterfaceMismatch.selector, InterfaceVersions.ASSET_ADAPTER_V1, config.interfaceVersion
            )
        );
        _register(config);

        config = _config(adapter, 1, bytes32(0));
        config.capabilities.transferLegMask = 2;
        config.capabilityHash = HTPHashing.hashAdapterCapabilities(config.capabilities);
        config.adapterConfigId = ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, config.capabilityHash, 1);
        config.configHash = HTPHashing.hashAdapterConfig(config);
        vm.expectRevert(HTPErrors.AdapterCapabilitiesMismatch.selector);
        _register(config);

        config = _config(adapter, 1, bytes32(0));
        config.providerHash = bytes32(uint256(config.providerHash) ^ 1);
        config.configHash = HTPHashing.hashAdapterConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AdapterProviderHashMismatch.selector, config.providerHash, adapter.providerHash()
            )
        );
        _register(config);

        assertFalse(registry.getAdapter(validConfigId).exists);
        assertFalse(registry.getCurrentAdapter(validCapabilityHash).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRegisterAndActivateRejectProxyAndRuntimeDrift() public {
        IAssetAdapter proxyAdapter = IAssetAdapter(
            address(new ERC1967Proxy(address(adapter), abi.encodeCall(IAssetAdapter.interfaceVersion, ())))
        );
        AdapterConfig memory proxyConfig = _config(proxyAdapter, 1, bytes32(0));
        IAssetAdapter cloneAdapter = IAssetAdapter(Clones.clone(address(adapter)));
        AdapterConfig memory cloneConfig = _config(cloneAdapter, 1, bytes32(0));

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.UpgradeableImplementationForbidden.selector, address(proxyAdapter))
        );
        _register(proxyConfig);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.UpgradeableImplementationForbidden.selector, address(cloneAdapter))
        );
        _register(cloneConfig);
        assertFalse(registry.getAdapter(proxyConfig.adapterConfigId).exists);
        assertEq(vm.getRecordedLogs().length, 0);

        AdapterConfig memory config = _config(adapter, 1, bytes32(0));
        _register(config);
        vm.etch(address(adapter), hex"00");
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.AdapterCodeHashMismatch.selector, config.codeHash, address(adapter).codehash
            )
        );
        _activate(config);
        assertEq(uint8(registry.getAdapter(config.adapterConfigId).status), uint8(AdapterStatus.REGISTERED));
        assertFalse(registry.getCurrentAdapter(config.capabilityHash).exists);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testLifecycleRolesCurrentAndHistoricalRecordsAreFailClosed() public {
        AdapterConfig memory config = _config(adapter, 1, bytes32(0));
        _register(config);

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(CONFIGURER);
        registry.activateAdapter(config.adapterConfigId, config.configHash);
        assertEq(uint8(registry.getAdapter(config.adapterConfigId).status), uint8(AdapterStatus.REGISTERED));
        assertFalse(registry.getCurrentAdapter(config.capabilityHash).exists);
        assertEq(vm.getRecordedLogs().length, 0);
        _activate(config);
        assertTrue(registry.isAdapterActive(config.adapterConfigId));

        vm.prank(PAUSER);
        registry.pauseAdapter(config.adapterConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertFalse(registry.isAdapterActive(config.adapterConfigId));
        assertEq(uint8(registry.getCurrentAdapter(config.capabilityHash).status), uint8(AdapterStatus.PAUSED));

        vm.prank(address(timelock));
        registry.unpauseAdapter(config.adapterConfigId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertTrue(registry.isAdapterActive(config.adapterConfigId));

        vm.prank(PAUSER);
        registry.pauseAdapter(config.adapterConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecateAdapter(config.adapterConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        assertEq(uint8(registry.getAdapter(config.adapterConfigId).status), uint8(AdapterStatus.DEPRECATED));

        vm.expectRevert();
        vm.prank(address(timelock));
        registry.unpauseAdapter(config.adapterConfigId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(registry.getAdapter(config.adapterConfigId).config.configHash, config.configHash);
    }

    function testStrongTypedEventsMatchLiteralTopicsAndReplayableFields() public {
        AdapterConfig memory config = _config(adapter, 1, bytes32(0));
        vm.recordLogs();
        _register(config);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        assertEq(registrationLogs[0].topics.length, 4);
        assertEq(registrationLogs[0].topics[0], REGISTERED_TOPIC);
        assertEq(registrationLogs[0].topics[1], config.adapterConfigId);
        assertEq(registrationLogs[0].topics[2], config.capabilityHash);
        assertEq(registrationLogs[0].topics[3], bytes32(uint256(uint160(config.adapter))));
        assertEq(registrationLogs[0].data.length, 12 * 32);
        AdapterRegisteredData memory registeredData = abi.decode(registrationLogs[0].data, (AdapterRegisteredData));
        assertEq(registeredData.chainId, block.chainid);
        assertEq(registeredData.schemaVersion, config.schemaVersion);
        assertEq(registeredData.revision, config.revision);
        assertEq(registeredData.interfaceVersion, config.interfaceVersion);
        assertEq(registeredData.codeHash, config.codeHash);
        assertEq(uint8(registeredData.tokenStandard), uint8(config.capabilities.tokenStandard));
        assertEq(uint8(registeredData.restrictionMode), uint8(config.capabilities.restrictionMode));
        assertEq(uint8(registeredData.precheckMethod), uint8(config.capabilities.precheckMethod));
        assertEq(registeredData.transferLegMask, config.capabilities.transferLegMask);
        assertEq(registeredData.providerHash, config.providerHash);
        assertEq(registeredData.configHash, config.configHash);
        assertEq(registeredData.replacesId, config.replacesId);

        vm.recordLogs();
        _activate(config);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();
        assertEq(activationLogs.length, 2);
        assertEq(activationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(activationLogs[0].topics[1], config.adapterConfigId);
        AdapterStatusChangedData memory statusData = abi.decode(activationLogs[0].data, (AdapterStatusChangedData));
        assertEq(statusData.chainId, block.chainid);
        assertEq(uint8(statusData.oldStatus), uint8(AdapterStatus.REGISTERED));
        assertEq(uint8(statusData.newStatus), uint8(AdapterStatus.ACTIVE));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.NONE));
        assertEq(statusData.evidenceHash, bytes32(0));
        assertEq(statusData.actor, address(timelock));

        assertEq(activationLogs[1].topics[0], CURRENT_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics[1], config.capabilityHash);
        assertEq(activationLogs[1].topics[2], bytes32(0));
        assertEq(activationLogs[1].topics[3], config.adapterConfigId);
        (uint256 currentChainId, address currentActor) = abi.decode(activationLogs[1].data, (uint256, address));
        assertEq(currentChainId, block.chainid);
        assertEq(currentActor, address(timelock));

        vm.recordLogs();
        vm.prank(PAUSER);
        registry.pauseAdapter(config.adapterConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        Vm.Log[] memory pauseLogs = vm.getRecordedLogs();
        assertEq(pauseLogs.length, 1);
        assertEq(pauseLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(pauseLogs[0].topics[1], config.adapterConfigId);
        statusData = abi.decode(pauseLogs[0].data, (AdapterStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(AdapterStatus.ACTIVE));
        assertEq(uint8(statusData.newStatus), uint8(AdapterStatus.PAUSED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.SECURITY_INCIDENT));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, PAUSER);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.deprecateAdapter(config.adapterConfigId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        Vm.Log[] memory deprecationLogs = vm.getRecordedLogs();
        assertEq(deprecationLogs.length, 1);
        assertEq(deprecationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(deprecationLogs[0].topics[1], config.adapterConfigId);
        statusData = abi.decode(deprecationLogs[0].data, (AdapterStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(AdapterStatus.PAUSED));
        assertEq(uint8(statusData.newStatus), uint8(AdapterStatus.DEPRECATED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.PLANNED_MIGRATION));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, address(timelock));
    }

    function testUpgradePreservesConfigsCurrentRolesAndDependentDvps() public {
        AdapterConfig memory config = _config(adapter, 1, bytes32(0));
        _register(config);
        _activate(config);
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        AdapterRegistryV2 nextImplementation = new AdapterRegistryV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(AdapterRegistryV2(address(registry)).phase7V2Marker(), 2);
        assertEq(registry.getCurrentAdapter(config.capabilityHash).config.adapterConfigId, config.adapterConfigId);
        assertEq(registry.getAdapter(config.adapterConfigId).config.configHash, config.configHash);
        assertEq(registry.getDependentDvpCount(), 1);
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
    }

    function _register(AdapterConfig memory config) internal {
        vm.prank(CONFIGURER);
        registry.registerAdapter(config);
    }

    function _activate(AdapterConfig memory config) internal {
        vm.prank(address(timelock));
        registry.activateAdapter(config.adapterConfigId, config.configHash);
    }

    function _config(IAssetAdapter candidate, uint32 revision, bytes32 replacesId)
        internal
        view
        returns (AdapterConfig memory config)
    {
        AdapterCapabilities memory capabilities = candidate.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, revision),
            revision: revision,
            chainId: block.chainid,
            adapter: address(candidate),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(candidate).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: candidate.providerHash(),
            replacesId: replacesId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }
}
