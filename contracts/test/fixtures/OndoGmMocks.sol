// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IntegrationERC20Token} from "./IntegrationTokens.sol";

interface IOndoGmList {
    function isBlocked(address account) external view returns (bool);
    function isSanctioned(address account) external view returns (bool);
}

contract OndoGmListMock {
    mapping(address account => bool value) internal blocked;
    mapping(address account => bool value) internal sanctioned;
    bool internal exhaustGas;

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setSanctioned(address account, bool value) external {
        sanctioned[account] = value;
    }

    function setExhaustGas(bool value) external {
        exhaustGas = value;
    }

    function isBlocked(address account) external view returns (bool) {
        _maybeExhaustGas();
        return blocked[account];
    }

    function isSanctioned(address account) external view returns (bool) {
        _maybeExhaustGas();
        return sanctioned[account];
    }

    function _maybeExhaustGas() private view {
        if (!exhaustGas) return;
        while (gasleft() > 0) {}
    }
}

contract OndoGmPauseManagerMock {
    mapping(address token => bool value) internal paused;

    function setTokenPaused(address token, bool value) external {
        paused[token] = value;
    }

    function isTokenPaused(address token) external view returns (bool) {
        return paused[token];
    }
}

contract OndoComplianceMock {
    mapping(address identifier => address provider) public rwaTokenToBlocklist;
    mapping(address identifier => address provider) public rwaTokenToSanctionsList;

    function configure(address identifier, address blocklist, address sanctionsList) external {
        rwaTokenToBlocklist[identifier] = blocklist;
        rwaTokenToSanctionsList[identifier] = sanctionsList;
    }

    function checkIsCompliant(address identifier, address account) external view {
        address blocklist = rwaTokenToBlocklist[identifier];
        address sanctionsList = rwaTokenToSanctionsList[identifier];
        if (blocklist != address(0) && IOndoGmList(blocklist).isBlocked(account)) revert("BLOCKED");
        if (sanctionsList != address(0) && IOndoGmList(sanctionsList).isSanctioned(account)) revert("SANCTIONED");
    }
}

contract OndoComplianceViewMock {
    address public compliance;
    address public gmIdentifier;

    constructor(address compliance_, address gmIdentifier_) {
        compliance = compliance_;
        gmIdentifier = gmIdentifier_;
    }

    function configure(address compliance_, address gmIdentifier_) external {
        compliance = compliance_;
        gmIdentifier = gmIdentifier_;
    }

    function checkIsCompliant(address account) external view {
        OndoComplianceMock(compliance).checkIsCompliant(gmIdentifier, account);
    }
}

contract IntegrationOndoGmToken is IntegrationERC20Token {
    address public compliance;
    address public tokenPauseManager;
    bool internal forceTransferRevert;

    constructor(address compliance_, address tokenPauseManager_) IntegrationERC20Token(18) {
        compliance = compliance_;
        tokenPauseManager = tokenPauseManager_;
    }

    function configureProviders(address compliance_, address tokenPauseManager_) external {
        compliance = compliance_;
        tokenPauseManager = tokenPauseManager_;
    }

    function setForceTransferRevert(bool value) external {
        forceTransferRevert = value;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!forceTransferRevert, "ISSUER_RULE");
        require(!OndoGmPauseManagerMock(tokenPauseManager).isTokenPaused(address(this)), "PAUSED");
        if (from != msg.sender && to != msg.sender) OndoComplianceViewMock(compliance).checkIsCompliant(msg.sender);
        OndoComplianceViewMock(compliance).checkIsCompliant(from);
        OndoComplianceViewMock(compliance).checkIsCompliant(to);
        return super.transferFrom(from, to, value);
    }
}
