# 审计 PoC 证据集

2026-08-19 安全与功能审计产出的可复现证据。共 8 个文件、105 个测试，全部通过。

这些**不是**常规功能测试。它们的作用是把审计报告里的每一条发现固定成可执行的证据，让修复过程有明确的验收标准。

## 修复状态（2026-08-20 更新）

已修复：**H-01**（含 M-07、M-08、C-05）、**M-01**（EIP-1271 无界 gas）、**M-12**（双腿 100% 费率）、**M-03**（Executor 择时期权）、**M-05**（代理 Token 登记成 DIRECT）、**M-06**（ERC-1404 宽容 fallback 假 PASS）、**M-10**（PAUSED 废弃后重新可结算）、**M-11**（Configurer 独占不可逆撤销）、**M-13**（治理角色可弃权至不可恢复）、**D-04**（费用侧无共享向量）。对应测试的断言均已反转。

M-01 的效果可量化：同一个恶意合约钱包场景，修复前一次失败的 settle 消耗 19,464,637 gas，修复后 358,303；另一处从 7,774,795 降到 295,059。M-12 则让「卖方交割资产却零收款」从可配置变为不可达——`sellerFee = floor(P × rate/10000)` 在聚合上限 1000 bps 下恒小于 `P`。M-03 把成交窗口从运营配置的 56.7 天压到协议强制的 1 小时。

**M-04** 与 **M-02** 按技术边界与产品决策结案，不加代码，详见下方结论表。

以下 16 个测试**断言已反转**——它们现在证明的是缺陷已消除，而不是缺陷存在：

| 发现 | 测试 | 现在断言的内容 |
|---|---|---|
| H-01 | `Deployment.t.sol::test_F01_upgraderAloneCannotUpgradeWhileDvpLive` | 空依赖集合下升级以 `NoDependentDvpRegistered` 被拒；补登记后转为要求 DvP 已暂停 |
| H-01 | `GovernanceAndUpgrade.t.sol::testEmptyDependentSetBlocksUpgradeUntilRegistered` | 空集合被读作「尚未登记」而非「无依赖」 |
| M-08 | `GovernanceAndUpgrade.t.sol::testMisregisteredDependentIsRejectedAtRegistration` | 接口不完整的地址在登记入口即被拒，集合不被污染 |
| M-08 | `GovernanceAndUpgrade.t.sol::testSelfDestructingDependentIsRejectedAtRegistration` | 同上，且 `retired()` 探测先行拦下 |
| M-07 | `ExternalCallsAndTokens.t.sol::testE09_...` | gas 炸弹在登记入口被识别为畸形接口，门禁保持可用 |
| — | `GovernanceAndUpgrade.t.sol::testUpgradeToNonUupsImplementationIsRejected` | 补了门禁前置条件（本身不是缺陷，是测试适配） |
| M-01 | `SignatureAndReplay.t.sol::testEip1271WalletCannotBurnUnboundedExecutorGas` | 验签受 200k 预算约束，消耗被压在同一量级 |
| M-01 | `ExternalCallsAndTokens.t.sol::testE10_...CannotBurn...` | 失败路径不再比成功路径更贵 |
| M-12 | `NumericsAndFees.t.sol::testAggregateFeeAtTwoHundredPercentIsNowRejected` | 聚合超本金返回 `AGGREGATE_FEE_EXCEEDS_PRINCIPAL` 且不回填金额 |
| M-12 | `NumericsAndFees.t.sol::testSellerAlwaysReceivesCashUnderRegistrableFees` | 可登记费率下卖方净收恒为正 |
| M-03 | `TrustBoundary.t.sol::test_F02_quoteLifetimeIsProtocolBounded` | 成交窗口由协议而非运营配置决定，56.7 天压到 1 小时 |
| M-05 | `ExternalCallsAndTokens.t.sol::testE02_ProxyTokenCannotBeRegisteredAsDirect` | 代理不能再谎报成 `DIRECT`，失败为 `TokenDeploymentKindMismatch` |
| M-06 | `ExternalCallsAndTokens.t.sol::testE05_PermissiveFallbackTokenCannotBackAnErc1404Adapter` | 无 ERC-1404 表面的 Token 上部署不出 Adapter，失败为 `AdapterProviderInterfaceMissing` |
| M-06 | `ExternalCallsAndTokens.t.sol::testE05_TokenTurningPermissiveAfterDeploymentIsUnknown` | 事后才变宽容（codehash 不变）由运行期哨兵探测拦下，判 UNKNOWN |
| M-10 | `GovernanceAndUpgrade.t.sol::testAPausedFeeVersionCannotBeDeprecatedIntoExecutabilityAgain` | `PAUSED → DEPRECATED` 被拒；暂停是吸收点，要退役先 unpause |
| M-11 | `GovernanceAndUpgrade.t.sol::testOnlyGovernanceCanIrreversiblyRevokeAParticipant` | Configurer 不再持有不可逆销毁原语，终态性本身不变 |
| M-13 | `Deployment.t.sol::test_F04_lastDefaultAdminCannotBeRenouncedSoRecoveryStaysOpen` | 最后一个 admin 不可弃权，补授 PAUSER 后升级门禁重新可满足 |
| M-13 | `GovernanceAndUpgrade.t.sol::testSoleDefaultAdminCannotRenounceAndRoleAdministrationStaysOpen` | 唯一 admin 自弃被拒，角色管理不冻结 |

合约侧改动：`UUPSRegistryBase._authorizeUpgrade` 对空集合 fail-closed、`registerDependentDvp` 增加 `IDvPGovernanceView` 探测与退役检查、`_strictBoolStaticCall` 由 `gasleft()` 改为 30k 硬顶；`DvPSignedPayloadValidator` 的 EIP-1271 调用改用 `ProtocolSecurityLimits.ERC1271_CALL_GAS`；`FeeMath` 增加聚合费用上界、`FeeRegistry` 增加登记期聚合费率上限并把 `deprecateFeeVersion` 收窄到只接受 `ACTIVE`；`DvPCurrentStateValidator` 增加 `MAX_QUOTE_LIFETIME`（1 小时）成交窗口上限；`TokenMetadataValidation.requireTokenDeployment` 在登记期复用 `RegistryImplementationValidation` 的代理形态检测；`ERC1404Adapter` 在构造期与 `preCheck` 主调用之前各做一次哨兵 selector 探测（哨兵不进 `RestrictionProvider[]`，`PROVIDER_HASH` 与 `capabilityHash` 均不变）；`revokeParticipant` / `revokeEligibility` 收归 `GOVERNANCE_ROLE`；DvP 与 `UUPSRegistryBase` 覆写 `_grantRole` / `_revokeRole` 维护 `DEFAULT_ADMIN` 计数，摘除最后一个会以 `LastDefaultAdminCannotBeRemoved` 被拒。部署侧新增 `script/RegisterDependentDvps.s.sol`（幂等治理脚本），`DeployHTP` 与 `DeployAndReport` 会显式报告门禁待办。

M-03 的修复顺带覆盖了旧费率回放：`tradeDeadline − createdAt ≤ 1 小时` 配合既有的 `createdAt ≤ now ≤ tradeDeadline`，把 `createdAt` 的回填空间也压到 1 小时，而跨 Epoch 回放需要回溯数周。因此 Fee Epoch 的 `LEGACY_SERVING` 宽限窗口长度不再是攻击面，未单独加硬顶。

D-04 走的是另一条路，不属于"反转断言"而是补齐缺失的保障。费用侧原先只有 `resolution-and-amounts.json` 里一条手写 amount 向量，且 `calc-reference` 没有任何费用函数——链下必须照着 Solidity 重写 FeeMath。现在补上 `packages/calc-reference/src/fees.ts` 参考实现与 `schema/v1/vectors/fees/amounts-v1.json`（8 条命名向量 + 240 条 fuzz 语料 + 7 条失败语料，期望值全部由参考实现现算），TS 侧 `test/fee.test.ts` 与 Solidity 侧 `test/fuzz/FeeMathFuzz.t.sol` 消费同一份 JSON。`FeeMath` 的十个状态在 `statusCoverage` 里逐一登记，其中 `SELLER_FEE_EXCEEDS_PRINCIPAL` 与 `CONSERVATION_MISMATCH` 经证明在当前算术下不可达（前者因为 `fee = min(P × rate/10000, cap)` 且 `rate ≤ 10000`），向量文件里附证明而非留白。

**按技术边界结案**（不加代码，改为文档披露）：

| 发现 | 结论 |
| --- | --- |
| M-04 代理实现基线空转 | 链上无法核对：EVM 无 `EXTSLOAD`，标准 `ERC1967Proxy` 不暴露 getter。登记期探测 `implementation()` 对真实 USDY 无效，且只覆盖登记那一刻，属于「看起来在守」的空转检查，故不加。PRD §5.4 改为按 Token 形态分列，明确代理那一行「链上完全不可观测」，两个配置字段定性为链下监控基线 |
| M-02 cancelNonce 抢跑 | 保留链上语义（签名人必须能随时退出），PRD §3.2 增补一节说明链下状态机不被链上强制，并把链下监控与接入层罚则列为**必需**而非可选。`NonceCancelled` 事件可观测是本条与其他反悔通道的关键差别 |

**仍在断言缺陷存在**的发现：M-09 费率指针被占、M-14 Epoch 封存后无法就地修正、M-15 资产版本误废弃。三条都是治理不可逆性，修它们需要设计新的恢复边。

M-06 的修复有明确边界，需要读者知道射程在哪。登记期仍然不探测 Token，而且没法探测——`AdapterConfig` 里根本没有 token 字段，token 只存在于 Adapter 的 immutable 里。所以防线落在 `ERC1404Adapter` 自己身上：构造期与每次 `preCheck` 都先用一个真 Token 不可能实现的哨兵 selector 问一次，对方连它也回 32 字节字就判定没有可信的限制面（构造期 revert，运行期 UNKNOWN）。这挡住的是「无差别宽容 fallback」这一类。一个实现了 `detectTransferRestriction`、只对该 selector 撒谎回 0、对其他 selector 干净 revert 的 Token，在链上与真实 ERC-1404 完全不可区分——EVM 没有办法验证语义，那一层残余风险仍由治理登记环节的尽调承担。

## 与代码库的关系

- 只读断言，不修改 `src/`、`script/` 或任何既有测试
- 不参与 `npm run contracts:unit`（它只匹配 `test/unit/**`），但会被全量 `forge test` 收进去
- 引用了 `test/helpers/` 下的既有 fixture，所以依赖它们保持稳定

## 运行

```bash
forge test --root contracts --match-path 'test/audit/**/*.t.sol' -vv
```

## 文件对应的发现

| 文件 | 测试数 | 覆盖的发现 |
|---|---|---|
| `Deployment.t.sol` | 7 | **H-01** 升级门禁在部署产出状态下失效（3 个）、F-03 VerifyRoles 正向断言盲区、F-04 治理角色 renounce 不可恢复、F-07 unpause 门禁接受任意子集、部署后角色表验证 |
| `SignatureAndReplay.t.sol` | 12 | M-01 EIP-1271 无界 gas（含诚实钱包对照基线）、M-02 cancelNonce 抢跑、B-03 EIP-7702 委托失效签名、B-04 tradeIdHash 预烧、B-06 分叉行为；另有 TYPEHASH 独立重编码交叉验证与写锁原子性正面验证 |
| `ExternalCallsAndTokens.t.sol` | 24 | M-04 代理实现基线空转、M-05 代理登记为 DIRECT、M-06 ERC-1404 宽容 fallback、M-07 升级门禁 gas 炸弹、M-01 从外部调用面的独立复现、E-03/E-04 gas 余量实测、E-06/E-07/E-08；以及完整的 Token 兼容性矩阵 |
| `NumericsAndFees.t.sol` | 27 | M-12 双腿 100% 费率聚合 200%、D-02 BOND 应计利息绕过 priceTick、D-03 错误码折叠、D-05 价格时点无新鲜度校验、D-06 舍入方向；含守恒等式 fuzz 与逐字段金额变异验证 |
| `GovernanceAndUpgrade.t.sol` | 11 | M-08 registerDependentDvp 无接口校验、M-09 CONFIGURER 垄断费率指针、M-10 DEPRECATED 逃逸边、M-11 revoke 不可逆、C-05 空集合 fail-open、C-06 DEFAULT_ADMIN 自弃、C-07 旧修订仍 ACTIVE |
| `SettlementPipeline.t.sol` | 14 | A-01（已下调 Low）adapter gas 预算、A-02 permit 路径恒 UNKNOWN；其余 11 个是**正面验证**——permit 字段精确性、四种地址重合被拒、原子回滚、事件 topic 与 log 长度核对 |
| `TrustBoundary.t.sol` | 7 | M-03 Executor 择时期权、取消竞态双向验证、USDY 白名单遗漏的失败模式、签名后转走资产的清理性、暂停期间 cancelNonce 可用性 |
| `OpsBlastRadius.t.sol` | 3 | M-14 Fee Epoch 封存后 collector 不可修正、M-15 AssetVersion DEPRECATED 终态、Registry 逐条暂停语义 |

## 修复时怎么用（重要）

尚未修复的那些测试断言的是**审计时刻的实际行为**，其中相当一部分断言的正是缺陷本身。

**修复某条发现后，对应的测试会失败——这是预期结果，失败即说明修复生效。** 例如给 EIP-1271 加上 gas 上限后，`testEip1271WalletBurnsUnboundedExecutorGas` 里 `assertGt(spent, 15_000_000)` 必然不再成立。

处理方式参照 H-01 那批已完成的做法：把断言反转（从"证明缺陷存在"改成"证明缺陷已消除"），并在函数名和注释里写明原缺陷是什么。这样每条发现都留下一条永久的防复现测试，而不是删掉了事。

H-01 的修复还顺带在 `test/unit/DependentDvpGuard.t.sol` 增加了两条正式回归：`testUpgradeRejectsEmptyDependentSet` 与 `testRegistrationRejectsMalformedRetiredAndGasBombGovernanceViews`，并把原先几个依赖畸形地址的用例改用 `vm.etch` 模拟"登记后 runtime 漂移"，从而在防线前移之后仍然覆盖 `_authorizeUpgrade` 的 fail-closed 分支。

## 适合直接转为长期回归的几个

以下测试无论是否修复都应长期保留，它们锁定的是不变量而非缺陷：

- `SettlementPipeline.t.sol` 里的 11 个正面验证（permit 精确性、地址互斥、原子回滚、事件编码）
- `SignatureAndReplay.t.sol` 的 TYPEHASH 独立重编码交叉验证——这是防止 EIP-712 schema 漂移的最有效手段
- `NumericsAndFees.t.sol` 的守恒等式 fuzz 与金额字段逐一变异
- `ExternalCallsAndTokens.t.sol` 的 Token 兼容性矩阵——它覆盖了 fee-on-transfer、rebase、非标准返回值、回调重入等 14 种行为

## 已知的测量口径差异

`SettlementPipeline.t.sol` 与 `ExternalCallsAndTokens.t.sol` 对 USDY Adapter 的 gas 消耗测出不同数字（80,791 vs 47,874）。原因是前者测 `gasBefore − gasAfter` 的消耗差值（含 staticcall 外层开销），后者用二分搜索找 adapter 执行成功所需的最小 gas limit。

`staticcall(100000, ...)` 约束的是后者，所以以 `ExternalCallsAndTokens.t.sol` 的 47,874 为准，实际余量约 52%。后续若再做 gas 相关测量，请明确说明口径。
