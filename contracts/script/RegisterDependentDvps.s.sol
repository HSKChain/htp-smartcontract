// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CoreDeployment, DirectOperation} from "./DeployTypes.sol";
import {VerifyDeployment} from "./VerifyDeployment.s.sol";

interface IDependentDvpRegistry {
    function registerDependentDvp(address dvp, bytes32 evidenceHash) external;
    function getDependentDvpCount() external view returns (uint256);
    function getDependentDvp(uint256 index) external view returns (address dvp, bool retiredExempt);
}

/// @notice 把 DvP 登记进八个 Registry 的升级门禁依赖集合。
///
/// @dev 为什么需要独立脚本：registerDependentDvp 要 GOVERNANCE_ROLE，而部署者
/// 不持有任何角色（见 DeployHTP），因此这一步无法并入 _deployCoreTopology。
/// 在它执行完之前，八个 Registry 的 _authorizeUpgrade 会以
/// NoDependentDvpRegistered 拒绝任何升级——门禁 fail-closed，不存在静默失效的窗口。
///
/// 本脚本幂等：已登记的 Registry 会被跳过，中途失败可以安全重跑。
///
/// forge script script/RegisterDependentDvps.s.sol:RegisterDependentDvps \
///   --sig "run((...),bytes32)" <coreDeployment> <evidenceHash> \
///   --rpc-url "$RPC_URL" --broadcast
contract RegisterDependentDvps is Script {
    error EvidenceHashRequired();
    error DvpNotDeployed(address dvp);

    /// @notice 广播入口。调用方必须是八个 Registry 的 GOVERNANCE_ROLE 持有人。
    function run(CoreDeployment calldata core, bytes32 evidenceHash) external returns (uint256 registered) {
        vm.startBroadcast();
        registered = _registerAll(core, evidenceHash);
        vm.stopBroadcast();
        _verify(core);
    }

    /// @notice 不广播的等价入口，供集成测试与 --sig 模拟使用。
    function registerAll(CoreDeployment calldata core, bytes32 evidenceHash) external returns (uint256 registered) {
        registered = _registerAll(core, evidenceHash);
        _verify(core);
    }

    /// @notice 只读预检：返回尚未登记本 DvP 的 Registry 地址。
    /// 返回空数组即表示门禁已全部就位。
    function pendingRegistrations(CoreDeployment calldata core) external view returns (address[] memory pending) {
        address[8] memory registries = _registries(core);
        address[] memory buffer = new address[](registries.length);
        uint256 count;
        for (uint256 i = 0; i < registries.length; ++i) {
            if (!_isRegistered(registries[i], core.dvp)) {
                buffer[count] = registries[i];
                ++count;
            }
        }
        pending = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            pending[i] = buffer[i];
        }
    }

    /// @notice 供治理方通过多签或 Timelock 逐笔提交的 calldata。
    /// 与 DeploymentOperationBuilder.dependentDvpRegistration 的区别是这里会跳过已登记项。
    function pendingOperations(CoreDeployment calldata core, bytes32 evidenceHash)
        external
        view
        returns (DirectOperation[] memory operations)
    {
        address[8] memory registries = _registries(core);
        bytes memory payload = abi.encodeCall(IDependentDvpRegistry.registerDependentDvp, (core.dvp, evidenceHash));
        DirectOperation[] memory buffer = new DirectOperation[](registries.length);
        uint256 count;
        for (uint256 i = 0; i < registries.length; ++i) {
            if (!_isRegistered(registries[i], core.dvp)) {
                buffer[count] = DirectOperation({target: registries[i], data: payload});
                ++count;
            }
        }
        operations = new DirectOperation[](count);
        for (uint256 i = 0; i < count; ++i) {
            operations[i] = buffer[i];
        }
    }

    function _registerAll(CoreDeployment memory core, bytes32 evidenceHash) private returns (uint256 registered) {
        if (evidenceHash == bytes32(0)) revert EvidenceHashRequired();
        if (core.dvp == address(0) || core.dvp.code.length == 0) revert DvpNotDeployed(core.dvp);

        address[8] memory registries = _registries(core);
        for (uint256 i = 0; i < registries.length; ++i) {
            if (_isRegistered(registries[i], core.dvp)) continue;
            IDependentDvpRegistry(registries[i]).registerDependentDvp(core.dvp, evidenceHash);
            ++registered;
        }
        console2.log(unicode"本次写入的依赖登记笔数:", registered);
        console2.log(unicode"此前已登记、本次跳过:", registries.length - registered);
    }

    /// @dev 复用部署验收脚本，确保「每个 Registry 恰好登记本 DvP 且未被豁免」。
    /// 失败会 revert，因此本脚本执行成功即等价于门禁已就位。
    function _verify(CoreDeployment memory core) private {
        new VerifyDeployment().verifyDependentDvpRegistrations(core);
        console2.log(unicode"八个 Registry 的升级门禁已全部就位");
    }

    function _isRegistered(address registry, address dvp) private view returns (bool) {
        uint256 count = IDependentDvpRegistry(registry).getDependentDvpCount();
        for (uint256 i = 0; i < count; ++i) {
            (address stored,) = IDependentDvpRegistry(registry).getDependentDvp(i);
            if (stored == dvp) return true;
        }
        return false;
    }

    function _registries(CoreDeployment memory core) private pure returns (address[8] memory registries) {
        registries[0] = core.adapterRegistry.proxy;
        registries[1] = core.calculatorRegistry.proxy;
        registries[2] = core.settlementTokenRegistry.proxy;
        registries[3] = core.assetVersionRegistry.proxy;
        registries[4] = core.eligibilityRegistry.proxy;
        registries[5] = core.feeRegistry.proxy;
        registries[6] = core.marketRuleRegistry.proxy;
        registries[7] = core.participantRegistry.proxy;
    }
}
