// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {IAllowlist, IBlocklist, ISanctionsList} from "src/adapters/UsdyRestrictedAdapter.sol";
import {IntegrationUpgradeableUsdyToken} from "./IntegrationTokens.sol";

contract OfficialUsdyBehaviorMock is IntegrationUpgradeableUsdyToken {
    address public admin;

    function initialize(address blocklist_, address allowlist_, address sanctionsList_) public override {
        super.initialize(blocklist_, allowlist_, sanctionsList_);
        admin = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == admin, "NOT_ADMIN");
        balanceOf[to] += amount;
    }

    function configureProviders(address blocklist_, address allowlist_, address sanctionsList_) public override {
        require(msg.sender == admin, "NOT_ADMIN");
        super.configureProviders(blocklist_, allowlist_, sanctionsList_);
    }

    function setPaused(bool value) public override {
        require(msg.sender == admin, "NOT_ADMIN");
        super.setPaused(value);
    }

    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) public pure override {
        revert("USDY: permit unsupported");
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!pausedValue, "USDY: paused");
        if (from != msg.sender && to != msg.sender) {
            _requireAccount(msg.sender, "'sender'");
        }
        if (from != address(0)) {
            _requireAccount(from, "'from'");
        }
        if (to != address(0)) {
            _requireAccount(to, "'to'");
        }
        return super.transferFrom(from, to, value);
    }

    function _requireAccount(address account, string memory label) private view {
        require(!IBlocklist(blocklistValue).isBlocked(account), string.concat("USDY: ", label, " address blocked"));
        require(
            !ISanctionsList(sanctionsListValue).isSanctioned(account),
            string.concat("USDY: ", label, " address sanctioned")
        );
        require(
            IAllowlist(allowlistValue).isAllowed(account), string.concat("USDY: ", label, " address not on allowlist")
        );
    }
}
