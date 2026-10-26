// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AssetClass,
    CalculatorStatus,
    PrincipalCalculatorConfig,
    PrincipalCalculatorRecord,
    ReasonCode
} from "../types/HTPTypes.sol";

interface IPrincipalCalculatorRegistry {
    event PrincipalCalculatorRegistered(
        uint256 chainId,
        bytes32 indexed calculatorConfigId,
        AssetClass indexed assetClass,
        address indexed calculator,
        uint32 schemaVersion,
        uint32 revision,
        bytes32 interfaceVersion,
        bytes32 codeHash,
        bytes32 configHash,
        bytes32 replacesId
    );

    event PrincipalCalculatorStatusChanged(
        uint256 chainId,
        bytes32 indexed calculatorConfigId,
        CalculatorStatus oldStatus,
        CalculatorStatus newStatus,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );

    event CurrentPrincipalCalculatorChanged(
        uint256 chainId,
        AssetClass indexed assetClass,
        bytes32 indexed oldCalculatorConfigId,
        bytes32 indexed newCalculatorConfigId,
        address actor
    );

    event DependentDvpRegistered(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event DependentDvpRetiredExempted(uint256 chainId, address indexed dvp, bytes32 evidenceHash, address actor);
    event Upgraded(address indexed implementation);

    /// @notice Register a principal calculator config revision for an asset class.
    function registerPrincipalCalculator(PrincipalCalculatorConfig calldata config) external;

    function activatePrincipalCalculator(bytes32 calculatorConfigId, bytes32 expectedConfigHash) external;
    function pausePrincipalCalculator(bytes32 calculatorConfigId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpausePrincipalCalculator(
        bytes32 calculatorConfigId,
        bytes32 expectedConfigHash,
        ReasonCode reason,
        bytes32 evidenceHash
    ) external;

    function deprecatePrincipalCalculator(bytes32 calculatorConfigId, ReasonCode reason, bytes32 evidenceHash) external;
    function getPrincipalCalculator(bytes32 calculatorConfigId) external view returns (PrincipalCalculatorRecord memory);

    function getCurrentPrincipalCalculator(AssetClass assetClass)
        external
        view
        returns (PrincipalCalculatorRecord memory);

    /// @notice Active calculator for config id, hash, and expected asset class.
    function isPrincipalCalculatorConfigActive(
        bytes32 calculatorConfigId,
        bytes32 expectedConfigHash,
        AssetClass expectedAssetClass
    ) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
