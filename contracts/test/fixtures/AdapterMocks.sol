// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

contract RevertingTokenProbe {
    fallback() external {
        revert();
    }
}

contract ERC1404TokenMock {
    uint256 internal restrictionCode;

    function setRestrictionCode(uint256 value) external {
        restrictionCode = value;
    }

    function detectTransferRestriction(address, address, uint256) external view returns (uint256) {
        return restrictionCode;
    }
}

contract MalformedERC1404Token {
    enum Mode {
        NORMAL,
        REVERT_CALL,
        SHORT_RETURN,
        LONG_RETURN,
        EXHAUST_GAS
    }

    Mode internal mode;
    uint256 internal restrictionCode;

    function configure(Mode newMode, uint256 newRestrictionCode) external {
        mode = newMode;
        restrictionCode = newRestrictionCode;
    }

    function detectTransferRestriction(address, address, uint256) external view returns (uint256 result) {
        if (mode == Mode.REVERT_CALL) revert();
        if (mode == Mode.EXHAUST_GAS) {
            uint256 accumulator;
            while (gasleft() > 0) {
                unchecked {
                    ++accumulator;
                }
            }
            return accumulator;
        }

        result = restrictionCode;
        if (mode == Mode.SHORT_RETURN) {
            assembly ("memory-safe") {
                mstore(0, result)
                return(0, 31)
            }
        }
        if (mode == Mode.LONG_RETURN) {
            assembly ("memory-safe") {
                mstore(0, result)
                return(0, 33)
            }
        }
    }
}

contract GasFloorERC1404Token {
    uint256 internal minimumGas;

    function setMinimumGas(uint256 value) external {
        minimumGas = value;
    }

    function detectTransferRestriction(address, address, uint256) external view returns (uint256) {
        if (gasleft() < minimumGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        return 0;
    }
}

contract UsdyTokenMock {
    bool internal pausedValue;
    address internal blocklistValue;
    address internal allowlistValue;
    address internal sanctionsListValue;

    function configure(address blocklist_, address allowlist_, address sanctionsList_) external {
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

contract AddressListMock {
    mapping(address => bool) internal blocked;
    mapping(address => bool) internal allowed;
    mapping(address => bool) internal sanctioned;

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setAllowed(address account, bool value) external {
        allowed[account] = value;
    }

    function setSanctioned(address account, bool value) external {
        sanctioned[account] = value;
    }

    function isBlocked(address account) external view returns (bool) {
        return blocked[account];
    }

    function isAllowed(address account) external view returns (bool) {
        return allowed[account];
    }

    function isSanctioned(address account) external view returns (bool) {
        return sanctioned[account];
    }
}
