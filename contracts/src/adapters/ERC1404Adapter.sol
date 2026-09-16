// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {AdapterInputValidation} from "../libraries/AdapterInputValidation.sol";
import {AdapterReasonCodes} from "../libraries/AdapterReasonCodes.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
import {ProtocolSecurityLimits} from "../libraries/ProtocolSecurityLimits.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    RestrictionProvider,
    RestrictionProviderSet,
    TokenStandard,
    TransferLeg
} from "../types/HTPTypes.sol";

interface IERC1404Restriction {
    function detectTransferRestriction(address from, address to, uint256 amount) external view returns (uint256);
}

contract ERC1404Adapter is IAssetAdapter {
    uint256 private constant TRANSFER_LEG_MASK = uint256(1) << uint8(TransferLeg.ASSET);

    bytes4 private constant INTERFACE_PROBE_SELECTOR =
        bytes4(keccak256("htpErc1404InterfaceProbe(address,address,uint256)"));

    address private immutable APPROVED_DVP;
    address private immutable APPROVED_TOKEN;
    bytes32 private immutable APPROVED_TOKEN_CODE_HASH;
    bytes32 private immutable PROVIDER_HASH;
    uint256 private immutable PROVIDER_CALL_GAS;

    constructor(address approvedDvp, address approvedToken, bytes32 approvedTokenCodeHash, uint256 providerCallGas) {
        ProtocolSecurityLimits.requireValidAdapterProviderCallGas(providerCallGas);

        if (approvedToken.code.length != 0 && _hasPermissiveFallback(approvedToken, providerCallGas)) {
            revert HTPErrors.AdapterProviderInterfaceMissing(approvedToken, INTERFACE_PROBE_SELECTOR);
        }
        APPROVED_DVP = approvedDvp;
        APPROVED_TOKEN = approvedToken;
        APPROVED_TOKEN_CODE_HASH = approvedTokenCodeHash;
        PROVIDER_CALL_GAS = providerCallGas;

        RestrictionProvider[] memory providers = new RestrictionProvider[](1);
        providers[0] = RestrictionProvider({
            provider: approvedToken,
            selector: IERC1404Restriction.detectTransferRestriction.selector,
            codeHash: approvedTokenCodeHash
        });
        PROVIDER_HASH = HTPHashing.hashRestrictionProviderSet(RestrictionProviderSet({providers: providers}));
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

    /// @notice Runs ERC-1404 detectTransferRestriction for the approved token and transfer amount.
    function preCheck(address token, address from, address to, uint256 amount, TransferLeg leg, bytes32 contextHash)
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

        if (_hasPermissiveFallback(token, PROVIDER_CALL_GAS)) {
            return (Decision.UNKNOWN, 0, AdapterReasonCodes.PROVIDER_INTERFACE_MISSING_REASON);
        }

        (bool success, bytes32 result) = BoundedStaticCall.staticCallWord(
            token,
            abi.encodeWithSelector(IERC1404Restriction.detectTransferRestriction.selector, from, to, amount),
            PROVIDER_CALL_GAS
        );

        if (!success || uint256(result) > type(uint8).max) {
            return (Decision.UNKNOWN, 0, AdapterReasonCodes.EXTERNAL_CALL_FAILED_REASON);
        }

        restrictionCode = uint256(result);

        if (restrictionCode == 0) {
            return (Decision.PASS, 0, bytes32(0));
        }

        return (Decision.BLOCK, restrictionCode, AdapterReasonCodes.erc1404RestrictionReason(restrictionCode));
    }

    function _hasPermissiveFallback(address token, uint256 gasLimit) private view returns (bool) {
        (bool success,) = BoundedStaticCall.staticCallWord(
            token, abi.encodeWithSelector(INTERFACE_PROBE_SELECTOR, address(0), address(0), uint256(0)), gasLimit
        );
        return success;
    }

    function _capabilities() private pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC1404,
            restrictionMode: RestrictionMode.ISSUER_EXTERNAL,
            precheckMethod: PrecheckMethod.ERC1404_CHECK,
            transferLegMask: TRANSFER_LEG_MASK
        });
    }
}
