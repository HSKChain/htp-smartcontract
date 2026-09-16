// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AdapterCapabilities,
    Decision,
    PrecheckMethod,
    RestrictionMode,
    TokenStandard,
    TransferLeg
} from "../../src/types/HTPTypes.sol";

abstract contract MaliciousAdapterShape {
    function interfaceVersion() external pure returns (bytes32) {
        return keccak256("HTP_IASSET_ADAPTER_V1");
    }

    function capabilities() external pure returns (AdapterCapabilities memory) {
        return AdapterCapabilities({
            tokenStandard: TokenStandard.ERC20,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            precheckMethod: PrecheckMethod.NO_PRECHECK,
            transferLegMask: 14
        });
    }

    function capabilityHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function providerHash() external pure returns (bytes32) {
        return bytes32(uint256(2));
    }
}

contract ExtraSelectorAdapter is MaliciousAdapterShape {
    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        pure
        returns (Decision, uint256, bytes32)
    {
        return (Decision.PASS, 0, bytes32(0));
    }

    function unexpectedExternalEntryPoint() external pure returns (bool) {
        return true;
    }
}

contract FallbackAdapter is MaliciousAdapterShape {
    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        pure
        returns (Decision, uint256, bytes32)
    {
        return (Decision.PASS, 0, bytes32(0));
    }

    fallback() external {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract StatefulAdapter is MaliciousAdapterShape {
    uint256 private stored;

    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        returns (Decision, uint256, bytes32)
    {
        stored += 1;
        return (Decision.PASS, stored, bytes32(0));
    }
}

contract DelegatecallAdapter is MaliciousAdapterShape {
    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        returns (Decision, uint256, bytes32)
    {
        (bool success,) = address(this).delegatecall(abi.encodeWithSignature("interfaceVersion()"));
        return (success ? Decision.PASS : Decision.UNKNOWN, 0, bytes32(0));
    }
}

contract TransferAdapter is MaliciousAdapterShape {
    function preCheck(address token, address, address to, uint256 amount, TransferLeg, bytes32)
        external
        returns (Decision, uint256, bytes32)
    {
        (bool success,) = token.call(abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount));
        return (success ? Decision.PASS : Decision.UNKNOWN, 0, bytes32(0));
    }
}

contract ArbitraryStaticcallAdapter is MaliciousAdapterShape {
    function preCheck(address token, address, address, uint256, TransferLeg, bytes32 contextHash)
        external
        view
        returns (Decision, uint256, bytes32)
    {
        (bool success,) = token.staticcall(abi.encodePacked(contextHash));
        return (success ? Decision.PASS : Decision.UNKNOWN, 0, bytes32(0));
    }
}

contract WrongReturnAbiAdapter is MaliciousAdapterShape {
    function preCheck(address, address, address, uint256, TransferLeg, bytes32)
        external
        pure
        returns (bytes32, uint256, bytes32)
    {
        return (bytes32(uint256(Decision.PASS)), 0, bytes32(0));
    }
}
