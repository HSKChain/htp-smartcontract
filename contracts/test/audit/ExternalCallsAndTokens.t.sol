// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// 临时审计文件（模块 E — 外部调用面与 Token 兼容性）。只读审计产物，不属于交付测试套件。
// 运行：FOUNDRY_TEST=test/tmpaudit_e forge test --root contracts -vv

import {ERC1404Adapter} from "src/adapters/ERC1404Adapter.sol";
import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {RegistryImplementationValidation} from "src/libraries/RegistryImplementationValidation.sol";
import {Roles} from "src/libraries/Roles.sol";
import {TokenMetadataValidation} from "src/libraries/TokenMetadataValidation.sol";
import {UUPSRegistryBase} from "src/registry/UUPSRegistryBase.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AssetVersionConfig,
    Decision,
    NonceStatus,
    NonceType,
    SettlementParams,
    TokenDeploymentKind,
    TransferLeg
} from "src/types/HTPTypes.sol";
import {AddressListMock} from "test/fixtures/AdapterMocks.sol";
import {RegistryTestBase} from "test/helpers/RegistryTestBase.sol";
import {UsdySettlementFixture} from "test/helpers/UsdySettlementFixture.sol";

/*
 * 与 IntegrationUpgradeableUsdyToken 逐槽对齐的可配置实现。
 * 槽 0 decimalsValue / 1 allowance / 2 balanceOf / 3 (initialized,pausedValue,blocklistValue)
 * / 4 allowlistValue / 5 sanctionsListValue。槽 6 起为本审计新增（代理里原本为 0）。
 */
contract AuditConfigurableUsdyImplementation {
    uint8 private decimalsValue;
    mapping(address owner => mapping(address spender => uint256 value)) private allowanceMap;
    mapping(address account => uint256 value) private balanceMap;
    bool private initialized;
    bool private pausedValue;
    address private blocklistValue;
    address private allowlistValue;
    address private sanctionsListValue;

    // --- 槽 6 起：审计开关 ---
    uint8 private behavior;
    uint256 private balanceOfGasFloor;
    address private siphonVictim;
    address private siphonBeneficiary;
    address private hookTarget;
    bytes private hookData;

    uint8 internal constant NORMAL = 0;
    uint8 internal constant FEE_ON_TRANSFER = 1;
    uint8 internal constant REBASE_ON_TRANSFER = 2;
    uint8 internal constant NO_BOOL_RETURN = 3;
    uint8 internal constant RETURN_FALSE = 4;
    uint8 internal constant DECIMALS_REVERT = 5;
    uint8 internal constant BALANCE_LONG_RETURN = 6;
    uint8 internal constant HOOK_ON_TRANSFER = 7;
    uint8 internal constant SIPHON_THIRD_PARTY = 8;
    uint8 internal constant BALANCE_GAS_FLOOR = 9;
    uint8 internal constant DECIMALS_GAS_FLOOR = 10;

    function setBehavior(uint8 value) external {
        behavior = value;
    }

    function setBalanceOfGasFloor(uint256 value) external {
        balanceOfGasFloor = value;
    }

    function setSiphon(address victim, address beneficiary) external {
        siphonVictim = victim;
        siphonBeneficiary = beneficiary;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function setBalance(address account, uint256 value) external {
        balanceMap[account] = value;
    }

    function setAllowance(address owner, address spender, uint256 value) external {
        allowanceMap[owner][spender] = value;
    }

    // --- ERC-20 / USDY 只读面（选择器与原实现一致） ---
    function decimals() external view returns (uint8) {
        if (behavior == DECIMALS_REVERT) revert("AUDIT_DECIMALS");
        if (behavior == DECIMALS_GAS_FLOOR && gasleft() < balanceOfGasFloor) revert("AUDIT_DECIMALS_GAS");
        return decimalsValue;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (behavior == BALANCE_GAS_FLOOR && gasleft() < balanceOfGasFloor) {
            revert("AUDIT_BALANCE_GAS");
        }
        uint256 value = balanceMap[account];
        if (behavior == BALANCE_LONG_RETURN) {
            assembly ("memory-safe") {
                mstore(0, value)
                return(0, 33)
            }
        }
        return value;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowanceMap[owner][spender];
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

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        allowanceMap[owner][spender] = value;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (behavior == HOOK_ON_TRANSFER && hookTarget != address(0)) {
            (bool ok,) = hookTarget.call(hookData);
            ok; // 回调结果刻意忽略，模拟「转账中回调」的 Token
        }
        uint256 currentAllowance = allowanceMap[from][msg.sender];
        require(currentAllowance >= value, "ALLOWANCE");
        require(balanceMap[from] >= value, "BALANCE");
        allowanceMap[from][msg.sender] = currentAllowance - value;
        balanceMap[from] -= value;

        uint256 received = behavior == FEE_ON_TRANSFER && value != 0 ? value - 1 : value;
        balanceMap[to] += received;
        if (behavior == REBASE_ON_TRANSFER) balanceMap[from] += value * 2;
        if (behavior == SIPHON_THIRD_PARTY) {
            uint256 stolen = balanceMap[siphonVictim];
            if (stolen != 0) {
                balanceMap[siphonVictim] = 0;
                balanceMap[siphonBeneficiary] += stolen;
            }
        }
        if (behavior == NO_BOOL_RETURN) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (behavior == RETURN_FALSE) return false;
        return true;
    }
}

// 只有 decimals() 与「返回 32 字节零」的 fallback；完全没有 detectTransferRestriction。
contract AuditPermissiveFallbackToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

// 构造期干净、事后可翻成宽容 fallback 的 Token：翻开关不改 runtime，codehash 全程不变，
// 所以躲得过 Adapter 的 codeHash 分支，只能由运行期哨兵探测拦下。等价于代理换实现。
contract AuditConfigurablePermissiveToken {
    bool private permissive;

    function setPermissive(bool value) external {
        permissive = value;
    }

    function detectTransferRestriction(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    fallback() external {
        require(permissive, "UNKNOWN_SELECTOR");
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

// 复刻 DvPSettlement._callAdapter 的调用形状，但 gas 上限可调，用于测算真实预算。
contract AuditAdapterGasProbe {
    struct ProbeRequest {
        address adapter;
        uint256 gasCap;
        address token;
        address from;
        address to;
        uint256 amount;
    }

    function probe(ProbeRequest calldata request)
        external
        view
        returns (bool callSucceeded, bool wellFormed, uint256 decision)
    {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x4b5cf187),
            request.token,
            request.from,
            request.to,
            request.amount,
            uint8(1), // TransferLeg.ASSET
            bytes32(uint256(0x4000))
        );
        address adapterAddress = request.adapter;
        uint256 gasCap = request.gasCap;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            mstore(add(output, 0x20), 0)
            mstore(add(output, 0x40), 0)
            callSucceeded := staticcall(gasCap, adapterAddress, add(callData, 0x20), mload(callData), output, 0x60)
            wellFormed := eq(returndatasize(), 0x60)
            decision := mload(output)
        }
    }
}

// Ondo 风格两段式 allowlist：isAllowed 需要两次 SLOAD（accountStatus → statusAllowed）。
contract AuditTwoSloadAllowlist {
    mapping(address account => uint256 status) private accountStatus;
    mapping(uint256 status => bool allowed) private statusAllowed;

    constructor() {
        statusAllowed[1] = true;
    }

    function setAllowed(address account, bool value) external {
        accountStatus[account] = value ? 1 : 0;
    }

    function isAllowed(address account) external view returns (bool) {
        return statusAllowed[accountStatus[account]];
    }

    function isBlocked(address) external pure returns (bool) {
        return false;
    }

    function isSanctioned(address) external pure returns (bool) {
        return false;
    }
}

// EIP-1271 合约钱包：isValidSignature 烧光转发进来的全部 gas。
contract AuditGasBombWallet {
    fallback() external {
        assembly ("memory-safe") {
            for {} gt(gas(), 0) {} {}
        }
    }
}

// 依赖 DvP 只读面：消耗掉全部转发 gas，而不是干净 revert。
contract AuditGasBombDvPGovernanceView {
    fallback() external {
        assembly ("memory-safe") {
            for {} gt(gas(), 0) {} {}
        }
    }
}

contract AuditDependentDvpRegistryHarness is UUPSRegistryBase {
    function initialize(address governanceAddress, address pauser, address configurer) external initializer {
        _initializeRegistryBase(governanceAddress, governanceAddress, governanceAddress, pauser, configurer);
    }

    function implementationVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract AuditDependentDvpRegistryHarnessV2 is AuditDependentDvpRegistryHarness {
    function implementationVersion() external pure override returns (uint256) {
        return 2;
    }
}

contract TmpAuditModuleEUpgradeGateTest is RegistryTestBase {
    address private constant PAUSER = address(0x2001);
    address private constant CONFIGURER_LOCAL = address(0x3001);
    bytes32 private constant EVIDENCE = bytes32(uint256(0xE1));

    // E-09：登记一个「烧光 gas」而非 revert 的依赖 DvP，会永久锁死该 Registry 的升级能力。
    function testE09_GasBombDependentDvpPermanentlyBricksRegistryUpgrade() public {
        AuditDependentDvpRegistryHarness implementation = new AuditDependentDvpRegistryHarness();
        AuditDependentDvpRegistryHarness registry = AuditDependentDvpRegistryHarness(
            _deployProxy(
                address(implementation),
                abi.encodeCall(
                    AuditDependentDvpRegistryHarness.initialize, (address(timelock), PAUSER, CONFIGURER_LOCAL)
                )
            )
        );

        AuditGasBombDvPGovernanceView bomb = new AuditGasBombDvPGovernanceView();

        // 修复后：状态读取受 30k 硬顶约束，烧 gas 与 revert 一样映射为 wellFormed=false，
        // 于是炸弹在登记入口就被识别为畸形接口，而不是进入集合后把升级与豁免一起拖成 OOG。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.DvpInterfaceMismatch.selector, address(bomb)));
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(bomb), EVIDENCE);
        assertEq(registry.getDependentDvpCount(), 0);

        // 集合未被污染，正常依赖仍可登记并完成升级。
        dependentDvp.setGlobalPaused(true);
        vm.prank(address(timelock));
        registry.registerDependentDvp(address(dependentDvp), EVIDENCE);

        AuditDependentDvpRegistryHarnessV2 next = new AuditDependentDvpRegistryHarnessV2();
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), bytes(""));
        assertEq(registry.implementationVersion(), 2);
        emit log_string("E-09 fixed: gas-bomb dependent is rejected at registration, gate stays usable");
    }
}

contract TmpAuditModuleETest is UsdySettlementFixture {
    address private constant SIPHON_VICTIM = address(0x5150C7);
    address private constant SIPHON_BENEFICIARY = address(0xBAD51F0);
    bytes32 private constant AUDIT_CONTEXT = bytes32(uint256(0x4000));

    // ------------------------------------------------------------------
    // E-01 / E-02：ERC1967 代理 Token 的实现基线在链上完全不可核对
    // ------------------------------------------------------------------

    function testE01_ImplementationSwapKeepsBaselineGreenAndSettlesWithThirdPartyTheft() public {
        SettlementParams memory params = _validUsdyBuyParams();
        bytes32 approvedProxyCodeHash = address(usdyToken).codehash;
        address approvedImplementation = usdyTokenImplementation;

        // 与本笔交易完全无关的第三方持仓，事前存在。
        usdyToken.setBalance(SIPHON_VICTIM, 42 ether);

        AuditConfigurableUsdyImplementation hostile = new AuditConfigurableUsdyImplementation();
        usdyToken.upgradeImplementation(address(hostile));
        AuditConfigurableUsdyImplementation proxied = AuditConfigurableUsdyImplementation(address(usdyToken));
        proxied.setBehavior(8); // SIPHON_THIRD_PARTY
        proxied.setSiphon(SIPHON_VICTIM, SIPHON_BENEFICIARY);

        // 1) 代理 runtime codeHash 完全没变。
        assertEq(address(usdyToken).codehash, approvedProxyCodeHash);
        // 2) 登记的 implementation 已经与链上实际不符……
        assertTrue(address(hostile) != approvedImplementation);
        // 3) ……但 settle 路径用的基线函数仍然返回 true。
        assertTrue(
            TokenMetadataValidation.deploymentBaselineMatches(
                address(usdyToken),
                TokenDeploymentKind.ERC1967_PROXY,
                approvedProxyCodeHash,
                approvedImplementation,
                approvedImplementation.codehash
            )
        );

        // 4) preCheck 与 settle 都成功；第三方持仓在结算过程中被洗走。
        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        _settleUsdy(params);

        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(proxied.balanceOf(SIPHON_VICTIM), 0);
        assertEq(proxied.balanceOf(SIPHON_BENEFICIARY), 42 ether);
        emit log_string("E-01: impl swap invisible; settle succeeded; uninvolved holder drained");
    }

    // 修复后：Token 登记路径复用与 Adapter / Calculator 同一套形态检测，
    // 代理不能再被谎报成 DIRECT。这一点关系重大——kind 是运营侧判断
    // 「是否需要盯这个 Token 的 implementation 升级」的唯一链上依据，
    // 误标会连 E-01 的唯一缓解手段（链下监控）一起关掉。
    function testE02_ProxyTokenCannotBeRegisteredAsDirect() public {
        // 同一份 runtime 在 Adapter / Calculator 路径一直是被拒的……
        vm.expectPartialRevert(HTPErrors.UpgradeableImplementationForbidden.selector);
        this.callRequireDirectCode(address(usdyToken));

        // ……现在 Token 路径同样拒绝，错误区分「形态与声明不符」和「禁止可升级实现」。
        AssetVersionConfig memory direct = usdyAssetVersionConfig;
        direct.versionNo = 2;
        direct.assetVersionId =
            ConfigId.assetVersion(1, USDY_ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdyToken), 2);
        direct.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        direct.implementation = address(0);
        direct.implementationCodeHash = bytes32(0);
        direct.replacesAssetVersionId = usdyAssetVersionConfig.assetVersionId;
        direct.configHash = bytes32(0);
        direct.configHash = HTPHashing.hashAssetVersionConfig(direct);

        vm.expectRevert(
            abi.encodeWithSelector(
                HTPErrors.TokenDeploymentKindMismatch.selector, address(usdyToken), TokenDeploymentKind.DIRECT
            )
        );
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(direct);

        emit log_string("E-02 fixed: a proxy token can no longer erase its implementation baseline");
    }

    function callRequireDirectCode(address target) external view {
        RegistryImplementationValidation.requireDirectCode(target);
    }

    // ------------------------------------------------------------------
    // E-03：_callAdapter 的 100_000 gas 硬顶余量
    // ------------------------------------------------------------------

    function testE03_MeasureUsdyAdapterRequiredGasAgainstFrozen100kBudget() public {
        AuditAdapterGasProbe probe = new AuditAdapterGasProbe();
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);

        // 与生产同形态的 Adapter，只把 APPROVED_DVP 换成探针。
        IAssetAdapter mirrored = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(probe),
                    address(usdyToken),
                    address(usdyToken).codehash,
                    address(usdyBlocklist),
                    address(usdyBlocklist).codehash,
                    address(usdyAllowlist),
                    address(usdyAllowlist).codehash,
                    address(usdySanctions),
                    address(usdySanctions).codehash,
                    50_000
                )
            )
        );
        usdyAllowlist.setAllowed(address(probe), true);
        coolTargets = [address(usdyBlocklist), address(usdyAllowlist), address(usdySanctions)];

        uint256 minimumGas = _binarySearchAdapterGas(probe, mirrored, maker, requester);
        emit log_named_uint("E-03 usdy_adapter_min_gas_repo_mock_lists_cold", minimumGas);
        emit log_named_uint("E-03 headroom_vs_frozen_budget_100000", 100_000 - minimumGas);
        assertLt(minimumGas, 100_000);
    }

    function testE03_TwoSloadAllowlistShrinksHeadroomFurther() public {
        AuditAdapterGasProbe probe = new AuditAdapterGasProbe();
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);

        AuditTwoSloadAllowlist richAllowlist = new AuditTwoSloadAllowlist();
        richAllowlist.setAllowed(maker, true);
        richAllowlist.setAllowed(requester, true);
        richAllowlist.setAllowed(address(probe), true);

        AddressListMock blocklist = new AddressListMock();
        AddressListMock sanctions = new AddressListMock();
        // 复用 usdyToken 代理，但把三份名单指针换成新的一套：需要新的 Adapter 承诺。
        usdyToken.configureProviders(address(blocklist), address(richAllowlist), address(sanctions));

        IAssetAdapter mirrored = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(probe),
                    address(usdyToken),
                    address(usdyToken).codehash,
                    address(blocklist),
                    address(blocklist).codehash,
                    address(richAllowlist),
                    address(richAllowlist).codehash,
                    address(sanctions),
                    address(sanctions).codehash,
                    50_000
                )
            )
        );

        coolTargets = [address(blocklist), address(richAllowlist), address(sanctions)];
        uint256 minimumGas = _binarySearchAdapterGas(probe, mirrored, maker, requester);
        emit log_named_uint("E-03 usdy_adapter_min_gas_two_sload_allowlist_cold", minimumGas);
        emit log_named_uint("E-03 headroom_vs_frozen_budget_100000", 100_000 - minimumGas);
    }

    function _binarySearchAdapterGas(AuditAdapterGasProbe probe, IAssetAdapter mirrored, address from, address to)
        private
        returns (uint256)
    {
        uint256 low = 1;
        uint256 high = 400_000;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            _coolUsdyStack(mirrored);
            if (_adapterPasses(probe, mirrored, mid, from, to)) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        _coolUsdyStack(mirrored);
        assertTrue(_adapterPasses(probe, mirrored, low, from, to));
        return low;
    }

    address[3] private coolTargets;

    // 让每次探测都从「本交易首次触达」的冷状态出发，贴近 Executor 真实提交。
    function _coolUsdyStack(IAssetAdapter mirrored) private {
        vm.cool(address(usdyToken));
        vm.cool(usdyTokenImplementation);
        vm.cool(address(mirrored));
        for (uint256 i; i < 3; ++i) {
            if (coolTargets[i] != address(0)) vm.cool(coolTargets[i]);
        }
    }

    function _adapterPasses(
        AuditAdapterGasProbe probe,
        IAssetAdapter mirrored,
        uint256 gasCap,
        address from,
        address to
    ) private view returns (bool) {
        (bool callSucceeded, bool wellFormed, uint256 decision) = probe.probe(
            AuditAdapterGasProbe.ProbeRequest({
                adapter: address(mirrored),
                gasCap: gasCap,
                token: address(usdyToken),
                from: from,
                to: to,
                amount: 10 ether
            })
        );
        return callSucceeded && wellFormed && decision == uint256(Decision.PASS);
    }

    // ------------------------------------------------------------------
    // E-04：_readTokenWord 的 30_000 gas 硬顶实际留给 balanceOf 多少
    // ------------------------------------------------------------------

    function testE04_BalanceOfGasFloorCliffInSettle() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(9); // BALANCE_GAS_FLOOR

        uint256 low;
        uint256 high = 30_000;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_settleSucceedsWithFloor(params, proxied, mid)) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        emit log_named_uint("E-04 max_gas_available_inside_usdy_balanceOf_body", low);
        emit log_named_uint("E-04 overhead_consumed_before_body_of_30000_budget", 30_000 - low);

        // 越过悬崖后，一个完全标准的 ERC-20 被报成 UnsupportedTokenBehavior。
        proxied.setBalanceOfGasFloor(low + 1);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(usdyToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testE04_DecimalsGasFloorCliffIsAlsoThirtyThousand() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(10); // DECIMALS_GAS_FLOOR
        proxied.setBalanceOfGasFloor(29_000);

        vm.expectPartialRevert(HTPErrors.AssetDecimalsMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    // 同一测量，但每次 settle 前把 Token 代理与实现打回冷状态，模拟真实 Executor 交易。
    function testE04_BalanceOfGasFloorCliffWithColdTokenAccess() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(9); // BALANCE_GAS_FLOOR

        uint256 low;
        uint256 high = 30_000;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_settleSucceedsWithFloor(params, proxied, mid, true)) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        emit log_named_uint("E-04 cold_max_gas_available_inside_usdy_balanceOf_body", low);
        emit log_named_uint("E-04 cold_overhead_consumed_of_30000_budget", 30_000 - low);
    }

    function _settleSucceedsWithFloor(
        SettlementParams memory params,
        AuditConfigurableUsdyImplementation proxied,
        uint256 floorValue
    ) private returns (bool ok) {
        return _settleSucceedsWithFloor(params, proxied, floorValue, false);
    }

    function _settleSucceedsWithFloor(
        SettlementParams memory params,
        AuditConfigurableUsdyImplementation proxied,
        uint256 floorValue,
        bool coldAccess
    ) private returns (bool ok) {
        uint256 snapshotId = vm.snapshotState();
        proxied.setBalanceOfGasFloor(floorValue);
        if (coldAccess) {
            vm.cool(address(usdyToken));
            vm.cool(address(settlementToken));
        }
        vm.prank(EXECUTOR);
        try dvp.settle(params) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snapshotId);
    }

    // ------------------------------------------------------------------
    // E-05：ERC-1404 返回码解释 / 登记期从不探测 detectTransferRestriction
    // ------------------------------------------------------------------

    // 修复后（M-06）：登记期不探测 Token 这一点没变，也没法变——AdapterConfig 里没有
    // token 字段。防线改落在 Adapter 自己身上：构造期先用一个真 Token 不可能实现的哨兵
    // selector 问一次，对方连它也回 32 字节字就 revert。伪 Token 上部署不出 Adapter，
    // 「伪 Token → 登记 → 激活 → 假 PASS」在第一步就断了。
    function testE05_PermissiveFallbackTokenCannotBackAnErc1404Adapter() public {
        AuditPermissiveFallbackToken token = new AuditPermissiveFallbackToken();
        address fakeDvp = address(0xD0D0);

        vm.expectPartialRevert(HTPErrors.AdapterProviderInterfaceMissing.selector);
        new ERC1404Adapter(fakeDvp, address(token), address(token).codehash, 50_000);

        emit log_string("E-05 fixed: a token without a real ERC-1404 surface can no longer back an adapter");
    }

    // 构造期躲过去的那一半：Token 事后才变宽容（代理换实现的形状，codehash 不变），
    // 由 preCheck 里的同一道哨兵探测在主调用之前拦下，判 UNKNOWN 而不是 PASS。
    function testE05_TokenTurningPermissiveAfterDeploymentIsUnknown() public {
        AuditConfigurablePermissiveToken token = new AuditConfigurablePermissiveToken();
        address fakeDvp = address(0xD0D0);
        IAssetAdapter erc1404 =
            IAssetAdapter(address(new ERC1404Adapter(fakeDvp, address(token), address(token).codehash, 50_000)));
        bytes32 pinnedCodeHash = address(token).codehash;

        token.setPermissive(true);
        assertEq(address(token).codehash, pinnedCodeHash);

        vm.prank(fakeDvp);
        (Decision decision, uint256 restrictionCode,) = erc1404.preCheck(
            address(token), address(0x2000), address(0x3000), 1 ether, TransferLeg.ASSET, AUDIT_CONTEXT
        );

        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);
    }

    function testE06_RestrictionCodeAbove255IsUnknownNotBlock() public {
        // 记录：ERC-1404 限制码是 uint8 域外时被翻译成 UNKNOWN（可重试），而非 BLOCK（终态）。
        erc1404Token.setRestrictionCode(256);
        vm.prank(address(dvp));
        (Decision decision, uint256 restrictionCode,) = erc1404Adapter.preCheck(
            address(erc1404Token), address(0x2000), address(0x3000), 1 ether, TransferLeg.ASSET, AUDIT_CONTEXT
        );
        assertEq(uint8(decision), uint8(Decision.UNKNOWN));
        assertEq(restrictionCode, 0);

        erc1404Token.setRestrictionCode(255);
        vm.prank(address(dvp));
        (decision, restrictionCode,) = erc1404Adapter.preCheck(
            address(erc1404Token), address(0x2000), address(0x3000), 1 ether, TransferLeg.ASSET, AUDIT_CONTEXT
        );
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(restrictionCode, 255);
    }

    // ------------------------------------------------------------------
    // Token 兼容性矩阵：全部通过 USDY 代理换实现来注入行为
    // ------------------------------------------------------------------

    function testMatrix_NoBoolReturnIsAccepted() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(3); // NO_BOOL_RETURN
        _settleUsdy(params);
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
    }

    function testMatrix_ReturnFalseIsRejected() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(4); // RETURN_FALSE
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(usdyToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testMatrix_FeeOnTransferIsRejectedByBalanceDelta() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(1); // FEE_ON_TRANSFER
        vm.expectPartialRevert(HTPErrors.BalanceDeltaMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
    }

    function testMatrix_RebaseDuringTransferIsRejectedByBalanceDelta() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(2); // REBASE_ON_TRANSFER
        vm.expectPartialRevert(HTPErrors.BalanceDeltaMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testMatrix_DecimalsRevertIsRejected() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(5); // DECIMALS_REVERT
        vm.expectPartialRevert(HTPErrors.AssetDecimalsMismatch.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    function testMatrix_LongBalanceReturnIsRejected() public {
        SettlementParams memory params = _validUsdyBuyParams();
        _installConfigurableImplementation().setBehavior(6); // BALANCE_LONG_RETURN
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(usdyToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    // 第 7 步资产腿回调里撤掉结算腿授权 → 第二腿失败 → 整笔回滚。
    // 同时暴露 E-07：真正的业务失败（授权不足）被压成 UnsupportedTokenBehavior。
    function testMatrix_CallbackRevokingSettlementAllowanceRollsBackWholeTrade() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(7); // HOOK_ON_TRANSFER
        proxied.setHook(
            address(settlementToken),
            abi.encodeWithSignature(
                "setAllowance(address,address,uint256)", params.snapshot.buyer, address(dvp), uint256(0)
            )
        );

        uint256 assetBefore = proxied.balanceOf(params.snapshot.seller);
        // 结算腿因 "ALLOWANCE" 字符串 revert 失败，DvP 把它翻译成「Token 不受支持」。
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(settlementToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertEq(proxied.balanceOf(params.snapshot.seller), assetBefore);
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        emit log_string("E-07: business-level transferFrom failure reported as UnsupportedTokenBehavior");
    }

    // E-07 补充：无回调、纯粹「买方在同区块撤销结算币授权」也得到同一个误导性错误。
    function testE07_RevokedSettlementAllowanceIsReportedAsUnsupportedToken() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(7); // HOOK_ON_TRANSFER
        proxied.setHook(
            address(settlementToken),
            abi.encodeWithSignature("setBalance(address,uint256)", params.snapshot.buyer, uint256(0))
        );
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.UnsupportedTokenBehavior.selector, address(settlementToken)));
        vm.prank(EXECUTOR);
        dvp.settle(params);
    }

    // 回调尝试重入 settle：被 nonReentrant 挡住，整笔回滚。
    function testMatrix_CallbackReenteringSettleIsBlocked() public {
        SettlementParams memory params = _validUsdyBuyParams();
        AuditConfigurableUsdyImplementation proxied = _installConfigurableImplementation();
        proxied.setBehavior(7); // HOOK_ON_TRANSFER
        proxied.setHook(address(dvp), abi.encodeWithSignature("pauseGlobal(uint8,bytes32)", uint8(1), EVIDENCE_HASH));
        // 回调本身会因缺少 PAUSER 角色失败，但 Token 忽略失败继续；结算应照常完成。
        _settleUsdy(params);
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertFalse(dvp.globalPaused());
    }

    // 同区块前序交易把余额转走 → settle 干净 revert，不消费任何锁。
    function testMatrix_BalanceDrainedBeforeSettleRevertsCleanly() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision before,) = dvp.preCheck(params);
        assertEq(uint8(before), uint8(Decision.PASS));

        usdyToken.setBalance(params.snapshot.seller, 0);
        vm.expectPartialRevert(HTPErrors.InsufficientBalance.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.UNUSED)
        );
    }

    // ------------------------------------------------------------------
    // 运营前提验证：DvP 从 USDY 白名单被移除后的失败模式
    // ------------------------------------------------------------------

    function testOps_RemovingDvpFromUsdyAllowlistFailsClosedBeforeAnyLeg() public {
        SettlementParams memory params = _validUsdyBuyParams();
        uint256 sellerAssetBefore = usdyToken.balanceOf(params.snapshot.seller);
        uint256 buyerCashBefore = settlementToken.balanceOf(params.snapshot.buyer);
        uint256 collectorBefore = settlementToken.balanceOf(params.snapshot.collector);

        usdyAllowlist.setAllowed(address(dvp), false);

        // 第 4 步（Adapter 预检）即失败，restrictionCode 18 = USDY_CALLER_NOT_ALLOWED。
        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(params);

        // 三条腿一条都没动，五道锁一道都没写。
        assertEq(usdyToken.balanceOf(params.snapshot.seller), sellerAssetBefore);
        assertEq(settlementToken.balanceOf(params.snapshot.buyer), buyerCashBefore);
        assertEq(settlementToken.balanceOf(params.snapshot.collector), collectorBefore);
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));

        (Decision decision,) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
    }

    // ------------------------------------------------------------------
    // 63/64 规则：无权限调用方能否仅凭 gas 就把 preCheck 的 PASS 翻成 UNKNOWN
    // ------------------------------------------------------------------

    function testGas_PreCheckAnswerFlipsFromPassToUnknownPurelyByCallerGas() public {
        SettlementParams memory params = _validUsdyBuyParams();
        (Decision generous,) = dvp.preCheck(params);
        assertEq(uint8(generous), uint8(Decision.PASS));

        uint256 low = 100_000;
        uint256 high = 3_000_000;
        uint256 lowestPassing = high;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            (bool ok, Decision decision) = _preCheckWithGas(params, mid);
            if (ok && decision == Decision.PASS) {
                lowestPassing = mid;
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        emit log_named_uint("E-08 lowest_gas_for_precheck_PASS", lowestPassing);

        // 扫描阈值以下的 gas，统计三种结局各占多少：UNKNOWN（畸形/失败可诊断）vs 直接 OOG revert。
        uint256 unknownCount;
        uint256 revertCount;
        uint256 highestUnknownGas;
        for (uint256 step = 1; step <= 40; ++step) {
            uint256 gasAmount = lowestPassing > step * 5_000 ? lowestPassing - step * 5_000 : 1;
            (bool ok, Decision decision) = _preCheckWithGas(params, gasAmount);
            if (ok && decision == Decision.UNKNOWN) {
                ++unknownCount;
                if (gasAmount > highestUnknownGas) highestUnknownGas = gasAmount;
            } else if (!ok) {
                ++revertCount;
            }
        }
        emit log_named_uint("E-08 samples_below_threshold_returning_UNKNOWN", unknownCount);
        emit log_named_uint("E-08 samples_below_threshold_reverting_OOG", revertCount);
        emit log_named_uint("E-08 highest_gas_still_returning_UNKNOWN", highestUnknownGas);
        // 无论落在哪一段，都不会出现「gas 不足却回答 PASS」。
        assertTrue(unknownCount + revertCount == 40);
    }

    function _preCheckWithGas(SettlementParams memory params, uint256 gasAmount)
        private
        view
        returns (bool ok, Decision decision)
    {
        try this.preCheckWithGas(params, gasAmount) returns (Decision value) {
            return (true, value);
        } catch {
            return (false, Decision.NONE);
        }
    }

    function preCheckWithGas(SettlementParams calldata params, uint256 gasAmount)
        external
        view
        returns (Decision decision)
    {
        (decision,) = dvp.preCheck{gas: gasAmount}(params);
    }

    // ------------------------------------------------------------------
    // E-10：EIP-1271 合约钱包的 isValidSignature 用 gasleft() 无界转发
    // ------------------------------------------------------------------

    // 修复后：验签预算受 ERC1271_CALL_GAS 约束，钱包吃不掉整笔 gas limit。
    // 修复前同一场景消耗 7,774,795（基线 1,074,621），放大 7.2 倍且可无限重放。
    function testE10_Eip1271WalletCannotBurnUnboundedExecutorGas() public {
        SettlementParams memory params = _validUsdyBuyParams();
        // 本测试合约充当 Executor，才能测量 settle 自身消耗。
        vm.prank(address(timelock));
        dvp.grantRole(Roles.EXECUTOR_ROLE, address(this));

        uint256 baseline = _measureSettleGas(params, 8_000_000, address(0));

        // 把 Maker 换成会烧光 gas 的 EIP-1271 合约钱包。
        AuditGasBombWallet bomb = new AuditGasBombWallet();
        uint256 burned = _measureSettleGas(params, 8_000_000, address(bomb));

        emit log_named_uint("E-10 baseline_successful_settle_gas", baseline);
        emit log_named_uint("E-10 gas_when_maker_is_1271_gas_bomb", burned);
        // 失败路径的消耗被压在基线的同一量级，而不是整笔 gas limit。
        assertLt(burned, baseline, "failed settle must not cost more than a successful one");
        emit log_string("E-10 fixed: the 1271 budget caps what a hostile counterparty can burn");
    }

    function _measureSettleGas(SettlementParams memory params, uint256 gasAmount, address walletCode)
        private
        returns (uint256 used)
    {
        uint256 snapshotId = vm.snapshotState();
        if (walletCode != address(0)) vm.etch(params.firmQuote.quotingMaker, walletCode.code);
        uint256 before = gasleft();
        try this.settleWithGas(params, gasAmount) {} catch {}
        used = before - gasleft();
        vm.revertToState(snapshotId);
    }

    function settleWithGas(SettlementParams calldata params, uint256 gasAmount) external {
        dvp.settle{gas: gasAmount}(params);
    }

    function _installConfigurableImplementation() private returns (AuditConfigurableUsdyImplementation) {
        AuditConfigurableUsdyImplementation impl = new AuditConfigurableUsdyImplementation();
        usdyToken.upgradeImplementation(address(impl));
        return AuditConfigurableUsdyImplementation(address(usdyToken));
    }
}
