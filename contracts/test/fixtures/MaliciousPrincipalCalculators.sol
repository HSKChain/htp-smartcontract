// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {AssetClass} from "../../src/types/HTPTypes.sol";

abstract contract MaliciousCalculatorShape {
    function interfaceVersion() external pure returns (bytes32) {
        return keccak256("HTP_IPRINCIPAL_CALCULATOR_V1");
    }

    function assetClass() external pure returns (AssetClass) {
        return AssetClass.FUND;
    }
}

contract ExtraSelectorCalculator is MaliciousCalculatorShape {
    function calculate(bytes calldata, uint256, uint8) external pure returns (bytes32, uint256, uint256) {
        return (bytes32(0), 1, 1);
    }

    function unexpectedExternalEntryPoint() external pure returns (bool) {
        return true;
    }
}

contract FallbackCalculator is MaliciousCalculatorShape {
    function calculate(bytes calldata, uint256, uint8) external pure returns (bytes32, uint256, uint256) {
        return (bytes32(0), 1, 1);
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract StatefulCalculator is MaliciousCalculatorShape {
    uint256 private stored;

    function calculate(bytes calldata, uint256, uint8) external returns (bytes32, uint256, uint256) {
        stored += 1;
        return (bytes32(0), stored, stored);
    }
}

contract DelegatecallCalculator is MaliciousCalculatorShape {
    function calculate(bytes calldata, uint256, uint8) external returns (bytes32, uint256, uint256) {
        (bool success,) = address(this).delegatecall(abi.encodeWithSignature("interfaceVersion()"));
        return (bytes32(0), success ? 1 : 0, 1);
    }
}

contract ExternalReadCalculator is MaliciousCalculatorShape {
    function calculate(bytes calldata, uint256, uint8) external view returns (bytes32, uint256, uint256) {
        (bool success,) = address(1).staticcall("");
        return (bytes32(0), success ? 1 : 0, 1);
    }
}

contract BlockEnvironmentCalculator is MaliciousCalculatorShape {
    function calculate(bytes calldata, uint256, uint8) external view returns (bytes32, uint256, uint256) {
        return (bytes32(0), block.timestamp, block.number);
    }
}
