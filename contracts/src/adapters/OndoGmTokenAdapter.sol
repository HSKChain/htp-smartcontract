// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {AdapterInputValidation} from "../libraries/AdapterInputValidation.sol";
import {AdapterReasonCodes} from "../libraries/AdapterReasonCodes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {ProtocolSecurityLimits} from "../libraries/ProtocolSecurityLimits.sol";
import {RestrictionProviderLib} from "../libraries/RestrictionProviderLib.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    RestrictionProvider,
    TokenStandard,
    TransferLeg
} from "../types/HTPTypes.sol";

interface IOndoGmToken {
    function compliance() external view returns (address);
    function tokenPauseManager() external view returns (address);
}

interface IOndoGmComplianceView {
    function compliance() external view returns (address);
    function gmIdentifier() external view returns (address);
}

interface IOndoCompliance {
    function rwaTokenToBlocklist(address rwaToken) external view returns (address);
    function rwaTokenToSanctionsList(address rwaToken) external view returns (address);
}

interface IOndoTokenPauseManager {
    function isTokenPaused(address token) external view returns (bool);
}

interface IOndoBlocklist {
    function isBlocked(address account) external view returns (bool);
}

interface IOndoSanctionsList {
    function isSanctioned(address account) external view returns (bool);
}

contract OndoGmTokenAdapter is IAssetAdapter {
    struct AccountRestrictionReasons {
        uint256 blockedCode;
        bytes32 blockedReason;
        uint256 sanctionedCode;
        bytes32 sanctionedReason;
    }

    struct PinnedProviderGraph {
        address complianceView;
        bytes32 complianceViewCodeHash;
        address compliance;
        bytes32 complianceCodeHash;
        address pauseManager;
        bytes32 pauseManagerCodeHash;
        address blocklist;
        bytes32 blocklistCodeHash;
        address sanctionsList;
        bytes32 sanctionsListCodeHash;
    }

    uint256 private constant TRANSFER_LEG_MASK = uint256(1) << uint8(TransferLeg.ASSET);
    address private constant EXPECTED_GM_IDENTIFIER =
        address(uint160(uint256(keccak256(abi.encodePacked("global_markets")))));

    address private immutable APPROVED_DVP;
    // One adapter serves every registered token with this runtime and the pinned provider graph.
    bytes32 private immutable APPROVED_TOKEN_CODE_HASH;
    address private immutable APPROVED_COMPLIANCE_VIEW;
    bytes32 private immutable APPROVED_COMPLIANCE_VIEW_CODE_HASH;
    address private immutable APPROVED_COMPLIANCE;
    bytes32 private immutable APPROVED_COMPLIANCE_CODE_HASH;
    address private immutable APPROVED_PAUSE_MANAGER;
    bytes32 private immutable APPROVED_PAUSE_MANAGER_CODE_HASH;
    address private immutable APPROVED_BLOCKLIST;
    bytes32 private immutable APPROVED_BLOCKLIST_CODE_HASH;
    address private immutable APPROVED_SANCTIONS_LIST;
    bytes32 private immutable APPROVED_SANCTIONS_LIST_CODE_HASH;
    bytes32 private immutable PROVIDER_HASH;
    uint256 private immutable PROVIDER_CALL_GAS;

    error InvalidOndoGmProvider(address provider);
    error OndoGmIdentifierMismatch(address expected, address actual);
    error OndoGmTokenCodeHashMismatch(bytes32 expected, bytes32 actual);

    constructor(address approvedDvp, address referenceToken, bytes32 approvedTokenCodeHash, uint256 providerCallGas) {
        ProtocolSecurityLimits.requireValidAdapterProviderCallGas(providerCallGas);
        bytes32 tokenCodeHash = _requireProvider(referenceToken);
        if (tokenCodeHash != approvedTokenCodeHash) {
            revert OndoGmTokenCodeHashMismatch(approvedTokenCodeHash, tokenCodeHash);
        }

        PinnedProviderGraph memory graph;
        graph.complianceView = IOndoGmToken(referenceToken).compliance();
        graph.pauseManager = IOndoGmToken(referenceToken).tokenPauseManager();
        graph.complianceViewCodeHash = _requireProvider(graph.complianceView);
        graph.pauseManagerCodeHash = _requireProvider(graph.pauseManager);

        graph.compliance = IOndoGmComplianceView(graph.complianceView).compliance();
        address gmIdentifier = IOndoGmComplianceView(graph.complianceView).gmIdentifier();
        if (gmIdentifier != EXPECTED_GM_IDENTIFIER) {
            revert OndoGmIdentifierMismatch(EXPECTED_GM_IDENTIFIER, gmIdentifier);
        }
        graph.complianceCodeHash = _requireProvider(graph.compliance);

        graph.blocklist = IOndoCompliance(graph.compliance).rwaTokenToBlocklist(gmIdentifier);
        graph.sanctionsList = IOndoCompliance(graph.compliance).rwaTokenToSanctionsList(gmIdentifier);
        graph.blocklistCodeHash = _requireProvider(graph.blocklist);
        graph.sanctionsListCodeHash = _requireProvider(graph.sanctionsList);

        APPROVED_DVP = approvedDvp;
        APPROVED_TOKEN_CODE_HASH = tokenCodeHash;
        APPROVED_COMPLIANCE_VIEW = graph.complianceView;
        APPROVED_COMPLIANCE_VIEW_CODE_HASH = graph.complianceViewCodeHash;
        APPROVED_COMPLIANCE = graph.compliance;
        APPROVED_COMPLIANCE_CODE_HASH = graph.complianceCodeHash;
        APPROVED_PAUSE_MANAGER = graph.pauseManager;
        APPROVED_PAUSE_MANAGER_CODE_HASH = graph.pauseManagerCodeHash;
        APPROVED_BLOCKLIST = graph.blocklist;
        APPROVED_BLOCKLIST_CODE_HASH = graph.blocklistCodeHash;
        APPROVED_SANCTIONS_LIST = graph.sanctionsList;
        APPROVED_SANCTIONS_LIST_CODE_HASH = graph.sanctionsListCodeHash;
        PROVIDER_CALL_GAS = providerCallGas;
        PROVIDER_HASH = _providerHash(referenceToken, tokenCodeHash, graph);
    }

    function _providerHash(address referenceToken, bytes32 tokenCodeHash, PinnedProviderGraph memory graph)
        private
        pure
        returns (bytes32)
    {
        RestrictionProvider[] memory providers = new RestrictionProvider[](9);
        providers[0] = RestrictionProvider({
            provider: referenceToken, selector: IOndoGmToken.compliance.selector, codeHash: tokenCodeHash
        });
        providers[1] = RestrictionProvider({
            provider: referenceToken, selector: IOndoGmToken.tokenPauseManager.selector, codeHash: tokenCodeHash
        });
        providers[2] = RestrictionProvider({
            provider: graph.complianceView,
            selector: IOndoGmComplianceView.compliance.selector,
            codeHash: graph.complianceViewCodeHash
        });
        providers[3] = RestrictionProvider({
            provider: graph.complianceView,
            selector: IOndoGmComplianceView.gmIdentifier.selector,
            codeHash: graph.complianceViewCodeHash
        });
        providers[4] = RestrictionProvider({
            provider: graph.compliance,
            selector: IOndoCompliance.rwaTokenToBlocklist.selector,
            codeHash: graph.complianceCodeHash
        });
        providers[5] = RestrictionProvider({
            provider: graph.compliance,
            selector: IOndoCompliance.rwaTokenToSanctionsList.selector,
            codeHash: graph.complianceCodeHash
        });
        providers[6] = RestrictionProvider({
            provider: graph.pauseManager,
            selector: IOndoTokenPauseManager.isTokenPaused.selector,
            codeHash: graph.pauseManagerCodeHash
        });
        providers[7] = RestrictionProvider({
            provider: graph.blocklist, selector: IOndoBlocklist.isBlocked.selector, codeHash: graph.blocklistCodeHash
        });
        providers[8] = RestrictionProvider({
            provider: graph.sanctionsList,
            selector: IOndoSanctionsList.isSanctioned.selector,
            codeHash: graph.sanctionsListCodeHash
        });
        return RestrictionProviderLib.canonicalHash(providers);
    }

    function interfaceVersion() external pure returns (bytes32) {
        return InterfaceVersions.ASSET_ADAPTER_V1;
    }

    function capabilities() external pure returns (AdapterCapabilities memory) {
        return _capabilities();
    }

    function capabilityHash() external pure returns (bytes32) {
        return HTPHashing.hashAdapterCapabilities(_capabilities());
    }

    function providerHash() external view returns (bytes32) {
        return PROVIDER_HASH;
    }

    function preCheck(address token, address from, address to, uint256, TransferLeg leg, bytes32 contextHash)
        external
        view
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        if (msg.sender != APPROVED_DVP) {
            return (Decision.BLOCK, AdapterReasonCodes.UNAPPROVED_CALLER, AdapterReasonCodes.UNAPPROVED_CALLER_REASON);
        }
        if (AdapterInputValidation.isInvalid(token, from, to, leg, contextHash, TRANSFER_LEG_MASK)) {
            return (Decision.BLOCK, AdapterReasonCodes.INVALID_INPUT, AdapterReasonCodes.INVALID_INPUT_REASON);
        }
        if (token.codehash != APPROVED_TOKEN_CODE_HASH) {
            return (Decision.UNKNOWN, 0, AdapterReasonCodes.PROVIDER_MISMATCH_REASON);
        }

        (bool providersReadable, bool providersMatch) = _providersMatch(token);
        if (!providersReadable) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);
        if (!providersMatch) return (Decision.UNKNOWN, 0, AdapterReasonCodes.PROVIDER_MISMATCH_REASON);

        (bool pauseReadable, bool paused) =
            _readBool(APPROVED_PAUSE_MANAGER, abi.encodeCall(IOndoTokenPauseManager.isTokenPaused, (token)));
        if (!pauseReadable) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);
        if (paused) {
            return
                (
                    Decision.BLOCK,
                    AdapterReasonCodes.ONDO_GM_TOKEN_PAUSED,
                    AdapterReasonCodes.ONDO_GM_TOKEN_PAUSED_REASON
                );
        }

        (decision, restrictionCode, reasonHash) = _checkAccount(
            from,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.ONDO_GM_FROM_BLOCKED,
                blockedReason: AdapterReasonCodes.ONDO_GM_FROM_BLOCKED_REASON,
                sanctionedCode: AdapterReasonCodes.ONDO_GM_FROM_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.ONDO_GM_FROM_SANCTIONED_REASON
            })
        );
        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);

        (decision, restrictionCode, reasonHash) = _checkAccount(
            to,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.ONDO_GM_TO_BLOCKED,
                blockedReason: AdapterReasonCodes.ONDO_GM_TO_BLOCKED_REASON,
                sanctionedCode: AdapterReasonCodes.ONDO_GM_TO_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.ONDO_GM_TO_SANCTIONED_REASON
            })
        );
        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);

        (decision, restrictionCode, reasonHash) = _checkAccount(
            msg.sender,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.ONDO_GM_CALLER_BLOCKED,
                blockedReason: AdapterReasonCodes.ONDO_GM_CALLER_BLOCKED_REASON,
                sanctionedCode: AdapterReasonCodes.ONDO_GM_CALLER_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.ONDO_GM_CALLER_SANCTIONED_REASON
            })
        );
        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);
        return (Decision.PASS, 0, bytes32(0));
    }

    function _providersMatch(address token) private view returns (bool readable, bool matches) {
        (bool ok, address provider) = _readAddress(token, abi.encodeCall(IOndoGmToken.compliance, ()));
        if (!ok) return (false, false);
        if (provider != APPROVED_COMPLIANCE_VIEW || provider.codehash != APPROVED_COMPLIANCE_VIEW_CODE_HASH) {
            return (true, false);
        }

        (ok, provider) = _readAddress(token, abi.encodeCall(IOndoGmToken.tokenPauseManager, ()));
        if (!ok) return (false, false);
        if (provider != APPROVED_PAUSE_MANAGER || provider.codehash != APPROVED_PAUSE_MANAGER_CODE_HASH) {
            return (true, false);
        }

        (ok, provider) = _readAddress(APPROVED_COMPLIANCE_VIEW, abi.encodeCall(IOndoGmComplianceView.compliance, ()));
        if (!ok) return (false, false);
        if (provider != APPROVED_COMPLIANCE || provider.codehash != APPROVED_COMPLIANCE_CODE_HASH) {
            return (true, false);
        }

        (ok, provider) = _readAddress(APPROVED_COMPLIANCE_VIEW, abi.encodeCall(IOndoGmComplianceView.gmIdentifier, ()));
        if (!ok) return (false, false);
        if (provider != EXPECTED_GM_IDENTIFIER) return (true, false);

        (ok, provider) = _readAddress(
            APPROVED_COMPLIANCE, abi.encodeCall(IOndoCompliance.rwaTokenToBlocklist, (EXPECTED_GM_IDENTIFIER))
        );
        if (!ok) return (false, false);
        if (provider != APPROVED_BLOCKLIST || provider.codehash != APPROVED_BLOCKLIST_CODE_HASH) {
            return (true, false);
        }

        (ok, provider) = _readAddress(
            APPROVED_COMPLIANCE, abi.encodeCall(IOndoCompliance.rwaTokenToSanctionsList, (EXPECTED_GM_IDENTIFIER))
        );
        if (!ok) return (false, false);
        return (
            true,
            provider == APPROVED_SANCTIONS_LIST && provider.codehash == APPROVED_SANCTIONS_LIST_CODE_HASH
                && APPROVED_PAUSE_MANAGER.codehash == APPROVED_PAUSE_MANAGER_CODE_HASH
        );
    }

    function _checkAccount(address account, AccountRestrictionReasons memory reasons)
        private
        view
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        (bool ok, bool restricted) = _readBool(APPROVED_BLOCKLIST, abi.encodeCall(IOndoBlocklist.isBlocked, (account)));
        if (!ok) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);
        if (restricted) return (Decision.BLOCK, reasons.blockedCode, reasons.blockedReason);

        (ok, restricted) =
            _readBool(APPROVED_SANCTIONS_LIST, abi.encodeCall(IOndoSanctionsList.isSanctioned, (account)));
        if (!ok) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);
        if (restricted) return (Decision.BLOCK, reasons.sanctionedCode, reasons.sanctionedReason);
        return (Decision.PASS, 0, bytes32(0));
    }

    function _readBool(address target, bytes memory callData) private view returns (bool ok, bool value) {
        bytes32 result;
        (ok, result) = BoundedStaticCall.staticCallWord(target, callData, PROVIDER_CALL_GAS);
        if (!ok || uint256(result) > 1) return (false, false);
        return (true, result != bytes32(0));
    }

    function _readAddress(address target, bytes memory callData) private view returns (bool ok, address value) {
        bytes32 result;
        (ok, result) = BoundedStaticCall.staticCallWord(target, callData, PROVIDER_CALL_GAS);
        if (!ok || uint256(result) > type(uint160).max || result == bytes32(0)) {
            return (false, address(0));
        }
        return (true, address(uint160(uint256(result))));
    }

    function _requireProvider(address provider) private view returns (bytes32 codeHash) {
        if (provider == address(0) || provider.code.length == 0) revert InvalidOndoGmProvider(provider);
        codeHash = provider.codehash;
    }

    function _capabilities() private pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.TOKEN_ENFORCED,
            precheckMethod: PrecheckMethod.TOKEN_SPECIFIC_CHECK,
            transferLegMask: TRANSFER_LEG_MASK
        });
    }
}
