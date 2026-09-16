// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

contract IntegrationERC20Token {
    uint8 internal decimalsValue;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;
    mapping(address account => uint256 value) public balanceOf;

    constructor(uint8 decimals_) {
        decimalsValue = decimals_;
    }

    function decimals() external view returns (uint8) {
        return decimalsValue;
    }

    function setDecimals(uint8 value) external {
        decimalsValue = value;
    }

    function setAllowance(address owner, address spender, uint256 value) external {
        allowance[owner][spender] = value;
    }

    function setBalance(address account, uint256 value) external {
        balanceOf[account] = value;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) public virtual {
        allowance[owner][spender] = value;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= value, "ALLOWANCE");
        require(balanceOf[from] >= value, "BALANCE");
        allowance[from][msg.sender] = currentAllowance - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }
}

contract IntegrationUsdyToken is IntegrationERC20Token {
    bool internal pausedValue;
    address internal blocklistValue;
    address internal allowlistValue;
    address internal sanctionsListValue;

    constructor() IntegrationERC20Token(18) {}

    function configureProviders(address blocklist_, address allowlist_, address sanctionsList_) external {
        blocklistValue = blocklist_;
        allowlistValue = allowlist_;
        sanctionsListValue = sanctionsList_;
    }

    function setPaused(bool value) external {
        pausedValue = value;
    }

    function paused() external view returns (bool) {
        return pausedValue;
    }

    function blocklist() external view returns (address) {
        return blocklistValue;
    }

    function allowlist() external view returns (address) {
        return allowlistValue;
    }

    function sanctionsList() external view returns (address) {
        return sanctionsListValue;
    }
}

contract IntegrationUpgradeableUsdyToken is IntegrationERC20Token {
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    bool internal initialized;
    bool internal pausedValue;
    address internal blocklistValue;
    address internal allowlistValue;
    address internal sanctionsListValue;

    constructor() IntegrationERC20Token(18) {}

    function initialize(address blocklist_, address allowlist_, address sanctionsList_) public virtual {
        require(!initialized, "INITIALIZED");
        initialized = true;
        decimalsValue = 18;
        blocklistValue = blocklist_;
        allowlistValue = allowlist_;
        sanctionsListValue = sanctionsList_;
    }

    function upgradeImplementation(address nextImplementation) external {
        require(nextImplementation.code.length != 0, "NO_CODE");
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            sstore(slot, nextImplementation)
        }
    }

    function implementationAddress() external view returns (address implementation) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            implementation := sload(slot)
        }
    }

    function configureProviders(address blocklist_, address allowlist_, address sanctionsList_) public virtual {
        blocklistValue = blocklist_;
        allowlistValue = allowlist_;
        sanctionsListValue = sanctionsList_;
    }

    function setPaused(bool value) public virtual {
        pausedValue = value;
    }

    function paused() external view returns (bool) {
        return pausedValue;
    }

    function blocklist() external view returns (address) {
        return blocklistValue;
    }

    function allowlist() external view returns (address) {
        return allowlistValue;
    }

    function sanctionsList() external view returns (address) {
        return sanctionsListValue;
    }
}

contract IntegrationUpgradeableUsdyTokenV2 is IntegrationUpgradeableUsdyToken {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }
}

contract IntegrationERC1404Token is IntegrationERC20Token {
    uint256 internal restrictionCode;
    address internal expectedFrom;
    address internal expectedTo;
    uint256 internal expectedAmount;
    bool internal enforceExpectedTransfer;

    constructor() IntegrationERC20Token(18) {}

    function setRestrictionCode(uint256 value) external {
        restrictionCode = value;
    }

    function configureExpectedTransfer(address from, address to, uint256 amount, bool enforce) external {
        expectedFrom = from;
        expectedTo = to;
        expectedAmount = amount;
        enforceExpectedTransfer = enforce;
    }

    function detectTransferRestriction(address from, address to, uint256 amount) external view returns (uint256) {
        if (enforceExpectedTransfer && (from != expectedFrom || to != expectedTo || amount != expectedAmount)) {
            return type(uint8).max;
        }
        return restrictionCode;
    }
}
