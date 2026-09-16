// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IDvPGovernanceView} from "../interfaces/IDvPGovernanceView.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {Roles} from "../libraries/Roles.sol";
import {HTPErrors} from "../types/HTPErrors.sol";
import {HTPEvents} from "../types/HTPEvents.sol";
import {ReasonCode} from "../types/HTPTypes.sol";

abstract contract UUPSRegistryBase is AccessControlUpgradeable, UUPSUpgradeable {
    uint256 public constant MAX_DEPENDENT_DVPS = 32;
    uint256 private constant DEPENDENT_DVP_CALL_GAS = 30_000;

    /// @custom:storage-location erc7201:htp.storage.UUPSRegistryBase
    struct RegistryBaseStorage {
        address[] dependentDvps;
        mapping(address dvp => bool registered) dependentDvpRegistered;
        mapping(address dvp => bool retiredExempt) dependentDvpRetiredExempt;
        uint256 defaultAdminCount;
    }

    // keccak256(abi.encode(uint256(keccak256("htp.storage.UUPSRegistryBase")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REGISTRY_BASE_STORAGE_LOCATION =
        0xafc6c3037b45832d571ada43a3f4e8693ce68a356d2fb4fa4bab4b27cdca1f00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _initializeRegistryBase(
        address defaultAdmin,
        address governance,
        address upgrader,
        address pauser,
        address configurer
    ) internal onlyInitializing {
        _requireRoleHolder(Roles.DEFAULT_ADMIN_ROLE, defaultAdmin);
        _requireRoleHolder(Roles.GOVERNANCE_ROLE, governance);
        _requireRoleHolder(Roles.UPGRADER_ROLE, upgrader);
        _requireRoleHolder(Roles.PAUSER_ROLE, pauser);
        _requireRoleHolder(Roles.CONFIGURER_ROLE, configurer);
        __AccessControl_init();

        _grantRole(Roles.DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(Roles.GOVERNANCE_ROLE, governance);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        _grantRole(Roles.PAUSER_ROLE, pauser);
        _grantRole(Roles.CONFIGURER_ROLE, configurer);
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == Roles.DEFAULT_ADMIN_ROLE) ++_getRegistryBaseStorage().defaultAdminCount;
    }

    /// @dev Prevents removal of the last default admin.
    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        RegistryBaseStorage storage $ = _getRegistryBaseStorage();
        if (role == Roles.DEFAULT_ADMIN_ROLE && $.defaultAdminCount == 1 && hasRole(role, account)) {
            revert HTPErrors.LastDefaultAdminCannotBeRemoved(account);
        }
        revoked = super._revokeRole(role, account);
        if (revoked && role == Roles.DEFAULT_ADMIN_ROLE) --$.defaultAdminCount;
    }

    /// @dev Upgrade allowed only when every non-exempt dependent DvP reports global pause.
    function _authorizeUpgrade(address) internal virtual override onlyRole(Roles.UPGRADER_ROLE) {
        RegistryBaseStorage storage $ = _getRegistryBaseStorage();
        uint256 count = $.dependentDvps.length;

        if (count == 0) revert HTPErrors.NoDependentDvpRegistered();
        for (uint256 i = 0; i < count; ++i) {
            address dvp = $.dependentDvps[i];
            if ($.dependentDvpRetiredExempt[dvp]) continue;

            (bool wellFormed, bool isPaused) = _strictBoolStaticCall(dvp, IDvPGovernanceView.globalPaused.selector);
            if (!wellFormed) revert HTPErrors.DependentDvpStatusMalformed(dvp);
            if (!isPaused) revert HTPErrors.DependentDvpNotPaused(dvp);
        }
    }

    /// @notice Registers a DvP that must be paused (or retired-exempt) before registry upgrade.
    function registerDependentDvp(address dvp, bytes32 evidenceHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        RegistryBaseStorage storage $ = _getRegistryBaseStorage();
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
        if (dvp == address(0) || dvp.code.length == 0) revert HTPErrors.InvalidDependentDvp(dvp);
        if ($.dependentDvpRegistered[dvp]) revert HTPErrors.DependentDvpAlreadyRegistered(dvp);
        if ($.dependentDvps.length >= MAX_DEPENDENT_DVPS) {
            revert HTPErrors.DependentDvpLimitReached(MAX_DEPENDENT_DVPS);
        }
        (bool pausedWellFormed,) = _strictBoolStaticCall(dvp, IDvPGovernanceView.globalPaused.selector);
        (bool retiredWellFormed, bool isRetired) = _strictBoolStaticCall(dvp, IDvPGovernanceView.retired.selector);
        if (!pausedWellFormed || !retiredWellFormed) revert HTPErrors.DvpInterfaceMismatch(dvp);

        if (isRetired) revert HTPErrors.DvpRetired(dvp);

        $.dependentDvpRegistered[dvp] = true;
        $.dependentDvps.push(dvp);
        emit HTPEvents.DependentDvpRegistered(block.chainid, dvp, evidenceHash, _msgSender());
    }

    /// @notice Returns the number of registered dependent DvP contracts.
    function getDependentDvpCount() external view returns (uint256) {
        return _getRegistryBaseStorage().dependentDvps.length;
    }

    /// @notice Marks a retired dependent DvP as exempt from upgrade pause checks.
    function exemptRetiredDependentDvp(address dvp, bytes32 evidenceHash) external onlyRole(Roles.GOVERNANCE_ROLE) {
        RegistryBaseStorage storage $ = _getRegistryBaseStorage();
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
        if (!$.dependentDvpRegistered[dvp]) revert HTPErrors.DependentDvpNotRegistered(dvp);
        if ($.dependentDvpRetiredExempt[dvp]) {
            revert HTPErrors.DependentDvpAlreadyRetiredExempt(dvp);
        }

        (bool wellFormed, bool isRetired) = _strictBoolStaticCall(dvp, IDvPGovernanceView.retired.selector);
        if (!wellFormed) revert HTPErrors.DependentDvpStatusMalformed(dvp);
        if (!isRetired) revert HTPErrors.DependentDvpNotRetired(dvp);

        $.dependentDvpRetiredExempt[dvp] = true;
        emit HTPEvents.DependentDvpRetiredExempted(block.chainid, dvp, evidenceHash, _msgSender());
    }

    /// @notice Returns a dependent DvP by index and its retired-exempt flag.
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt) {
        RegistryBaseStorage storage $ = _getRegistryBaseStorage();
        dvp = $.dependentDvps[index];
        retiredExempt = $.dependentDvpRetiredExempt[dvp];
    }

    function _isDependentDvpRegistered(address dvp) internal view returns (bool) {
        return _getRegistryBaseStorage().dependentDvpRegistered[dvp];
    }

    function _requireReasonAndEvidence(ReasonCode reason, bytes32 evidenceHash) internal pure {
        if (reason == ReasonCode.NONE) revert HTPErrors.ReasonCodeRequired(reason);
        if (evidenceHash == bytes32(0)) revert HTPErrors.EvidenceHashRequired();
    }

    function _getRegistryBaseStorage() private pure returns (RegistryBaseStorage storage $) {
        assembly {
            $.slot := REGISTRY_BASE_STORAGE_LOCATION
        }
    }

    function _requireRoleHolder(bytes32 role, address account) private pure {
        if (account == address(0)) revert HTPErrors.InvalidRoleHolder(role, account);
    }

    function _strictBoolStaticCall(address target, bytes4 selector) private view returns (bool wellFormed, bool value) {
        (bool success, bytes32 result) =
            BoundedStaticCall.staticCallWord(target, abi.encodeWithSelector(selector), DEPENDENT_DVP_CALL_GAS);
        uint256 word = uint256(result);
        wellFormed = success && word <= 1;
        value = word == 1;
    }
}
