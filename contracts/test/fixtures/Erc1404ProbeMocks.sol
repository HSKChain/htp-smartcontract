// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/*
 * ERC1404Adapter 哨兵探测（M-06）专用的 Token 假体。
 *
 * 刻意与 AdapterMocks.sol 分开：那份文件里 ERC1404TokenMock 的 runtime codeHash 进了
 * ERC1404Adapter 的 PROVIDER_HASH，而 solc 的 metadata 哈希覆盖整份源文件——往里加一个
 * 合约就会让 test/unit/ERC1404Adapter.t.sol 里那条钉死的 providerHash 断言无故漂移。
 */

// 完全没有 detectTransferRestriction，任意 calldata 都经 fallback 回 32 字节零。
contract PermissiveFallbackERC1404Token {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

/*
 * 构造期干净、事后可翻成宽容 fallback 的 Token。
 *
 * 用来测运行期哨兵探测：翻开关不改 runtime code，codehash 全程不变，所以 preCheck
 * 不会被前面的 codeHash 分支提前拦下。vm.etch 换码做不到这一点。对应的真实场景是
 * 代理型 Token 在登记之后被换掉实现。
 */
contract ConfigurablePermissiveERC1404Token {
    uint256 internal restrictionCode;
    bool internal permissive;

    function setRestrictionCode(uint256 value) external {
        restrictionCode = value;
    }

    function setPermissive(bool value) external {
        permissive = value;
    }

    function detectTransferRestriction(address, address, uint256) external view returns (uint256) {
        return restrictionCode;
    }

    fallback() external {
        require(permissive, "UNKNOWN_SELECTOR");
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}
