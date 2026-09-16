// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    AssetVersionRecord,
    AssetVersionStatus,
    PermitCapability,
    PrincipalCalculatorConfig,
    ReasonCode,
    RestrictionMode,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";
import {MockDvP} from "test/fixtures/MockDvP.sol";

contract AssetTokenFixture {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract AssetSettlementTokenFixture {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MalformedDeploymentVersionDvp {
    function globalPaused() external pure returns (bool) {
        return false;
    }

    function retired() external pure returns (bool) {
        return false;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 0x1f)
        }
    }
}

contract DeploymentOnlyDvp {
    bytes32 private immutable VERSION;

    constructor(bytes32 version) {
        VERSION = version;
    }

    function deploymentVersionHash() external view returns (bytes32) {
        return VERSION;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract AssetVersionRegistryV2 is AssetVersionRegistry {
    function phase8V2Marker() external pure returns (uint256) {
        return 2;
    }
}

contract AssetVersionRegistryTest is RegistryTestBase {
    struct AssetVersionRegisteredData {
        uint256 chainId;
        uint32 schemaVersion;
        uint32 versionNo;
        TokenStandard tokenStandard;
        TokenDeploymentKind tokenDeploymentKind;
        uint8 assetDecimals;
        bytes32 tokenCodeHash;
        address implementation;
        bytes32 implementationCodeHash;
        PermitCapability assetPermitCapability;
        AssetClass assetClass;
        bytes32 principalCalculatorConfigId;
        bytes32 principalCalculatorConfigHash;
        bytes32 adapterConfigId;
        bytes32 adapterConfigHash;
        RestrictionMode restrictionMode;
        address settlementToken;
        bytes32 settlementTokenConfigId;
        bytes32 settlementTokenConfigHash;
        address dvpContract;
        bytes32 deploymentVersionHash;
        bytes32 replacesAssetVersionId;
        bytes32 configHash;
    }

    struct AssetVersionStatusChangedData {
        uint256 chainId;
        AssetVersionStatus oldStatus;
        AssetVersionStatus newStatus;
        ReasonCode reason;
        bytes32 evidenceHash;
        address actor;
    }

    address internal constant PAUSER = address(0x2201);
    address internal constant CONFIGURER = address(0x3201);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE201));
    bytes32 internal constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0xA55E7));
    bytes32 internal constant REGISTERED_TOPIC = 0x100773d51fab64b1962f8e4e5966207b6779560f02b61810ce0f40a1fc2f3fc4;
    bytes32 internal constant STATUS_CHANGED_TOPIC = 0xacd570cc1f9b1adf354695ff52dad2a12da252063b50ae008ac406b16481a03c;
    bytes32 internal constant CURRENT_CHANGED_TOPIC =
        0xd157739353c04f85851db8d9a21abf57ad97bdbf36ee2ddaadca4707546cbbdd;

    AdapterRegistry internal adapterRegistry;
    PrincipalCalculatorRegistry internal calculatorRegistry;
    SettlementTokenRegistry internal settlementTokenRegistry;
    AssetVersionRegistry internal registry;
    IAssetAdapter internal adapter;
    IPrincipalCalculator internal calculator;
    AssetTokenFixture internal assetToken;
    AssetSettlementTokenFixture internal settlementToken;
    AdapterConfig internal adapterConfig;
    PrincipalCalculatorConfig internal calculatorConfig;
    SettlementTokenConfig internal settlementTokenConfig;

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
        adapterConfig = _adapterConfig();
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(adapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(adapterConfig.adapterConfigId, adapterConfig.configHash);

        calculatorRegistry = PrincipalCalculatorRegistry(
            _deployProxy(
                address(new PrincipalCalculatorRegistry()),
                abi.encodeCall(
                    PrincipalCalculatorRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        calculator = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        calculatorConfig = _calculatorConfig();
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(calculatorConfig);
        vm.prank(address(timelock));
        calculatorRegistry.activatePrincipalCalculator(calculatorConfig.calculatorConfigId, calculatorConfig.configHash);

        settlementTokenRegistry = SettlementTokenRegistry(
            _deployProxy(
                address(new SettlementTokenRegistry()),
                abi.encodeCall(
                    SettlementTokenRegistry.initialize,
                    (
                        address(timelock),
                        address(timelock),
                        address(timelock),
                        PAUSER,
                        CONFIGURER,
                        address(adapterRegistry)
                    )
                )
            )
        );
        settlementToken = new AssetSettlementTokenFixture();
        settlementTokenConfig = _settlementTokenConfig();
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(settlementTokenConfig);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(
            settlementTokenConfig.configId, settlementTokenConfig.configHash
        );

        registry = AssetVersionRegistry(
            _deployProxy(
                address(new AssetVersionRegistry()),
                abi.encodeCall(
                    AssetVersionRegistry.initialize,
                    (
                        address(timelock),
                        address(timelock),
                        address(timelock),
                        PAUSER,
                        CONFIGURER,
                        address(settlementTokenRegistry),
                        address(adapterRegistry),
                        address(calculatorRegistry)
                    )
                )
            )
        );
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE_HASH);
        assetToken = new AssetTokenFixture();
    }

    function testRegisterStoresValidatedHistoryOwnershipWithoutChangingCurrent() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));

        vm.prank(CONFIGURER);
        registry.registerAssetVersion(config);

        AssetVersionRecord memory stored = registry.getAssetVersion(config.assetVersionId);
        AssetVersionRecord memory current = registry.getCurrentAssetVersion(address(assetToken));
        assertTrue(stored.exists);
        assertEq(uint8(stored.status), uint8(AssetVersionStatus.REGISTERED));
        assertEq(stored.config.assetVersionId, config.assetVersionId);
        assertEq(stored.config.configHash, config.configHash);
        assertEq(registry.getEconomicAssetIdHash(address(assetToken)), ECONOMIC_ASSET_ID_HASH);
        assertFalse(current.exists);
    }

    function testRegisterRejectsAssetDecimalsAboveReviewedBound() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        config.assetDecimals = 37;
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.AssetDecimalsOutOfRange.selector, uint8(37)));
        _register(config);
    }

    function testRegisterRejectsZeroEconomicAssetIdentity() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        config.economicAssetIdHash = bytes32(0);
        config.assetVersionId = ConfigId.assetVersion(1, bytes32(0), block.chainid, address(assetToken), 1);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(HTPErrors.InvalidConfigIdentity.selector);
        _register(config);
    }

    function testRegisterRejectsAssetVersionIdThatDoesNotMatchCanonicalIdentity() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        bytes32 expectedId = config.assetVersionId;
        config.assetVersionId = bytes32(uint256(0xBAD));

        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AssetVersionIdMismatch.selector, config.assetVersionId, expectedId)
        );
        _register(config);
    }

    function testAssetTokenOwnershipIsPermanentAndVersionsAreLinear() public {
        AssetVersionConfig memory first = _config(1, bytes32(0));
        _register(first);
        _activate(first);

        AssetVersionConfig memory wrongSecond = _config(2, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.ConfigReplacesMismatch.selector, first.assetVersionId, bytes32(0))
        );
        _register(wrongSecond);

        AssetVersionConfig memory conflictingOwner = _config(2, first.assetVersionId);
        conflictingOwner.economicAssetIdHash = bytes32(uint256(0xBAD));
        conflictingOwner.assetVersionId = ConfigId.assetVersion(
            1, conflictingOwner.economicAssetIdHash, block.chainid, address(assetToken), conflictingOwner.versionNo
        );
        conflictingOwner.configHash = HTPHashing.hashAssetVersionConfig(conflictingOwner);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.AssetTokenAlreadyRegistered.selector, address(assetToken)));
        _register(conflictingOwner);

        AssetVersionConfig memory second = _config(2, first.assetVersionId);
        _register(second);
        assertEq(registry.getCurrentAssetVersion(address(assetToken)).config.assetVersionId, first.assetVersionId);
        _activate(second);
        assertEq(registry.getCurrentAssetVersion(address(assetToken)).config.assetVersionId, second.assetVersionId);
        assertEq(registry.getAssetVersion(first.assetVersionId).config.configHash, first.configHash);
    }

    function testRegisterBindsExactSettlementAdapterCalculatorAndProductCapabilities() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        config.settlementTokenConfigHash = bytes32(uint256(config.settlementTokenConfigHash) ^ 1);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.settlementTokenConfigId,
                config.settlementTokenConfigHash
            )
        );
        _register(config);

        config = _config(1, bytes32(0));
        config.adapterConfigHash = bytes32(uint256(config.adapterConfigHash) ^ 1);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector, config.adapterConfigId, config.adapterConfigHash
            )
        );
        _register(config);

        config = _config(1, bytes32(0));
        config.principalCalculatorConfigHash = bytes32(uint256(config.principalCalculatorConfigHash) ^ 1);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                config.principalCalculatorConfigId,
                config.principalCalculatorConfigHash
            )
        );
        _register(config);

        config = _config(1, bytes32(0));
        config.restrictionMode = RestrictionMode.PLATFORM;
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AssetAdapterCapabilitiesInvalid.selector, config.adapterConfigId)
        );
        _register(config);

        config = _config(1, bytes32(0));
        config.assetPermitCapability = PermitCapability.NONE;
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.InvalidPermitCapability.selector, PermitCapability.NONE));
        _register(config);

        config.assetPermitCapability = PermitCapability.EIP2612;
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        _register(config);
        assertEq(
            uint8(registry.getAssetVersion(config.assetVersionId).config.assetPermitCapability),
            uint8(PermitCapability.EIP2612)
        );
    }

    function testRegisterRequiresRegisteredDvpWithCanonicalDeploymentVersion() public {
        MockDvP unregistered = new MockDvP(DEPLOYMENT_VERSION_HASH);
        AssetVersionConfig memory config = _config(1, bytes32(0));
        config.dvpContract = address(unregistered);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DependentDvpNotRegistered.selector, address(unregistered)));
        _register(config);

        config = _config(1, bytes32(0));
        config.deploymentVersionHash = bytes32(uint256(DEPLOYMENT_VERSION_HASH) ^ 1);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.DvpDeploymentVersionMismatch.selector,
                address(dependentDvp),
                config.deploymentVersionHash,
                DEPLOYMENT_VERSION_HASH
            )
        );
        _register(config);

        MalformedDeploymentVersionDvp malformed = new MalformedDeploymentVersionDvp();
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(malformed), EVIDENCE_HASH);
        config = _config(1, bytes32(0));
        config.dvpContract = address(malformed);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpDeploymentVersionMalformed.selector, address(malformed)));
        _register(config);
    }

    // tokenDeploymentKind 是运营侧判断「是否需要盯这个 Token 的 implementation 升级」
    // 的唯一链上依据。声明字段填零只证明声明自洽，不证明标的真是直部署，
    // 因此登记期要用与 Adapter / Calculator 相同的形态检测把裁量权收回链上。
    function testProxyShapedTokenCannotBeRegisteredAsDirectDeployment() public {
        // 只需要一个 runtime 里带 ERC-1967 slot 常量的外壳；实现无需初始化，
        // 用一次无副作用的 view 调用满足代理对非空 initData 的要求。
        address proxyToken =
            address(new ERC1967Proxy(address(new AssetTokenFixture()), abi.encodeCall(AssetTokenFixture.decimals, ())));

        AssetVersionConfig memory config = _config(1, bytes32(0));
        config.assetToken = proxyToken;
        config.assetVersionId = ConfigId.assetVersion(1, ECONOMIC_ASSET_ID_HASH, block.chainid, proxyToken, 1);
        config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        config.implementation = address(0);
        config.implementationCodeHash = bytes32(0);
        config.tokenCodeHash = proxyToken.codehash;
        config.configHash = bytes32(0);
        config.configHash = HTPHashing.hashAssetVersionConfig(config);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TokenDeploymentKindMismatch.selector, proxyToken, TokenDeploymentKind.DIRECT
            )
        );
        _register(config);

        // 直部署的同一实现仍然可以正常登记，检测没有误伤。
        AssetVersionConfig memory plain = _config(1, bytes32(0));
        _register(plain);
    }

    // 接口不完整的 DvP 现在在依赖登记入口就被拒，因此根本到不了资产版本登记这一步。
    function testDependentRegistrationRequiresCompleteGovernanceViewInterface() public {
        DeploymentOnlyDvp incomplete = new DeploymentOnlyDvp(DEPLOYMENT_VERSION_HASH);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, address(incomplete)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(incomplete), EVIDENCE_HASH);
    }

    // 纵深防御：即便某台 DvP 在登记之后 runtime 漂移成不完整接口，
    // 资产版本登记仍必须独立地拒绝它，而不是依赖入口那一道。
    function testRegisterRequiresCompleteGovernanceViewInterfaceAfterRuntimeDrift() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        vm.etch(address(dependentDvp), address(new DeploymentOnlyDvp(DEPLOYMENT_VERSION_HASH)).code);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, address(dependentDvp)));
        _register(config);
    }

    function testRetiredDvpCannotReceiveOrActivateAssetVersion() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        dependentDvp.setRetired(true);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpRetired.selector, address(dependentDvp)));
        _register(config);

        dependentDvp.setRetired(false);
        _register(config);
        dependentDvp.setRetired(true);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpRetired.selector, address(dependentDvp)));
        _activate(config);
    }

    function testImplementationChangedPauseCannotBeUnpaused() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);

        vm.prank(PAUSER);
        registry.pauseAssetVersion(config.assetVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        vm.prank(PAUSER);
        registry.pauseAssetVersion(config.assetVersionId, ReasonCode.IMPLEMENTATION_CHANGED, EVIDENCE_HASH);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AssetVersionImplementationChanged.selector, config.assetVersionId)
        );
        vm.prank(address(timelock));
        registry.unpauseAssetVersion(
            config.assetVersionId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        assertEq(uint8(registry.getAssetVersion(config.assetVersionId).status), uint8(AssetVersionStatus.PAUSED));
    }

    function testLifecycleRevalidatesDecimalsAndPreservesHistoricalVersion() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        _register(config);

        vm.mockCall(address(assetToken), abi.encodeWithSignature("decimals()"), abi.encode(uint256(6)));
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.AssetDecimalsMismatch.selector, address(assetToken), uint8(18), uint256(6))
        );
        _activate(config);
        assertFalse(registry.getCurrentAssetVersion(address(assetToken)).exists);
        vm.clearMockedCalls();

        _activate(config);
        vm.prank(PAUSER);
        registry.pauseAssetVersion(config.assetVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.unpauseAssetVersion(
            config.assetVersionId, config.configHash, ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH
        );
        vm.prank(PAUSER);
        registry.pauseAssetVersion(config.assetVersionId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        vm.prank(address(timelock));
        registry.deprecateAssetVersion(config.assetVersionId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);

        AssetVersionRecord memory historical = registry.getAssetVersion(config.assetVersionId);
        assertEq(uint8(historical.status), uint8(AssetVersionStatus.DEPRECATED));
        assertEq(historical.config.configHash, config.configHash);
        assertEq(registry.getCurrentAssetVersion(address(assetToken)).config.assetVersionId, config.assetVersionId);
    }

    function testStrongTypedEventsMatchLiteralTopicsAndReplayableFields() public {
        AssetVersionConfig memory first = _config(1, bytes32(0));
        _register(first);
        _activate(first);

        AssetVersionConfig memory config = _config(2, first.assetVersionId);
        config.tokenDeploymentKind = TokenDeploymentKind.ERC1967_PROXY;
        config.implementation = address(0xCA1C);
        config.implementationCodeHash = bytes32(uint256(0xBEEF));
        config.assetPermitCapability = PermitCapability.EIP2612;
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
        vm.recordLogs();
        _register(config);
        Vm.Log[] memory registrationLogs = vm.getRecordedLogs();
        assertEq(registrationLogs.length, 1);
        assertEq(registrationLogs[0].topics.length, 4);
        assertEq(registrationLogs[0].topics[0], REGISTERED_TOPIC);
        assertEq(registrationLogs[0].topics[1], config.assetVersionId);
        assertEq(registrationLogs[0].topics[2], config.economicAssetIdHash);
        assertEq(registrationLogs[0].topics[3], bytes32(uint256(uint160(config.assetToken))));
        assertEq(registrationLogs[0].data.length, 23 * 32);
        AssetVersionRegisteredData memory registeredData =
            abi.decode(registrationLogs[0].data, (AssetVersionRegisteredData));
        assertEq(registeredData.chainId, block.chainid);
        assertEq(registeredData.schemaVersion, config.schemaVersion);
        assertEq(registeredData.versionNo, config.versionNo);
        assertEq(uint8(registeredData.tokenStandard), uint8(config.tokenStandard));
        assertEq(uint8(registeredData.tokenDeploymentKind), uint8(config.tokenDeploymentKind));
        assertEq(registeredData.assetDecimals, config.assetDecimals);
        assertEq(registeredData.tokenCodeHash, config.tokenCodeHash);
        assertEq(registeredData.implementation, config.implementation);
        assertEq(registeredData.implementationCodeHash, config.implementationCodeHash);
        assertEq(uint8(registeredData.assetPermitCapability), uint8(config.assetPermitCapability));
        assertEq(uint8(registeredData.assetClass), uint8(config.assetClass));
        assertEq(registeredData.principalCalculatorConfigId, config.principalCalculatorConfigId);
        assertEq(registeredData.principalCalculatorConfigHash, config.principalCalculatorConfigHash);
        assertEq(registeredData.adapterConfigId, config.adapterConfigId);
        assertEq(registeredData.adapterConfigHash, config.adapterConfigHash);
        assertEq(uint8(registeredData.restrictionMode), uint8(config.restrictionMode));
        assertEq(registeredData.settlementToken, config.settlementToken);
        assertEq(registeredData.settlementTokenConfigId, config.settlementTokenConfigId);
        assertEq(registeredData.settlementTokenConfigHash, config.settlementTokenConfigHash);
        assertEq(registeredData.dvpContract, config.dvpContract);
        assertEq(registeredData.deploymentVersionHash, config.deploymentVersionHash);
        assertEq(registeredData.replacesAssetVersionId, config.replacesAssetVersionId);
        assertEq(registeredData.configHash, config.configHash);

        vm.recordLogs();
        _activate(config);
        Vm.Log[] memory activationLogs = vm.getRecordedLogs();
        assertEq(activationLogs.length, 2);
        assertEq(activationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(activationLogs[0].topics[1], config.assetVersionId);
        AssetVersionStatusChangedData memory statusData =
            abi.decode(activationLogs[0].data, (AssetVersionStatusChangedData));
        assertEq(statusData.chainId, block.chainid);
        assertEq(uint8(statusData.oldStatus), uint8(AssetVersionStatus.REGISTERED));
        assertEq(uint8(statusData.newStatus), uint8(AssetVersionStatus.ACTIVE));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.NONE));
        assertEq(statusData.evidenceHash, bytes32(0));
        assertEq(statusData.actor, address(timelock));
        assertEq(activationLogs[1].topics[0], CURRENT_CHANGED_TOPIC);
        assertEq(activationLogs[1].topics[1], bytes32(uint256(uint160(config.assetToken))));
        assertEq(activationLogs[1].topics[2], first.assetVersionId);
        assertEq(activationLogs[1].topics[3], config.assetVersionId);
        (uint256 currentChainId, address currentActor) = abi.decode(activationLogs[1].data, (uint256, address));
        assertEq(currentChainId, block.chainid);
        assertEq(currentActor, address(timelock));

        vm.recordLogs();
        vm.prank(PAUSER);
        registry.pauseAssetVersion(config.assetVersionId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        Vm.Log[] memory pauseLogs = vm.getRecordedLogs();
        assertEq(pauseLogs.length, 1);
        assertEq(pauseLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(pauseLogs[0].topics[1], config.assetVersionId);
        statusData = abi.decode(pauseLogs[0].data, (AssetVersionStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(AssetVersionStatus.ACTIVE));
        assertEq(uint8(statusData.newStatus), uint8(AssetVersionStatus.PAUSED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.SECURITY_INCIDENT));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, PAUSER);

        vm.recordLogs();
        vm.prank(address(timelock));
        registry.deprecateAssetVersion(config.assetVersionId, ReasonCode.PLANNED_MIGRATION, EVIDENCE_HASH);
        Vm.Log[] memory deprecationLogs = vm.getRecordedLogs();
        assertEq(deprecationLogs.length, 1);
        assertEq(deprecationLogs[0].topics[0], STATUS_CHANGED_TOPIC);
        assertEq(deprecationLogs[0].topics[1], config.assetVersionId);
        statusData = abi.decode(deprecationLogs[0].data, (AssetVersionStatusChangedData));
        assertEq(uint8(statusData.oldStatus), uint8(AssetVersionStatus.PAUSED));
        assertEq(uint8(statusData.newStatus), uint8(AssetVersionStatus.DEPRECATED));
        assertEq(uint8(statusData.reason), uint8(ReasonCode.PLANNED_MIGRATION));
        assertEq(statusData.evidenceHash, EVIDENCE_HASH);
        assertEq(statusData.actor, address(timelock));
    }

    function testUpgradePreservesOwnershipConfigsCurrentRolesAndDependentDvps() public {
        AssetVersionConfig memory config = _config(1, bytes32(0));
        _register(config);
        _activate(config);
        dependentDvp.setGlobalPaused(true);

        AssetVersionRegistryV2 nextImplementation = new AssetVersionRegistryV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(AssetVersionRegistryV2(address(registry)).phase8V2Marker(), 2);
        assertEq(registry.getCurrentAssetVersion(address(assetToken)).config.assetVersionId, config.assetVersionId);
        assertEq(registry.getAssetVersion(config.assetVersionId).config.configHash, config.configHash);
        assertEq(registry.getEconomicAssetIdHash(address(assetToken)), ECONOMIC_ASSET_ID_HASH);
        assertEq(registry.getDependentDvpCount(), 1);
        assertTrue(registry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(registry.hasRole(Roles.GOVERNANCE_ROLE, address(timelock)));
    }

    function _config(uint32 versionNo, bytes32 replacesAssetVersionId)
        internal
        view
        returns (AssetVersionConfig memory config)
    {
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: ECONOMIC_ASSET_ID_HASH,
            assetVersionId: ConfigId.assetVersion(
                1, ECONOMIC_ASSET_ID_HASH, block.chainid, address(assetToken), versionNo
            ),
            chainId: block.chainid,
            versionNo: versionNo,
            assetToken: address(assetToken),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            assetDecimals: 18,
            tokenCodeHash: address(assetToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            assetPermitCapability: PermitCapability.UNSUPPORTED,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            dvpContract: address(dependentDvp),
            deploymentVersionHash: DEPLOYMENT_VERSION_HASH,
            replacesAssetVersionId: replacesAssetVersionId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }

    function _adapterConfig() internal view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = adapter.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, 1),
            revision: 1,
            chainId: block.chainid,
            adapter: address(adapter),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(adapter).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: adapter.providerHash(),
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _calculatorConfig() internal view returns (PrincipalCalculatorConfig memory config) {
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(calculator),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(calculator).codehash,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
    }

    function _settlementTokenConfig() internal view returns (SettlementTokenConfig memory config) {
        bytes32 subject = bytes32(uint256(uint160(address(settlementToken))));
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(ConfigId.SETTLEMENT_TOKEN_NAMESPACE, 1, block.chainid, subject, 1),
            revision: 1,
            chainId: block.chainid,
            settlementToken: address(settlementToken),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: 6,
            tokenCodeHash: address(settlementToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.UNSUPPORTED,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }

    // 登记只要求三个引用存在且内容哈希一致，激活才要求 ACTIVE。
    // 支持「一批登记 + 一批激活」，同时覆盖登记后引用被暂停的漂移场景。
    function testRegisterAcceptsNonActiveReferencesButActivationStillRequiresActive() public {
        vm.prank(PAUSER);
        settlementTokenRegistry.pauseSettlementToken(
            settlementTokenConfig.configId, ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH
        );

        AssetVersionConfig memory config = _config(1, bytes32(0));

        // 结算币非 ACTIVE：登记仍然成功。
        _register(config);
        assertTrue(registry.getAssetVersion(config.assetVersionId).exists);

        // 但激活必须因结算币非 ACTIVE 而失败。
        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.ConfigReferenceMismatch.selector,
                settlementTokenConfig.configId,
                settlementTokenConfig.configHash
            )
        );
        _activate(config);

        // 结算币恢复后，同一条资产版本即可激活。
        vm.prank(address(timelock));
        settlementTokenRegistry.unpauseSettlementToken(
            settlementTokenConfig.configId,
            settlementTokenConfig.configHash,
            ReasonCode.GOVERNANCE_ACTION,
            EVIDENCE_HASH
        );
        _activate(config);
        assertEq(uint8(registry.getAssetVersion(config.assetVersionId).status), uint8(AssetVersionStatus.ACTIVE));
    }

    function _register(AssetVersionConfig memory config) internal {
        vm.prank(CONFIGURER);
        registry.registerAssetVersion(config);
    }

    function _activate(AssetVersionConfig memory config) internal {
        vm.prank(address(timelock));
        registry.activateAssetVersion(config.assetVersionId, config.configHash);
    }
}
