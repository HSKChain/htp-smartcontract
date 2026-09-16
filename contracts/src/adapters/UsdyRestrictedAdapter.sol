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

interface IUsdyRestrictionToken {
    function paused() external view returns (bool);
    function blocklist() external view returns (address);
    function allowlist() external view returns (address);
    function sanctionsList() external view returns (address);
}

interface IBlocklist {
    function isBlocked(address account) external view returns (bool);
}

interface IAllowlist {
    function isAllowed(address account) external view returns (bool);
}

interface ISanctionsList {
    function isSanctioned(address account) external view returns (bool);
}

contract UsdyRestrictedAdapter is IAssetAdapter {
    struct AccountRestrictionReasons {
        uint256 blockedCode;
        bytes32 blockedReason;
        uint256 notAllowedCode;
        bytes32 notAllowedReason;
        uint256 sanctionedCode;
        bytes32 sanctionedReason;
    }

    uint256 private constant TRANSFER_LEG_MASK = uint256(1) << uint8(TransferLeg.ASSET);

    address private immutable APPROVED_DVP;
    address private immutable APPROVED_TOKEN;
    bytes32 private immutable APPROVED_TOKEN_CODE_HASH;
    address private immutable APPROVED_BLOCKLIST;
    bytes32 private immutable APPROVED_BLOCKLIST_CODE_HASH;
    address private immutable APPROVED_ALLOWLIST;
    bytes32 private immutable APPROVED_ALLOWLIST_CODE_HASH;
    address private immutable APPROVED_SANCTIONS_LIST;
    bytes32 private immutable APPROVED_SANCTIONS_LIST_CODE_HASH;
    bytes32 private immutable PROVIDER_HASH;
    uint256 private immutable PROVIDER_CALL_GAS;

    constructor(
        address approvedDvp,
        address approvedToken,
        bytes32 approvedTokenCodeHash,
        address approvedBlocklist,
        bytes32 approvedBlocklistCodeHash,
        address approvedAllowlist,
        bytes32 approvedAllowlistCodeHash,
        address approvedSanctionsList,
        bytes32 approvedSanctionsListCodeHash,
        uint256 providerCallGas
    ) {
        ProtocolSecurityLimits.requireValidAdapterProviderCallGas(providerCallGas);
        APPROVED_DVP = approvedDvp;
        APPROVED_TOKEN = approvedToken;
        APPROVED_TOKEN_CODE_HASH = approvedTokenCodeHash;
        APPROVED_BLOCKLIST = approvedBlocklist;
        APPROVED_BLOCKLIST_CODE_HASH = approvedBlocklistCodeHash;
        APPROVED_ALLOWLIST = approvedAllowlist;
        APPROVED_ALLOWLIST_CODE_HASH = approvedAllowlistCodeHash;
        APPROVED_SANCTIONS_LIST = approvedSanctionsList;
        APPROVED_SANCTIONS_LIST_CODE_HASH = approvedSanctionsListCodeHash;
        PROVIDER_CALL_GAS = providerCallGas;

        RestrictionProvider[] memory providers = new RestrictionProvider[](7);
        // [0] Token.paused
        providers[0] = RestrictionProvider({
            provider: approvedToken, selector: IUsdyRestrictionToken.paused.selector, codeHash: approvedTokenCodeHash
        });

        providers[1] = RestrictionProvider({
            provider: approvedToken, selector: IUsdyRestrictionToken.blocklist.selector, codeHash: approvedTokenCodeHash
        });
        // [2] Token.allowlist
        providers[2] = RestrictionProvider({
            provider: approvedToken, selector: IUsdyRestrictionToken.allowlist.selector, codeHash: approvedTokenCodeHash
        });
        // [3] Token.sanctionsList
        providers[3] = RestrictionProvider({
            provider: approvedToken,
            selector: IUsdyRestrictionToken.sanctionsList.selector,
            codeHash: approvedTokenCodeHash
        });
        // [4] Blocklist.isBlocked
        providers[4] = RestrictionProvider({
            provider: approvedBlocklist, selector: IBlocklist.isBlocked.selector, codeHash: approvedBlocklistCodeHash
        });
        // [5] Allowlist.isAllowed
        providers[5] = RestrictionProvider({
            provider: approvedAllowlist, selector: IAllowlist.isAllowed.selector, codeHash: approvedAllowlistCodeHash
        });
        // [6] SanctionsList.isSanctioned
        providers[6] = RestrictionProvider({
            provider: approvedSanctionsList,
            selector: ISanctionsList.isSanctioned.selector,
            codeHash: approvedSanctionsListCodeHash
        });
        PROVIDER_HASH = RestrictionProviderLib.canonicalHash(providers);
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

    /// @notice Enforces USDY pause, list wiring, and block/allow/sanctions checks on from, to, and caller.
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

        if (token != APPROVED_TOKEN || token.codehash != APPROVED_TOKEN_CODE_HASH) {
            return (Decision.UNKNOWN, 0, AdapterReasonCodes.PROVIDER_MISMATCH_REASON);
        }

        (bool pausedOk, bool isPaused) = _readBool(token, abi.encodeCall(IUsdyRestrictionToken.paused, ()));

        if (!pausedOk) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);

        if (isPaused) {
            return (Decision.BLOCK, AdapterReasonCodes.USDY_TOKEN_PAUSED, AdapterReasonCodes.USDY_TOKEN_PAUSED_REASON);
        }

        (bool providersReadable, bool providersMatch) = _providersMatch(token);

        if (!providersReadable) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);

        if (!providersMatch) return (Decision.UNKNOWN, 0, AdapterReasonCodes.PROVIDER_MISMATCH_REASON);

        (decision, restrictionCode, reasonHash) = _checkAccount(
            from,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.USDY_FROM_BLOCKED,
                blockedReason: AdapterReasonCodes.USDY_FROM_BLOCKED_REASON,
                notAllowedCode: AdapterReasonCodes.USDY_FROM_NOT_ALLOWED,
                notAllowedReason: AdapterReasonCodes.USDY_FROM_NOT_ALLOWED_REASON,
                sanctionedCode: AdapterReasonCodes.USDY_FROM_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.USDY_FROM_SANCTIONED_REASON
            })
        );

        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);

        (decision, restrictionCode, reasonHash) = _checkAccount(
            to,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.USDY_TO_BLOCKED,
                blockedReason: AdapterReasonCodes.USDY_TO_BLOCKED_REASON,
                notAllowedCode: AdapterReasonCodes.USDY_TO_NOT_ALLOWED,
                notAllowedReason: AdapterReasonCodes.USDY_TO_NOT_ALLOWED_REASON,
                sanctionedCode: AdapterReasonCodes.USDY_TO_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.USDY_TO_SANCTIONED_REASON
            })
        );
        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);

        (decision, restrictionCode, reasonHash) = _checkAccount(
            msg.sender,
            AccountRestrictionReasons({
                blockedCode: AdapterReasonCodes.USDY_CALLER_BLOCKED,
                blockedReason: AdapterReasonCodes.USDY_CALLER_BLOCKED_REASON,
                notAllowedCode: AdapterReasonCodes.USDY_CALLER_NOT_ALLOWED,
                notAllowedReason: AdapterReasonCodes.USDY_CALLER_NOT_ALLOWED_REASON,
                sanctionedCode: AdapterReasonCodes.USDY_CALLER_SANCTIONED,
                sanctionedReason: AdapterReasonCodes.USDY_CALLER_SANCTIONED_REASON
            })
        );
        if (decision != Decision.PASS) return (decision, restrictionCode, reasonHash);

        return (Decision.PASS, 0, bytes32(0));
    }

    function _providersMatch(address token) private view returns (bool readable, bool matches) {
        (bool ok, address provider) = _readAddress(token, abi.encodeCall(IUsdyRestrictionToken.blocklist, ()));

        if (!ok) return (false, false);

        if (provider != APPROVED_BLOCKLIST || provider.codehash != APPROVED_BLOCKLIST_CODE_HASH) return (true, false);

        (ok, provider) = _readAddress(token, abi.encodeCall(IUsdyRestrictionToken.allowlist, ()));
        if (!ok) return (false, false);

        if (provider != APPROVED_ALLOWLIST || provider.codehash != APPROVED_ALLOWLIST_CODE_HASH) return (true, false);

        (ok, provider) = _readAddress(token, abi.encodeCall(IUsdyRestrictionToken.sanctionsList, ()));
        if (!ok) return (false, false);

        return (true, provider == APPROVED_SANCTIONS_LIST && provider.codehash == APPROVED_SANCTIONS_LIST_CODE_HASH);
    }

    function _checkAccount(address account, AccountRestrictionReasons memory reasons)
        private
        view
        returns (Decision decision, uint256 restrictionCode, bytes32 reasonHash)
    {
        (bool ok, bool value) = _readBool(APPROVED_BLOCKLIST, abi.encodeCall(IBlocklist.isBlocked, (account)));

        if (!ok) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);

        if (value) {
            return (Decision.BLOCK, reasons.blockedCode, reasons.blockedReason);
        }

        (ok, value) = _readBool(APPROVED_ALLOWLIST, abi.encodeCall(IAllowlist.isAllowed, (account)));
        if (!ok) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);

        if (!value) {
            return (Decision.BLOCK, reasons.notAllowedCode, reasons.notAllowedReason);
        }

        (ok, value) = _readBool(APPROVED_SANCTIONS_LIST, abi.encodeCall(ISanctionsList.isSanctioned, (account)));
        if (!ok) return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);

        if (value) {
            return (Decision.BLOCK, reasons.sanctionedCode, reasons.sanctionedReason);
        }
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

    function _capabilities() private pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.TOKEN_ENFORCED,
            precheckMethod: PrecheckMethod.TOKEN_SPECIFIC_CHECK,
            transferLegMask: TRANSFER_LEG_MASK
        });
    }
}
