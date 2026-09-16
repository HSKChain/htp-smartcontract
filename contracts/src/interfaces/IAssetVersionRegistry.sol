// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AssetClass,
    AssetVersionConfig,
    AssetVersionRecord,
    AssetVersionStatus,
    PermitCapability,
    ReasonCode,
    RestrictionMode,
    TokenDeploymentKind,
    TokenStandard
} from "../types/HTPTypes.sol";

interface IAssetVersionRegistry {
    event AssetVersionRegistered(
        uint256 chainId,
        bytes32 indexed assetVersionId,
        bytes32 indexed economicAssetIdHash,
        address indexed assetToken,
        uint32 schemaVersion,
        uint32 versionNo,
        TokenStandard tokenStandard,
        TokenDeploymentKind tokenDeploymentKind,
        uint8 assetDecimals,
        bytes32 tokenCodeHash,
        address implementation,
        bytes32 implementationCodeHash,
        PermitCapability assetPermitCapability,
        AssetClass assetClass,
        bytes32 principalCalculatorConfigId,
        bytes32 principalCalculatorConfigHash,
        bytes32 adapterConfigId,
        bytes32 adapterConfigHash,
        RestrictionMode restrictionMode,
        address settlementToken,
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        address dvpContract,
        bytes32 deploymentVersionHash,
        bytes32 replacesAssetVersionId,
        bytes32 configHash
    );

    event AssetVersionStatusChanged(
        uint256 chainId,
        bytes32 indexed assetVersionId,
        AssetVersionStatus oldStatus,
        AssetVersionStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );

    event CurrentAssetVersionChanged(
        uint256 chainId,
        address indexed assetToken,
        bytes32 indexed oldAssetVersionId,
        bytes32 indexed newAssetVersionId,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Register a new asset version binding token, calculators, adapters, and DvP.
    function registerAssetVersion(AssetVersionConfig calldata config) external;

    function activateAssetVersion(bytes32 assetVersionId, bytes32 expectedConfigHash) external;
    function pauseAssetVersion(bytes32 assetVersionId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseAssetVersion(
        bytes32 assetVersionId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external;

    function deprecateAssetVersion(bytes32 assetVersionId, ReasonCode reason, bytes32 evidenceHash) external;
    function getAssetVersion(bytes32 assetVersionId) external view returns (AssetVersionRecord memory);
    function getCurrentAssetVersion(address assetToken) external view returns (AssetVersionRecord memory);
    function getEconomicAssetIdHash(address assetToken) external view returns (bytes32);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
