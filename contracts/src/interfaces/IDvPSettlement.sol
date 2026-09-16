// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAdapterRegistry} from "./IAdapterRegistry.sol";
import {IAssetVersionRegistry} from "./IAssetVersionRegistry.sol";
import {IEligibilityRegistry} from "./IEligibilityRegistry.sol";
import {IFeeRegistry} from "./IFeeRegistry.sol";
import {IParticipantRegistry} from "./IParticipantRegistry.sol";
import {IMarketRuleRegistry} from "./IMarketRuleRegistry.sol";
import {IPrincipalCalculatorRegistry} from "./IPrincipalCalculatorRegistry.sol";
import {ISettlementTokenRegistry} from "./ISettlementTokenRegistry.sol";
import {
    AssetClass,
    Decision,
    NonceCancellation,
    NonceStatus,
    NonceType,
    ParticipantType,
    ReasonCode,
    RequesterSide,
    SettlementParams
} from "../types/HTPTypes.sol";

/// @notice On-chain DvP settlement, nonce lifecycle, and registry wiring.
interface IDvPSettlement {
    event NonceConsumed(
        uint256 chainId, address indexed signer, NonceType indexed nonceType, uint256 indexed nonce, bytes32 tradeIdHash
    );

    event NonceCancelled(uint256 chainId, address indexed signer, NonceType indexed nonceType, uint256 indexed nonce);
    event GlobalPaused(uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor);
    event GlobalUnpaused(uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor);
    event Retired(uint256 chainId, ReasonCode reason, bytes32 evidenceHash, address actor);

    event SettlementExecuted(
        uint256 chainId,
        bytes32 indexed tradeIdHash,
        bytes32 quoteHash,
        bytes32 indexed snapshotHash,
        bytes32 indexed assetVersionId,
        ParticipantType requesterType,
        RequesterSide requesterSide,
        address requester,
        address quotingMaker,
        address buyer,
        address seller,
        address assetToken,
        address settlementToken,
        uint256 executedQuantity,
        AssetClass assetClass,
        bytes32 priceTermsHash,
        bytes32 principalCalculatorConfigId,
        bytes32 principalCalculatorConfigHash,
        bytes32 adapterConfigId,
        bytes32 adapterConfigHash,
        bytes32 settlementTokenConfigId,
        bytes32 settlementTokenConfigHash,
        bytes32 marketRuleConfigId,
        bytes32 marketRuleConfigHash,
        uint256 cashPrincipal,
        uint256 buyerFee,
        uint256 sellerFee,
        uint256 buyerDebit,
        uint256 sellerCredit,
        uint64 feePolicyEpoch,
        bytes32 feeVersionId,
        bytes32 matchedScopeHash,
        uint256 makerQuoteNonce,
        uint256 requesterTradeNonce,
        bytes32 deploymentVersionHash
    );

    event FeeCollected(
        uint256 chainId,
        bytes32 indexed tradeIdHash,
        bytes32 snapshotHash,
        address indexed collector,
        address indexed settlementToken,
        uint256 buyerFee,
        uint256 sellerFee,
        uint256 collectorCredit,
        uint64 feePolicyEpoch,
        bytes32 feeVersionId,
        bytes32 matchedScopeHash,
        bytes32 deploymentVersionHash
    );

    /// @notice Execute atomic DvP for signed settlement params.
    function settle(SettlementParams calldata params) external;

    /// @notice Read-only settlement gating without state changes.
    function preCheck(SettlementParams calldata params) external view returns (Decision decision, bytes4 reason);

    function cancelNonce(NonceType nonceType, uint256 nonce) external;

    /// @notice Cancel nonce via EIP-712 signature from the nonce owner.
    function cancelNonceBySig(NonceCancellation calldata cancellation, bytes calldata signature) external;

    function getNonceStatus(address signer, NonceType nonceType, uint256 nonce)
        external
        view
        returns (NonceStatus status);

    function usedQuoteHash(bytes32 quoteHash) external view returns (bool);
    function usedSnapshotHash(bytes32 snapshotHash) external view returns (bool);
    function usedTradeIdHash(bytes32 tradeIdHash) external view returns (bool);

    function pauseGlobal(ReasonCode reason, bytes32 evidenceHash) external;
    function unpauseGlobal(ReasonCode reason, bytes32 evidenceHash) external;

    /// @notice Permanently disable new settlements on this DvP deployment.
    function retire(ReasonCode reason, bytes32 evidenceHash) external;

    function domainSeparatorV4() external view returns (bytes32);
    function deploymentVersionHash() external view returns (bytes32);
    function globalPaused() external view returns (bool);
    function retired() external view returns (bool);

    function participantRegistry() external view returns (IParticipantRegistry);
    function assetVersionRegistry() external view returns (IAssetVersionRegistry);
    function eligibilityRegistry() external view returns (IEligibilityRegistry);
    function feeRegistry() external view returns (IFeeRegistry);
    function marketRuleRegistry() external view returns (IMarketRuleRegistry);
    function settlementTokenRegistry() external view returns (ISettlementTokenRegistry);
    function adapterRegistry() external view returns (IAdapterRegistry);
    function principalCalculatorRegistry() external view returns (IPrincipalCalculatorRegistry);
}
