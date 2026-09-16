// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {MarketRuleConfig, MarketRuleRecord, MarketRuleStatus, ReasonCode} from "../types/HTPTypes.sol";

interface IMarketRuleRegistry {
    event MarketRuleRegistered(
        uint256 chainId,
        bytes32 indexed marketRuleConfigId,
        bytes32 indexed assetVersionId,
        uint32 revision,
        bytes32 replacesConfigId,
        bytes32 configHash,
        address actor
    );

    event MarketRuleSealed(uint256 chainId, bytes32 indexed marketRuleConfigId, bytes32 configHash, address actor);

    event MarketRuleStatusChanged(
        uint256 chainId,
        bytes32 indexed marketRuleConfigId,
        bytes32 indexed assetVersionId,
        MarketRuleStatus oldStatus,
        MarketRuleStatus newStatus,
        bytes32 evidenceHash,
        address actor
    );

    event MarketRulePauseChanged(
        uint256 chainId,
        bytes32 indexed marketRuleConfigId,
        bool paused,
        ReasonCode reason,
        bytes32 evidenceHash,
        address actor
    );

    event CurrentMarketRuleChanged(
        uint256 chainId,
        bytes32 indexed assetVersionId,
        bytes32 indexed oldConfigId,
        bytes32 indexed newConfigId,
        address actor
    );

    /// @notice Register a new market rule config revision for an asset version.
    function registerMarketRule(MarketRuleConfig calldata config) external;

    /// @notice Freeze config content; required before activation.
    function sealMarketRule(bytes32 configId, bytes32 expectedConfigHash) external;

    function activateMarketRule(bytes32 configId, bytes32 expectedConfigHash) external;
    function pauseMarketRule(bytes32 configId, ReasonCode reason, bytes32 evidenceHash) external;

    function unpauseMarketRule(bytes32 configId, bytes32 expectedConfigHash, ReasonCode reason, bytes32 evidenceHash)
        external;

    function closeMarketRule(bytes32 configId, bytes32 evidenceHash) external;
    function getMarketRule(bytes32 configId) external view returns (MarketRuleRecord memory);
    function getCurrentMarketRule(bytes32 assetVersionId) external view returns (MarketRuleRecord memory);

    /// @notice Whether rule is active for quote/settlement windows and config hash binding.
    function isMarketRuleServiceable(
        bytes32 configId,
        bytes32 expectedConfigHash,
        bytes32 assetVersionId,
        uint64 quoteCreatedAt,
        uint64 quoteExpiresAt,
        uint64 tradeDeadline
    ) external view returns (bool);

    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
