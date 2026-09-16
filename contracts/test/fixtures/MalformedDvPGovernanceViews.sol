// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

contract RevertingDvPGovernanceView {
    fallback() external {
        revert();
    }
}

contract ShortReturnDvPGovernanceView {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(1, 31)
        }
    }
}

contract LongReturnDvPGovernanceView {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(0x20, 0)
            return(0, 64)
        }
    }
}

contract NonCanonicalBoolDvPGovernanceView {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

contract RetiredOnlyDvPGovernanceView {
    function retired() external pure returns (bool) {
        return true;
    }

    function globalPaused() external pure returns (bool) {
        revert();
    }
}

// 不 revert，改为烧光转发进来的 gas。若调用方用 gasleft() 无界转发，
// 依赖检查会连同整笔交易一起 OOG，既无法诊断也无法把该地址移出集合。
contract GasBombDvPGovernanceView {
    fallback() external {
        assembly ("memory-safe") {
            for {} gt(gas(), 0) {} {}
        }
    }
}
