// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AdapterCapabilities, AdapterConfig, AdapterRecord, AdapterStatus, ReasonCode} from "src/types/HTPTypes.sol";
import {MockDvP} from "test/fixtures/MockDvP.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";

contract RegistryStateMachineHandler {
    uint256 private constant MAX_CONFIGS = 8;
    uint256 private constant MAX_DEPENDENTS = 4;
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0x1601));

    AdapterRegistry private immutable REGISTRY;
    IAssetAdapter private immutable ADAPTER;
    address private immutable CONFIGURER;
    address private immutable PAUSER;
    address private immutable GOVERNANCE;
    address private immutable NEXT_IMPLEMENTATION;
    bytes32 private immutable CAPABILITY_HASH;

    AdapterConfig[] private configs;
    AdapterStatus[] private statuses;
    MockDvP[] private dependents;
    bool[] private dependentExempt;
    uint256 private latestIndex;
    uint256 private currentIndex;

    uint256 public unexpectedSuccesses;
    uint256 public unexpectedReverts;
    uint256 public successfulUpgrades;

    constructor(
        AdapterRegistry registry,
        IAssetAdapter adapter,
        address configurer,
        address pauser,
        address governance,
        address nextImplementation,
        AdapterConfig memory initial
    ) {
        REGISTRY = registry;
        ADAPTER = adapter;
        CONFIGURER = configurer;
        PAUSER = pauser;
        GOVERNANCE = governance;
        NEXT_IMPLEMENTATION = nextImplementation;
        CAPABILITY_HASH = initial.capabilityHash;
        configs.push(initial);
        statuses.push(AdapterStatus.ACTIVE);
    }

    function registerConfig(uint8 mode) external {
        bool expectedValid = mode % 4 == 0 && configs.length < MAX_CONFIGS;
        AdapterConfig memory candidate;
        if (expectedValid) {
            candidate = _config(uint32(configs.length + 1), configs[latestIndex].adapterConfigId);
        } else if (mode % 4 == 1) {
            candidate = configs[latestIndex];
        } else if (mode % 4 == 2) {
            candidate = _config(uint32(configs.length + 2), configs[latestIndex].adapterConfigId);
        } else {
            candidate = _config(uint32(configs.length + 1), bytes32(0));
        }

        _prank(CONFIGURER);
        try REGISTRY.registerAdapter(candidate) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            configs.push(candidate);
            statuses.push(AdapterStatus.REGISTERED);
            latestIndex = configs.length - 1;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function activateConfig(uint256 seed, bool correctHash) external {
        (bool known, uint256 index, bytes32 configId) = _selectedConfig(seed);
        bytes32 expectedHash = known ? configs[index].configHash : bytes32(uint256(0xBAD1));
        if (!correctHash) expectedHash = bytes32(uint256(expectedHash) ^ 1);
        bool expectedValid = known && index == latestIndex && statuses[index] == AdapterStatus.REGISTERED && correctHash;

        _prank(GOVERNANCE);
        try REGISTRY.activateAdapter(configId, expectedHash) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            statuses[index] = AdapterStatus.ACTIVE;
            currentIndex = index;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function pauseConfig(uint256 seed, bool validEvidence) external {
        (bool known, uint256 index, bytes32 configId) = _selectedConfig(seed);
        ReasonCode reason = validEvidence ? ReasonCode.SECURITY_INCIDENT : ReasonCode.NONE;
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && statuses[index] == AdapterStatus.ACTIVE && validEvidence;

        _prank(PAUSER);
        try REGISTRY.pauseAdapter(configId, reason, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            statuses[index] = AdapterStatus.PAUSED;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function unpauseConfig(uint256 seed, bool correctHash, bool validEvidence) external {
        (bool known, uint256 index, bytes32 configId) = _selectedConfig(seed);
        bytes32 expectedHash = known ? configs[index].configHash : bytes32(uint256(0xBAD2));
        if (!correctHash) expectedHash = bytes32(uint256(expectedHash) ^ 1);
        ReasonCode reason = validEvidence ? ReasonCode.GOVERNANCE_ACTION : ReasonCode.NONE;
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && statuses[index] == AdapterStatus.PAUSED && correctHash && validEvidence;

        _prank(GOVERNANCE);
        try REGISTRY.unpauseAdapter(configId, expectedHash, reason, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            statuses[index] = AdapterStatus.ACTIVE;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function deprecateConfig(uint256 seed, bool validEvidence) external {
        (bool known, uint256 index, bytes32 configId) = _selectedConfig(seed);
        ReasonCode reason = validEvidence ? ReasonCode.PLANNED_MIGRATION : ReasonCode.NONE;
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && statuses[index] == AdapterStatus.PAUSED && validEvidence;

        _prank(GOVERNANCE);
        try REGISTRY.deprecateAdapter(configId, reason, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            statuses[index] = AdapterStatus.DEPRECATED;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function registerDependent(uint8 mode) external {
        bool expectedValid = mode % 3 == 0 && dependents.length < MAX_DEPENDENTS;
        MockDvP candidate;
        address candidateAddress;
        bytes32 evidence = EVIDENCE_HASH;
        if (expectedValid || dependents.length == 0) {
            candidate = new MockDvP(bytes32(dependents.length + 1));
            candidateAddress = address(candidate);
            if (!expectedValid) evidence = bytes32(0);
        } else if (mode % 3 == 1) {
            candidate = dependents[uint256(mode) % dependents.length];
            candidateAddress = address(candidate);
        } else {
            candidateAddress = address(0xBEEF);
        }

        _prank(GOVERNANCE);
        try REGISTRY.registerDependentDvp(candidateAddress, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            dependents.push(candidate);
            dependentExempt.push(false);
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function setDependentState(uint256 seed, bool paused, bool retired) external {
        if (dependents.length == 0) return;
        MockDvP dependent = dependents[seed % dependents.length];
        dependent.setGlobalPaused(paused);
        dependent.setRetired(retired);
    }

    function exemptDependent(uint256 seed, bool validEvidence) external {
        bool known = dependents.length != 0 && seed % (dependents.length + 1) < dependents.length;
        uint256 index = known ? seed % (dependents.length + 1) : 0;
        address dependentAddress = known ? address(dependents[index]) : address(0xBAD3);
        bytes32 evidence = validEvidence ? EVIDENCE_HASH : bytes32(0);
        bool expectedValid = known && !dependentExempt[index] && dependents[index].retired() && validEvidence;

        _prank(GOVERNANCE);
        try REGISTRY.exemptRetiredDependentDvp(dependentAddress, evidence) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            dependentExempt[index] = true;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function attemptUpgrade() external {
        // 空依赖集合 fail-closed：门禁把它读作「尚未登记」而不是「没有依赖」。
        bool expectedValid = dependents.length != 0;
        for (uint256 i = 0; i < dependents.length; ++i) {
            if (!dependentExempt[i] && !dependents[i].globalPaused()) {
                expectedValid = false;
                break;
            }
        }

        _prank(GOVERNANCE);
        try REGISTRY.upgradeToAndCall(NEXT_IMPLEMENTATION, bytes("")) {
            if (!expectedValid) {
                ++unexpectedSuccesses;
                return;
            }
            ++successfulUpgrades;
        } catch {
            if (expectedValid) ++unexpectedReverts;
        }
    }

    function configCount() external view returns (uint256) {
        return configs.length;
    }

    function configAt(uint256 index) external view returns (AdapterConfig memory, AdapterStatus) {
        return (configs[index], statuses[index]);
    }

    function expectedCurrentIndex() external view returns (uint256) {
        return currentIndex;
    }

    function capabilityHash() external view returns (bytes32) {
        return CAPABILITY_HASH;
    }

    function dependentCount() external view returns (uint256) {
        return dependents.length;
    }

    function dependentAt(uint256 index) external view returns (address, bool) {
        return (address(dependents[index]), dependentExempt[index]);
    }

    function _selectedConfig(uint256 seed) private view returns (bool known, uint256 index, bytes32 configId) {
        uint256 selected = seed % (configs.length + 1);
        known = selected < configs.length;
        index = known ? selected : 0;
        configId = known ? configs[index].adapterConfigId : keccak256(abi.encode("unknown-config", seed));
    }

    function _config(uint32 revision, bytes32 replacesId) private view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = ADAPTER.capabilities();
        bytes32 capabilityHash_ = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash_, revision),
            revision: revision,
            chainId: block.chainid,
            adapter: address(ADAPTER),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(ADAPTER).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash_,
            providerHash: ADAPTER.providerHash(),
            replacesId: replacesId,
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _prank(address actor) private {
        VmAccess.vm().prank(actor);
    }
}

library VmAccess {
    function vm() internal pure returns (VmLike) {
        return VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}

interface VmLike {
    function prank(address) external;
}

contract RegistryStateMachineInvariantTest is RegistryTestBase {
    address private constant PAUSER = address(0x2601);
    address private constant CONFIGURER = address(0x3601);

    AdapterRegistry private registry;
    RegistryStateMachineHandler private handler;

    function setUp() public override {
        super.setUp();
        registry = AdapterRegistry(
            _deployProxy(
                address(new AdapterRegistry()),
                abi.encodeCall(
                    AdapterRegistry.initialize,
                    (address(timelock), address(timelock), address(timelock), PAUSER, CONFIGURER)
                )
            )
        );
        IAssetAdapter adapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dependentDvp))));
        AdapterConfig memory initial = _initialConfig(adapter);
        vm.prank(CONFIGURER);
        registry.registerAdapter(initial);
        vm.prank(address(timelock));
        registry.activateAdapter(initial.adapterConfigId, initial.configHash);

        handler = new RegistryStateMachineHandler(
            registry, adapter, CONFIGURER, PAUSER, address(timelock), address(new AdapterRegistry()), initial
        );
        targetContract(address(handler));
    }

    function invariantConfigHistoryCurrentAndTerminalStateMatchModel() public view {
        uint256 count = handler.configCount();
        for (uint256 i = 0; i < count; ++i) {
            (AdapterConfig memory expected, AdapterStatus expectedStatus) = handler.configAt(i);
            AdapterRecord memory actual = registry.getAdapter(expected.adapterConfigId);
            assertTrue(actual.exists);
            assertEq(actual.config.configHash, expected.configHash);
            assertEq(actual.config.revision, expected.revision);
            assertEq(actual.config.replacesId, expected.replacesId);
            assertEq(actual.config.adapter, expected.adapter);
            assertEq(uint8(actual.status), uint8(expectedStatus));
        }

        (AdapterConfig memory expectedCurrent,) = handler.configAt(handler.expectedCurrentIndex());
        AdapterRecord memory current = registry.getCurrentAdapter(handler.capabilityHash());
        assertEq(current.config.adapterConfigId, expectedCurrent.adapterConfigId);
        assertEq(current.config.configHash, expectedCurrent.configHash);
    }

    function invariantDependentSetIsAppendOnlyAndExemptionIsOneWay() public view {
        uint256 count = handler.dependentCount();
        assertEq(registry.getDependentDvpCount(), count);
        for (uint256 i = 0; i < count; ++i) {
            (address expectedDvp, bool expectedExempt) = handler.dependentAt(i);
            (address actualDvp, bool actualExempt) = registry.getDependentDvp(i);
            assertEq(actualDvp, expectedDvp);
            assertEq(actualExempt, expectedExempt);
        }
    }

    function invariantIllegalEdgesAndUnsafeUpgradesNeverSucceed() public view {
        assertEq(handler.unexpectedSuccesses(), 0);
        assertEq(handler.unexpectedReverts(), 0);
    }

    function _initialConfig(IAssetAdapter adapter) private view returns (AdapterConfig memory config) {
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
}
