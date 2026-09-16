// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice Deterministic config and asset-version id derivation.
library ConfigId {
    bytes32 internal constant FEE_NAMESPACE = keccak256("HTP_FEE_CONFIG");
    bytes32 internal constant SETTLEMENT_TOKEN_NAMESPACE = keccak256("HTP_SETTLEMENT_TOKEN_CONFIG");
    bytes32 internal constant ADAPTER_NAMESPACE = keccak256("HTP_ADAPTER_CONFIG");
    bytes32 internal constant PRINCIPAL_CALCULATOR_NAMESPACE = keccak256("HTP_PRINCIPAL_CALCULATOR_CONFIG");
    bytes32 internal constant MARKET_RULE_NAMESPACE = keccak256("HTP_MARKET_RULE_CONFIG");

    // Fee=matchedScopeHash; Adapter=capabilityHash; SettlementToken=token subject;
    // Calculator=assetClass subject; MarketRule=assetVersionId.

    /// @notice Derive a registry config id from namespace, schema, chain, subject, and revision.
    function derive(bytes32 namespaceHash, uint32 schemaVersion, uint256 chainId, bytes32 subjectKey, uint32 revision)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(namespaceHash, schemaVersion, chainId, subjectKey, revision));
    }

    /// @notice Derive assetVersionId from economic identity, chain, token, and version number.
    function assetVersion(
        uint32 schemaVersion,
        bytes32 economicAssetIdHash,
        uint256 chainId,
        address assetToken,
        uint32 versionNo
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(schemaVersion, economicAssetIdHash, chainId, assetToken, versionNo));
    }
}
