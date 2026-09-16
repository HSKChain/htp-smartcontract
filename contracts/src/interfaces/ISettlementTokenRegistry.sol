// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    PermitCapability,
    ReasonCode,
    SettlementTokenConfig,
    SettlementTokenRecord,
    SettlementTokenStatus,
    TokenDeploymentKind
} from "../types/HTPTypes.sol";

interface ISettlementTokenRegistry {
    event SettlementTokenRegistered(
        uint256 chainId,
        bytes32 indexed configId,
        address indexed settlementToken,
        bytes32 indexed adapterConfigId,
        uint32 schemaVersion,
        uint32 revision,
        TokenDeploymentKind tokenDeploymentKind,
        uint8 settlementTokenDecimals,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash,
        bytes32 adapterConfigHash,
        PermitCapability permitCapability,
        bytes32 configHash,
        bytes32 replacesConfigId
    );

    event SettlementTokenStatusChanged(
        uint256 chainId,
        bytes32 indexed configId,
        SettlementTokenStatus oldStatus,
        SettlementTokenStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );

    event CurrentSettlementTokenChanged(
        uint256 chainId,
        address indexed settlementToken,
        bytes32 indexed oldConfigId,
        bytes32 indexed newConfigId,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Register a settlement token config revision and adapter binding.
    function registerSettlementToken(SettlementTokenConfig calldata config) external;

    function activateSettlementToken(bytes32 configId, bytes32 expectedConfigHash) external;
    function pauseSettlementToken(bytes32 configId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseSettlementToken(
        bytes32 configId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external;

    function deprecateSettlementToken(bytes32 configId, ReasonCode reason, bytes32 evidenceHash) external;
    function getSettlementToken(bytes32 configId) external view returns (SettlementTokenRecord memory);
    function getCurrentSettlementToken(address token) external view returns (SettlementTokenRecord memory);
    function isSettlementTokenConfigActive(bytes32 configId, bytes32 expectedConfigHash) external view returns (bool);

    /// @notice Whether config may be referenced at registration time (hash and lifecycle gates).
    function isSettlementTokenConfigRegisterable(bytes32 configId, bytes32 expectedConfigHash) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
