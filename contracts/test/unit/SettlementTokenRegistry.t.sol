// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    Decision,
    PermitCapability,
    PrecheckMethod,
    ReasonCode,
    RestrictionMode,
    SettlementTokenConfig,
    SettlementTokenRecord,
    SettlementTokenStatus,
    TokenDeploymentKind,
    TokenStandard,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract SettlementTokenFixture {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MissingSettlementLegAdapter is IAssetAdapter {
    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.ASSET_ADAPTER_V1;
    }

    function capabilities() external pure returns (AdapterCapabilities memory) {
        return _capabilities();
    }

    function capabilityHash() external pure returns (bytes32) {
        return HTPHashing.hashAdapterCapabilities(_capabilities());
    }

    function providerHash() external pure returns (bytes32) {
        return bytes32(uint256(0xA11CE));
    }

    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        pure
        returns (Decision, uint256, bytes32)
    {
        return (Decision.BLOCK, 1, bytes32(uint256(1)));
    }

    function _capabilities() private pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            precheckMethod: PrecheckMethod.NO_PRECHECK,
            transferLegMask: uint256(1) << uint8(TransferLeg.ASSET)
        });
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract SettlementTokenRegistryV2 is SettlementTokenRegistry {
    function phase8V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract SettlementTokenRegistryTest is RegistryTestBase {
    struct SettlementTokenRegisteredData {
        uint256 chainId;
        uint32 schemaVersion;
        uint32 revision;
        TokenDeploymentKind tokenDeploymentKind;
        uint8 settlementTokenDecimals;
        bytes32 tokenCodeHash;
        address implementation;
        bytes32 implementationCodeHash;
        bytes32 adapterConfigHash;
        PermitCapability permitCapability;
        bytes32 configHash;
        bytes32 replacesConfigId;
    }

    struct SettlementTokenStatusChangedData {
        uint256 chainId;
        SettlementTokenStatus oldStatus;
        SettlementTokenStatus newStatus;
        ReasonCode reason;
        bytes32 evidenceHash;
        address actor;
    }

    address internal constant PAUSER = address(0x2101);
    address internal constant CONFIGURER = address(0x3101);
    address internal constant TOKEN_CONFIGURER = address(0x3102);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE101));
    bytes32 internal constant REGISTERED_TOPIC = 0xce3ade8d36ba0fe6a488b4bab5da00ab5a7fe4a7ecec04b51f586e86dbb09b6d;
    bytes32 internal constant STATUS_CHANGED_TOPIC = 0xe1b8c21abb81d397041eb0e62cdb31dac23a5bbedc292fd758e0eec1b49b719c;
    bytes32 internal constant CURRENT_CHANGED_TOPIC =
        0x889e523162d8a3688a6463aa19df3a3d9ff57ce27df84b02a197a0b599d9486f;

    AdapterRegistry internal adapterRegistry;
    SettlementTokenRegistry internal registry;
    IAssetAdapter internal adapter;
    SettlementTokenFixture internal token;
    AdapterConfig internal adapterConfig;

    function setUp() public override {
        super.setUp();
        adapterRegistry = AdapterRegistry(
            _deployProxy(
                address(new AdapterRegistry()),
                abi.encodeCall(
                    AdapterRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        adapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dependentDvp))));
        adapterConfig = _adapterConfig(adapter);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(adapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(adapterConfig.adapterConfigId, adapterConfig.configHash);

        registry = SettlementTokenRegistry(
            _deployProxy(
                address(new SettlementTokenRegistry()),
                abi.encodeCall(
                    SettlementTokenRegistry.initialize,
                    (
                        address(timelock),
                        address(timelock),
                        address(timelock),
                        PAUSER,
                        TOKEN_CONFIGURER,
                        address(adapterRegistry)
                    )
                )
            )
        );
        token = new SettlementTokenFixture();
    }

    function testRegisterStoresValidatedHistoryWithoutChangingCurrent() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));

        vm.prank(TOKEN_CONFIGURER);
        registry.registerSettlementToken(config);

        SettlementTokenRecord memory stored = registry.getSettlementToken(config.configId);
        SettlementTokenRecord memory current = registry.getCurrentSettlementToken(address(token));
        assertTrue(stored.exists);
        assertEq(uint8(stored.status), uint8(SettlementTokenStatus.REGISTERED));
        assertEq(stored.config.configId, config.configId);
        assertEq(stored.config.configHash, config.configHash);
        assertFalse(current.exists);
    }

    function testTokenSubjectFormsLinearVersionsAndCurrentChangesOnlyOnActivation() public {
        SettlementTokenConfig memory first = _config(1, bytes32(0));
        _register(first);
        _activate(first);

        SettlementTokenConfig memory wrongSecond = _config(2, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ConfigReplacesMismatch.selector, first.configId, bytes32(0)));
        _register(wrongSecond);

        SettlementTokenConfig memory second = _config(2, first.configId);
        _register(second);
        assertEq(registry.getCurrentSettlementToken(address(token)).config.configId, first.configId);

        _activate(second);
        assertEq(registry.getCurrentSettlementToken(address(token)).config.configId, second.configId);
        assertEq(registry.getSettlementToken(first.configId).config.configHash, first.configHash);
    }

    function testRegisterRequiresExactAdapterHashSupportingBothSettlementLegs() public {
        IAssetAdapter incompleteAdapter = IAssetAdapter(address(new MissingSettlementLegAdapter()));
        AdapterConfig memory incompleteConfig = _adapterConfig(incompleteAdapter);
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(incompleteConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(incompleteConfig.adapterConfigId, incompleteConfig.configHash);

        SettlementTokenConfig memory config = _config(1, bytes32(0));
        config.adapterConfigId = incompleteConfig.adapterConfigId;
        config.adapterConfigHash = incompleteConfig.configHash;
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.SettlementAdapterCapabilitiesInvalid.selector, incompleteConfig.adapterConfigId
            )
        );
        _register(config);

        config = _config(1, bytes32(0));
        config.adapterConfigHash = bytes32(uint256(config.adapterConfigHash) ^ 1);
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector, config.adapterConfigId, config.adapterConfigHash
            )
        );
        _register(config);
    }

    // 登记只要求 Adapter 已存在且内容哈希一致，激活才要求 ACTIVE。
    // 这既支持「一批登记 + 一批激活」的两笔上线流程，也覆盖登记后 Adapter 被暂停的漂移场景。
    function testRegisterAcceptsNonActiveAdapterButActivationStillRequiresActive() public {
        vm.prank(PAUSER);
        adapterRegistry.pauseAdapter(adapterConfig.adapterConfigId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);

        SettlementTokenConfig memory config = _config(1, bytes32(0));

        // Adapter 非 ACTIVE：登记仍然成功，内容校验照常执行。
        _register(config);
        assertTrue(registry.getSettlementToken(config.configId).exists);

        // 但激活必须因 Adapter 非 ACTIVE 而失败。
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector, adapterConfig.adapterConfigId, adapterConfig.configHash
            )
        );
        _activate(config);

        // Adapter 恢复后，同一条结算币配置即可激活。
        vm.prank(address(timelock));
        adapterRegistry.unpauseAdapter(
            adapterConfig.adapterConfigId, adapterConfig.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        _activate(config);
        assertTrue(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
    }

    function testPermitCapabilityRejectsNoneAndAcceptsReviewedCapabilities() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));
        config.permitCapability = PermitCapability.NONE;
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidPermitCapability.selector, PermitCapability.NONE));
        _register(config);

        config.permitCapability = PermitCapability.EIP2612;
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        _register(config);
        assertEq(
            uint8(registry.getSettlementToken(config.configId).config.permitCapability), uint8(PermitCapability.EIP2612)
        );
    }

    function testLifecycleAndActiveHelperRemainExactAndFailClosed() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);
        assertTrue(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
        assertFalse(registry.isSettlementTokenConfigActive(config.configId, bytes32(uint256(config.configHash) ^ 1)));

        vm.prank(PAUSER);
        registry.pauseSettlementToken(config.configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertFalse(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
        assertEq(uint8(registry.getCurrentSettlementToken(address(token)).status), uint8(SettlementTokenStatus.PAUSED));

        vm.prank(address(timelock));
        registry.unpauseSettlementToken(config.configId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertTrue(registry.isSettlementTokenConfigActive(config.configId, config.configHash));

        vm.prank(PAUSER);
        registry.pauseSettlementToken(config.configId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecateSettlementToken(config.configId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        assertFalse(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
        assertEq(uint8(registry.getSettlementToken(config.configId).status), uint8(SettlementTokenStatus.DEPRECATED));
    }

    function testImplementationChangedPauseCannotRestoreOldSettlementConfig() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);

        vm.prank(PAUSER);
        registry.pauseSettlementToken(config.configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        vm.prank(PAUSER);
        registry.pauseSettlementToken(config.configId, ReasonCode.IMPLEMENTATION_CHANGED, EVIDENCE_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.SettlementTokenImplementationChanged.selector, config.configId)
        );
        vm.prank(address(timelock));
        registry.unpauseSettlementToken(config.configId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertEq(uint8(registry.getSettlementToken(config.configId).status), uint8(SettlementTokenStatus.PAUSED));
    }

    function testActiveHelperRechecksRuntimeCodeAndStrictDecimals() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);

        vm.mockCall(address(token), abi.encodeWithSignature("decimals()"), abi.encode(uint256(18)));
        assertFalse(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
        vm.clearMockedCalls();

        vm.etch(address(token), hex"00");
        assertFalse(registry.isSettlementTokenConfigActive(config.configId, config.configHash));
    }

    function testStrongTypedEventsMatchLiteralTopicsAndReplayableFields() public {
        SettlementTokenConfig memory first = _config(1, bytes32(0));
        _register(first);
        _activate(first);

        SettlementTokenConfig memory config = _config(2, first.configId);
        config.tokenDeploymentKind = TokenDeploymentKind.ERC1967_PROXY;
        config.implementation = address(0xCA1C);
        config.implementationCodeHash = bytes32(uint256(0xBEEF));
        config.permitCapability = PermitCapability.EIP2612;
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
        vm.recordLogs();
        _register(config);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        assertEq(registrationLogs[0].topics.length, 4);
        assertEq(registrationLogs[0].topics[0], REGISTERED_TOPIC);
        assertEq(registrationLogs[0].topics[1], config.configId);
        assertEq(registrationLogs[0].topics[2], bytes32(uint256(uint160(config.settlementToken))));
        assertEq(registrationLogs[0].topics[3], config.adapterConfigId);
        assertEq(registrationLogs[0].data.length, 12 * 32);
        SettlementTokenRegisteredData memory registeredData =
            abi.decode(registrationLogs[0].data, (SettlementTokenRegisteredData));
        assertEq(registeredData.chainId, block.chainid);
        assertEq(registeredData.schemaVersion, config.schemaVersion);
        assertEq(registeredData.revision, config.revision);
        assertEq(uint8(registeredData.tokenDeploymentKind), uint8(config.tokenDeploymentKind));
        assertEq(registeredData.settlementTokenDecimals, config.settlementTokenDecimals);
        assertEq(registeredData.tokenCodeHash, config.tokenCodeHash);
        assertEq(registeredData.implementation, config.implementation);
        assertEq(registeredData.implementationCodeHash, config.implementationCodeHash);
        assertEq(registeredData.adapterConfigHash, config.adapterConfigHash);
        assertEq(uint8(registeredData.permitCapability), uint8(config.permitCapability));
        assertEq(registeredData.configHash, config.configHash);
        assertEq(registeredData.replacesConfigId, config.replacesConfigId);

        vm.recordLogs();
        _activate(config);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();
        assertEq(activationLogs.length, 2);
        assertEq(activationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(activationLogs[0].topics[1], config.configId);
        SettlementTokenStatusChangedData memory statusData =
            abi.decode(activationLogs[0].data, (SettlementTokenStatusChangedData));
        assertEq(statusData.chainId, block.chainid);
        assertEq(uint8(statusData.oldStatus), uint8(SettlementTokenStatus.REGISTERED));
        assertEq(uint8(statusData.newStatus), uint8(SettlementTokenStatus.ACTIVE));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.NONE));
        assertEq(statusData.evidenceHash, bytes32(0));
        assertEq(statusData.actor, address(timelock));
        assertEq(activationLogs[1].topics[0], CURRENT_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics[1], bytes32(uint256(uint160(config.settlementToken))));
        assertEq(activationLogs[1].topics[2], first.configId);
        assertEq(activationLogs[1].topics[3], config.configId);
        (uint256 currentChainId, address currentActor) = abi.decode(activationLogs[1].data, (uint256, address));
        assertEq(currentChainId, block.chainid);
        assertEq(currentActor, address(timelock));

        vm.recordLogs();
        vm.prank(PAUSER);
        registry.pauseSettlementToken(config.configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        Vm.Log[] memory pauseLogs = vm.getRecordedLogs();
        assertEq(pauseLogs.length, 1);
        assertEq(pauseLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(pauseLogs[0].topics[1], config.configId);
        statusData = abi.decode(pauseLogs[0].data, (SettlementTokenStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(SettlementTokenStatus.ACTIVE));
        assertEq(uint8(statusData.newStatus), uint8(SettlementTokenStatus.PAUSED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.SECURITY_INCIDENT));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, PAUSER);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.deprecateSettlementToken(config.configId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        Vm.Log[] memory deprecationLogs = vm.getRecordedLogs();
        assertEq(deprecationLogs.length, 1);
        assertEq(deprecationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(deprecationLogs[0].topics[1], config.configId);
        statusData = abi.decode(deprecationLogs[0].data, (SettlementTokenStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(SettlementTokenStatus.PAUSED));
        assertEq(uint8(statusData.newStatus), uint8(SettlementTokenStatus.DEPRECATED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.PLANNED_MIGRATION));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, address(timelock));
    }

    function testUpgradePreservesConfigsCurrentRolesAndDependentDvps() public {
        SettlementTokenConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);

        SettlementTokenRegistryV2 nextImplementation = new SettlementTokenRegistryV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(SettlementTokenRegistryV2(address(registry)).phase8V2Marker(), 2);
        assertEq(registry.getCurrentSettlementToken(address(token)).config.configId, config.configId);
        assertEq(registry.getSettlementToken(config.configId).config.configHash, config.configHash);
        assertEq(registry.getDependentDvpCount(), 1);
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, TOKEN_CONFIGURER));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
    }

    function _config(uint32 revision, bytes32 replacesConfigId)
        internal
        view
        returns (SettlementTokenConfig memory config)
    {
        bytes32 subject = bytes32(uint256(uint160(address(token))));
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(ConfigId.SETTLEMENT_TOKEN_NAMESPACE, 1, block.chainid, subject, revision),
            revision: revision,
            chainId: block.chainid,
            settlementToken: address(token),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: 6,
            tokenCodeHash: address(token).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.UNSUPPORTED,
            replacesConfigId: replacesConfigId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }

    function _adapterConfig(IAssetAdapter candidate) internal view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = candidate.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, 1),
            revision: 1,
            chainId: block.chainid,
            adapter: address(candidate),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(candidate).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: candidate.providerHash(),
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _register(SettlementTokenConfig memory config) internal {
        vm.prank(TOKEN_CONFIGURER);
        registry.registerSettlementToken(config);
    }

    function _activate(SettlementTokenConfig memory config) internal {
        vm.prank(address(timelock));
        registry.activateSettlementToken(config.configId, config.configHash);
    }
}
