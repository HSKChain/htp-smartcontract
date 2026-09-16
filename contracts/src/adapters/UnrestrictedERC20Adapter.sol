// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";
import {InterfaceVersions} from "../interfaces/InterfaceVersions.sol";
import {AdapterInputValidation} from "../libraries/AdapterInputValidation.sol";
import {AdapterReasonCodes} from "../libraries/AdapterReasonCodes.sol";
import {HTPHashing} from "../libraries/HTPHashing.sol";
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

contract UnrestrictedERC20Adapter is IAssetAdapter {
    uint256 private constant TRANSFER_LEG_MASK = (uint256(1) << uint8(TransferLeg.ASSET))
        | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_SELLER))
        | (uint256(1) << uint8(TransferLeg.SETTLEMENT_TO_COLLECTOR));

    address private immutable APPROVED_DVP;

    constructor(address approvedDvp) {
        APPROVED_DVP = approvedDvp;
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

    function providerHash() external pure returns (bytes32) {
        RestrictionProviderSet memory providerSet = RestrictionProviderSet({providers: new RestrictionProvider[](0)});
        return HTPHashing.hashRestrictionProviderSet(providerSet);
    }

    /// @notice Pre-check for unrestricted ERC20 legs; only the approved DvP may call.
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

        return (Decision.PASS, 0, bytes32(0));
    }

    function _capabilities() private pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            precheckMethod: PrecheckMethod.NO_PRECHECK,
            transferLegMask: TRANSFER_LEG_MASK
        });
    }
}
