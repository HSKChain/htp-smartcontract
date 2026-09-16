// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AdapterConfig,
    AdapterRecord,
    AdapterStatus,
    PrecheckMethod,
    ReasonCode,
    RestrictionMode,
    TokenStandard
} from "../types/HTPTypes.sol";

interface IAdapterRegistry {
    event AdapterRegistered(
        uint256 chainId,
        bytes32 indexed adapterConfigId,
        bytes32 indexed capabilityHash,
        address indexed adapter,
        uint32 schemaVersion,
        uint32 revision,
        bytes32 interfaceVersion,
        bytes32 codeHash,
        TokenStandard tokenStandard,
        RestrictionMode restrictionMode,
        PrecheckMethod precheckMethod,
        uint256 transferLegMask,
        bytes32 providerHash,
        bytes32 configHash,
        bytes32 replacesId
    );

    event AdapterStatusChanged(
        uint256 chainId,
        bytes32 indexed adapterConfigId,
        AdapterStatus oldStatus,
        AdapterStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );

    event CurrentAdapterChanged(
        uint256 chainId,
        bytes32 indexed capabilityHash,
        bytes32 indexed oldAdapterConfigId,
        bytes32 indexed newAdapterConfigId,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Register a new adapter config revision for a capability hash.
    function registerAdapter(AdapterConfig calldata config) external;

    function activateAdapter(bytes32 adapterConfigId, bytes32 expectedConfigHash) external;
    function pauseAdapter(bytes32 adapterConfigId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseAdapter(
        bytes32 adapterConfigId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external;

    function deprecateAdapter(bytes32 adapterConfigId, ReasonCode reason, bytes32 evidenceHash) external;
    function getAdapter(bytes32 adapterConfigId) external view returns (AdapterRecord memory);
    function getCurrentAdapter(bytes32 capabilityHash) external view returns (AdapterRecord memory);
    function isAdapterActive(bytes32 adapterConfigId) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
