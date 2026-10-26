// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

/// @notice 单文件 USDY 运营流水线：对本地 Anvil 广播真实交易，不引用任何其它测试文件。
///
/// 只依赖生产合约 `src/`、OpenZeppelin 与 forge-std。USDY / 结算币 / 名单都写在本文件里。
/// 部署账户是 Anvil 默认 account[0]；运营角色通过 Anvil impersonate 发交易。
///
///   make e2e          启动 Anvil、广播流水线、结束后自动停 Anvil
///   make anvil        只启动节点，方便事后用 cast 查看
///
/// 跑完后可用 cast 查 Anvil 上的合约，地址写在 deploy/out/usdy-e2e.json。

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {UsdyRestrictedAdapter} from "src/adapters/UsdyRestrictedAdapter.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {DvPRegistries, DvPRoles, DvPSettlement} from "src/DvPSettlement.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeScope} from "src/libraries/FeeScope.sol";
import {HTPHashing} from "src/libraries/HTPHashing.sol";
import {Roles} from "src/libraries/Roles.sol";
import {AdapterRegistry} from "src/registry/AdapterRegistry.sol";
import {AssetVersionRegistry} from "src/registry/AssetVersionRegistry.sol";
import {EligibilityRegistry} from "src/registry/EligibilityRegistry.sol";
import {FeeRegistry} from "src/registry/FeeRegistry.sol";
import {MarketRuleRegistry} from "src/registry/MarketRuleRegistry.sol";
import {ParticipantRegistry} from "src/registry/ParticipantRegistry.sol";
import {PrincipalCalculatorRegistry} from "src/registry/PrincipalCalculatorRegistry.sol";
import {SettlementTokenRegistry} from "src/registry/SettlementTokenRegistry.sol";
import {HTPErrors} from "src/types/HTPErrors.sol";
import {
    AdapterCapabilities,
    AdapterConfig,
    AdapterStatus,
    AssetClass,
    AssetVersionConfig,
    AssetVersionStatus,
    Decision,
    EligibilityInput,
    FeeConfig,
    FeePolicyEpochConfig,
    FirmQuote,
    FundPriceTerms,
    MarketRuleConfig,
    NonceStatus,
    NonceType,
    ParticipantInput,
    ParticipantType,
    PermitCapability,
    PermitData,
    PrincipalCalculatorConfig,
    ReasonCode,
    RequesterSide,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard,
    TradeIntent,
    TradeTermsSnapshot
} from "src/types/HTPTypes.sol";
import {DvPCurrentStateValidatorFactory} from "src/validation/DvPCurrentStateValidatorFactory.sol";

/// @dev 本文件内的 allow / block / sanctions 名单。生产上这些是 Ondo 侧管理员，不属于 HTP RBAC。
contract PipelineUsdyList {
    address public admin;
    mapping(address account => bool value) internal flagged;

    constructor() {
        admin = msg.sender;
    }

    function set(address account, bool value) external {
        require(msg.sender == admin, "NOT_ADMIN");
        flagged[account] = value;
    }

    function isBlocked(address account) external view returns (bool) {
        return flagged[account];
    }

    function isAllowed(address account) external view returns (bool) {
        return flagged[account];
    }

    function isSanctioned(address account) external view returns (bool) {
        return flagged[account];
    }
}

/// @dev 行为对齐官方 USDY 公开限制：paused → operator → from → to；blocked → sanctioned → allowlist。
///      无 ERC-2612 permit。不要把本合约当成官方源码副本。
contract PipelineUsdy {
    address public admin;
    bool public paused;
    address public blocklist;
    address public allowlist;
    address public sanctionsList;
    uint8 public constant decimals = 18;
    mapping(address account => uint256 value) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;

    function initialize(address blocklist_, address allowlist_, address sanctionsList_) external {
        require(admin == address(0), "INITIALIZED");
        admin = msg.sender;
        blocklist = blocklist_;
        allowlist = allowlist_;
        sanctionsList = sanctionsList_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == admin, "NOT_ADMIN");
        balanceOf[to] += amount;
    }

    function setPaused(bool value) external {
        require(msg.sender == admin, "NOT_ADMIN");
        paused = value;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert("USDY: permit unsupported");
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(!paused, "USDY: paused");
        if (from != msg.sender && to != msg.sender) {
            _requireAccount(msg.sender, "'sender'");
        }
        if (from != address(0)) {
            _requireAccount(from, "'from'");
        }
        if (to != address(0)) {
            _requireAccount(to, "'to'");
        }
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= value, "ALLOWANCE");
        require(balanceOf[from] >= value, "BALANCE");
        allowance[from][msg.sender] = currentAllowance - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    function _requireAccount(address account, string memory label) private view {
        require(!PipelineUsdyList(blocklist).isBlocked(account), string.concat("USDY: ", label, " address blocked"));
        require(
            !PipelineUsdyList(sanctionsList).isSanctioned(account),
            string.concat("USDY: ", label, " address sanctioned")
        );
        require(
            PipelineUsdyList(allowlist).isAllowed(account), string.concat("USDY: ", label, " address not on allowlist")
        );
    }
}

/// @dev 6 位小数结算币。本流水线只用 approve，不走 permit。
contract PipelineCashToken {
    uint8 public constant decimals = 6;
    mapping(address account => uint256 value) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= value, "ALLOWANCE");
        require(balanceOf[from] >= value, "BALANCE");
        allowance[from][msg.sender] = currentAllowance - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }
}

contract UsdyOperatorPipeline is Test {
    struct TradeCashAmounts {
        uint256 buyerFee;
        uint256 sellerFee;
        uint256 buyerDebit;
        uint256 sellerCredit;
        uint256 collectorCredit;
    }

    /// @dev Anvil 默认 account[0]。只用于本地节点，不是生产密钥。
    uint256 private constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 private constant MAKER1_KEY = 0xA11CE;
    uint256 private constant INVESTOR1_KEY = 0xB0B;
    uint256 private constant MAKER2_KEY = 0xC0FFEE;
    uint256 private constant INVESTOR2_KEY = 0xD00D;
    uint256 private constant MAKER3_KEY = 0xE11;
    uint256 private constant UNREGISTERED_KEY = 0xDEAD;

    address private constant GOVERNANCE = address(0x1001);
    address private constant DVP_PAUSER = address(0x2001);
    address private constant REGISTRY_PAUSER = address(0x2301);
    address private constant EXECUTOR = address(0x3001);
    address private constant CONFIGURER = address(0x3301);
    address private constant COLLECTOR = address(0xC011);
    address private constant OUTSIDER = address(0xBAD);

    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0xE313));
    bytes32 private constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0x55D7));
    bytes private constant DEPLOYMENT_VERSION = bytes("1.2.3");
    uint256 private constant PROVIDER_CALL_GAS = 50_000;
    uint64 private constant FEE_EPOCH = 1;
    uint64 private constant QUOTE_VALID_FROM = 1_780_000_000;
    uint64 private constant CREATED_AT = 1_780_000_100;
    // 单笔成交的窗口受 ProtocolSecurityLimits.MAX_QUOTE_LIFETIME（1 小时）约束，
    // 与 Epoch / MarketRule 的配置窗口是两个尺度：前者按一次 RFQ 的寿命计，
    // 后者按一个费率周期计，由 CONFIG_WINDOW_UNTIL 承担。
    uint64 private constant TRADE_DEADLINE = CREATED_AT + 2_000;
    uint64 private constant QUOTE_EXPIRES_AT = CREATED_AT + 3_000;
    uint64 private constant CONFIG_WINDOW_UNTIL = 1_785_000_000;
    uint64 private constant SETTLEMENT_VALID_UNTIL = 1_790_000_000;

    uint256 private constant TRADE_QUANTITY = 10 ether;
    uint256 private constant CASH_PRINCIPAL = 11_400_000;
    uint256 private constant BUYER_FEE = 28_500;
    uint256 private constant SELLER_FEE = 17_100;
    uint256 private constant BUYER_DEBIT = 11_428_500;
    uint256 private constant SELLER_CREDIT = 11_382_900;
    uint256 private constant COLLECTOR_CREDIT = 45_600;
    uint256 private constant INITIAL_CASH = 100_000_000;

    PipelineUsdyList private usdyBlocklist;
    PipelineUsdyList private usdyAllowlist;
    PipelineUsdyList private usdySanctions;
    PipelineUsdy private usdy;
    address private usdyImplementation;
    PipelineCashToken private cash;

    AdapterRegistry private adapterRegistry;
    PrincipalCalculatorRegistry private calculatorRegistry;
    SettlementTokenRegistry private settlementTokenRegistry;
    AssetVersionRegistry private assetVersionRegistry;
    EligibilityRegistry private eligibilityRegistry;
    FeeRegistry private feeRegistry;
    MarketRuleRegistry private marketRuleRegistry;
    ParticipantRegistry private participantRegistry;
    DvPSettlement private dvp;

    IAssetAdapter private cashAdapter;
    IAssetAdapter private usdyAdapter;
    IPrincipalCalculator private fundCalculator;
    AdapterConfig private cashAdapterConfig;
    AdapterConfig private usdyAdapterConfig;
    PrincipalCalculatorConfig private calculatorConfig;
    SettlementTokenConfig private cashTokenConfig;
    AssetVersionConfig private usdyAssetConfig;
    FeePolicyEpochConfig private feeEpochConfig;
    FeeConfig private feeConfig;
    MarketRuleConfig private marketRuleConfig;

    address private deployer;
    address private maker1;
    address private maker2;
    address private investor1;
    address private investor2;
    bool private broadcasting;

    function run() external {
        deployer = vm.addr(DEPLOYER_KEY);
        maker1 = vm.addr(MAKER1_KEY);
        maker2 = vm.addr(MAKER2_KEY);
        investor1 = vm.addr(INVESTOR1_KEY);
        investor2 = vm.addr(INVESTOR2_KEY);

        // 时间戳提前到 CREATED_AT
        vm.warp(CREATED_AT);
        vm.deal(deployer, 10_000 ether);
        // 广播部署者私钥
        _broadcastKey(DEPLOYER_KEY);
        // 给四方打款
        _fundActors();

        // 部署 USDY
        _step1DeployUsdy();
        // 名单管理员放行钱包并 mint
        _step2UsdyAllowWalletsAndMint();
        // 部署 6 位小数结算币，并给四方打款
        _step3DeployCashToken();
        // 部署 HTP：8 Registry → Factory → DvP
        _step4DeployHtpPlatform();
        // 运营角色：initialize 已写入；Governance 再授予独立 DvP Pauser
        _step5OperatorsReceiveRoles();
        // 运营方登记 Adapter / Calculator / 结算币 / USDY Asset Version / Fee
        _step6OperatorsRegisterMarketConfigs();
        // 运营方注册参与者
        _step7OperatorsOnboardParticipants();
        // 运营方批准 DvP 并允许 DvP 暂停
        _step8ApproveAndAllowDvp();
        // DvP Pauser 暂停，Governance 恢复
        _step9PauserStopsThenGovernanceResumes();
        // 四方成功交易
        _step10FourSuccessfulTrades();
        // 失败路径没有留下锁
        _step11FailurePathsLeaveNoLocks();
        // 写入 Anvil 地址
        _writeAnvilAddresses();
        _stopBroadcast();
        emit log_string(unicode"======== 流水线执行完成（dry-run 时仅模拟）========");
        emit log_string("deploy/out/usdy-e2e.json");
    }

    function _step1DeployUsdy() private {
        emit log_string(unicode"======== STEP 1  部署 USDY：名单 + implementation + ERC1967 proxy ========");

        usdyBlocklist = new PipelineUsdyList();
        usdyAllowlist = new PipelineUsdyList();
        usdySanctions = new PipelineUsdyList();
        PipelineUsdy implementation = new PipelineUsdy();
        usdyImplementation = address(implementation);
        usdy = PipelineUsdy(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        PipelineUsdy.initialize,
                        (address(usdyBlocklist), address(usdyAllowlist), address(usdySanctions))
                    )
                )
            )
        );

        emit log_named_address("usdy.proxy", address(usdy));
        emit log_named_address("usdy.implementation", usdyImplementation);
        emit log_named_address("usdy.blocklist", address(usdyBlocklist));
        emit log_named_address("usdy.allowlist", address(usdyAllowlist));
        emit log_named_address("usdy.sanctions", address(usdySanctions));
        assertEq(usdy.decimals(), 18);
        assertEq(usdy.admin(), deployer);
        assertEq(usdy.allowlist(), address(usdyAllowlist));
        _stopBroadcast();
        vm.expectRevert(bytes("USDY: permit unsupported"));
        usdy.permit(address(0), address(0), 0, 0, 0, bytes32(0), bytes32(0));
        _broadcastKey(DEPLOYER_KEY);
    }

    function _step2UsdyAllowWalletsAndMint() private {
        emit log_string(unicode"======== STEP 2  USDY 名单管理员放行钱包并 mint（此时还没有 HTP） ========");

        usdyAllowlist.set(maker1, true);
        usdyAllowlist.set(maker2, true);
        usdyAllowlist.set(investor1, true);
        usdyAllowlist.set(investor2, true);

        usdy.mint(maker1, 100 ether);
        usdy.mint(maker2, 100 ether);
        usdy.mint(investor2, 20 ether);

        emit log_named_address("maker1", maker1);
        emit log_named_address("maker2", maker2);
        emit log_named_address("investor1", investor1);
        emit log_named_address("investor2", investor2);
        assertTrue(usdyAllowlist.isAllowed(maker1));
        assertTrue(usdyAllowlist.isAllowed(maker2));
        assertTrue(usdyAllowlist.isAllowed(investor1));
        assertTrue(usdyAllowlist.isAllowed(investor2));
        assertFalse(usdyBlocklist.isBlocked(maker1));
        assertFalse(usdySanctions.isSanctioned(maker1));
        assertEq(usdy.balanceOf(maker1), 100 ether);
        assertEq(usdy.balanceOf(maker2), 100 ether);
        assertEq(usdy.balanceOf(investor1), 0);
        assertEq(usdy.balanceOf(investor2), 20 ether);
    }

    function _step3DeployCashToken() private {
        emit log_string(unicode"======== STEP 3  部署 6 位小数结算币，并给四方打款 ========");

        cash = new PipelineCashToken();
        cash.mint(maker1, INITIAL_CASH);
        cash.mint(maker2, INITIAL_CASH);
        cash.mint(investor1, INITIAL_CASH);
        cash.mint(investor2, INITIAL_CASH);

        emit log_named_address("cash", address(cash));
        assertEq(cash.decimals(), 6);
        assertEq(cash.balanceOf(investor1), INITIAL_CASH);
    }

    function _step4DeployHtpPlatform() private {
        emit log_string(unicode"======== STEP 4  部署 HTP：8 Registry → Factory → DvP ========");

        uint64 firstCoreNonce = uint64(vm.getNonce(deployer));
        address predictedDvp = vm.computeCreateAddress(deployer, firstCoreNonce + 17);
        emit log_named_address("predictedDvp", predictedDvp);

        AdapterRegistry adapterImpl = new AdapterRegistry();
        adapterRegistry = AdapterRegistry(
            _proxy(
                address(adapterImpl),
                abi.encodeCall(
                    AdapterRegistry.initialize, (GOVERNANCE, GOVERNANCE, GOVERNANCE, REGISTRY_PAUSER, CONFIGURER)
                )
            )
        );

        PrincipalCalculatorRegistry calculatorImpl = new PrincipalCalculatorRegistry();
        calculatorRegistry = PrincipalCalculatorRegistry(
            _proxy(
                address(calculatorImpl),
                abi.encodeCall(
                    PrincipalCalculatorRegistry.initialize,
                    (GOVERNANCE, GOVERNANCE, GOVERNANCE, REGISTRY_PAUSER, CONFIGURER)
                )
            )
        );

        SettlementTokenRegistry settlementImpl = new SettlementTokenRegistry();
        settlementTokenRegistry = SettlementTokenRegistry(
            _proxy(
                address(settlementImpl),
                abi.encodeCall(
                    SettlementTokenRegistry.initialize,
                    (GOVERNANCE, GOVERNANCE, GOVERNANCE, REGISTRY_PAUSER, CONFIGURER, address(adapterRegistry))
                )
            )
        );

        AssetVersionRegistry assetImpl = new AssetVersionRegistry();
        assetVersionRegistry = AssetVersionRegistry(
            _proxy(
                address(assetImpl),
                abi.encodeCall(
                    AssetVersionRegistry.initialize,
                    (
                        GOVERNANCE,
                        GOVERNANCE,
                        GOVERNANCE,
                        REGISTRY_PAUSER,
                        CONFIGURER,
                        address(settlementTokenRegistry),
                        address(adapterRegistry),
                        address(calculatorRegistry)
                    )
                )
            )
        );

        EligibilityRegistry eligibilityImpl = new EligibilityRegistry();
        eligibilityRegistry = EligibilityRegistry(
            _proxy(
                address(eligibilityImpl),
                abi.encodeCall(
                    EligibilityRegistry.initialize, (GOVERNANCE, GOVERNANCE, GOVERNANCE, REGISTRY_PAUSER, CONFIGURER)
                )
            )
        );

        FeeRegistry feeImpl = new FeeRegistry();
        feeRegistry = FeeRegistry(
            _proxy(
                address(feeImpl),
                abi.encodeCall(
                    FeeRegistry.initialize,
                    (
                        GOVERNANCE,
                        GOVERNANCE,
                        GOVERNANCE,
                        REGISTRY_PAUSER,
                        CONFIGURER,
                        address(assetVersionRegistry),
                        address(settlementTokenRegistry)
                    )
                )
            )
        );

        MarketRuleRegistry marketRuleImpl = new MarketRuleRegistry();
        marketRuleRegistry = MarketRuleRegistry(
            _proxy(
                address(marketRuleImpl),
                abi.encodeCall(
                    MarketRuleRegistry.initialize,
                    (
                        GOVERNANCE,
                        GOVERNANCE,
                        GOVERNANCE,
                        REGISTRY_PAUSER,
                        CONFIGURER,
                        address(assetVersionRegistry),
                        address(settlementTokenRegistry)
                    )
                )
            )
        );

        ParticipantRegistry participantImpl = new ParticipantRegistry();
        participantRegistry = ParticipantRegistry(
            _proxy(
                address(participantImpl),
                abi.encodeCall(
                    ParticipantRegistry.initialize, (GOVERNANCE, GOVERNANCE, GOVERNANCE, REGISTRY_PAUSER, CONFIGURER)
                )
            )
        );

        address factory = address(new DvPCurrentStateValidatorFactory());
        dvp = new DvPSettlement(
            DvPRoles({defaultAdmin: GOVERNANCE, governance: GOVERNANCE, pauser: REGISTRY_PAUSER, executor: EXECUTOR}),
            DvPRegistries({
                participant: address(participantRegistry),
                assetVersion: address(assetVersionRegistry),
                eligibility: address(eligibilityRegistry),
                fee: address(feeRegistry),
                marketRule: address(marketRuleRegistry),
                settlementToken: address(settlementTokenRegistry),
                adapter: address(adapterRegistry),
                principalCalculator: address(calculatorRegistry)
            }),
            block.chainid,
            DEPLOYMENT_VERSION,
            factory
        );
        assertEq(address(dvp), predictedDvp, "CREATE sequence drifted");

        _broadcast(GOVERNANCE);
        adapterRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        calculatorRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        settlementTokenRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        assetVersionRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        eligibilityRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        feeRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        marketRuleRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);
        participantRegistry.registerDependentDvp(address(dvp), EVIDENCE_HASH);

        emit log_named_address("dvp", address(dvp));
        emit log_named_address("participantRegistry", address(participantRegistry));
        emit log_named_address("assetVersionRegistry", address(assetVersionRegistry));
        emit log_named_address("eligibilityRegistry", address(eligibilityRegistry));
        emit log_named_address("feeRegistry", address(feeRegistry));
        emit log_named_address("marketRuleRegistry", address(marketRuleRegistry));
        emit log_named_address("settlementTokenRegistry", address(settlementTokenRegistry));
        emit log_named_address("adapterRegistry", address(adapterRegistry));
        emit log_named_address("calculatorRegistry", address(calculatorRegistry));
        assertEq(address(dvp.participantRegistry()), address(participantRegistry));
        assertFalse(dvp.globalPaused());
        assertFalse(dvp.retired());
    }

    function _step5OperatorsReceiveRoles() private {
        emit log_string(unicode"======== STEP 5  运营角色：initialize 已写入；Governance 再授予独立 DvP Pauser ========");

        assertTrue(dvp.hasRole(Roles.DEFAULT_ADMIN_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.GOVERNANCE_ROLE, GOVERNANCE));
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, REGISTRY_PAUSER));
        assertTrue(dvp.hasRole(Roles.EXECUTOR_ROLE, EXECUTOR));
        assertTrue(participantRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(eligibilityRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(assetVersionRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(feeRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(settlementTokenRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(adapterRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertTrue(calculatorRegistry.hasRole(Roles.CONFIGURER_ROLE, CONFIGURER));
        assertFalse(dvp.hasRole(Roles.EXECUTOR_ROLE, OUTSIDER));
        assertFalse(dvp.hasRole(Roles.GOVERNANCE_ROLE, EXECUTOR));

        _broadcast(GOVERNANCE);
        dvp.grantRole(Roles.PAUSER_ROLE, DVP_PAUSER);
        assertTrue(dvp.hasRole(Roles.PAUSER_ROLE, DVP_PAUSER));

        emit log_named_address("governance", GOVERNANCE);
        emit log_named_address("dvpPauser", DVP_PAUSER);
        emit log_named_address("registryPauser", REGISTRY_PAUSER);
        emit log_named_address("executor", EXECUTOR);
        emit log_named_address("configurer", CONFIGURER);
        emit log_named_address("feeCollector", COLLECTOR);
    }

    // 生产形态：先一批登记，再一批激活。
    // 登记只要求被引用配置已存在且内容哈希一致，不要求已激活，所以整条引用链
    // （Adapter/Calculator → 结算币 → Asset Version → Market Rule）可以一次登记完。
    // 激活按依赖序执行，因为激活会复查被引用配置是否 ACTIVE。
    // 唯一的治理前置是 createFeePolicyEpoch：registerFeeVersion 要求 Epoch 已存在且未封存。
    function _step6OperatorsRegisterMarketConfigs() private {
        emit log_string(unicode"======== STEP 6  运营方登记 Adapter / Calculator / 结算币 / USDY Asset Version / Fee ========");

        _step6aDeployImmutableComponents();
        _buildMarketConfigs();
        _step6bGovernanceOpensFeeEpoch();
        _step6cConfigurerRegistersEveryConfig();
        _step6dGovernanceActivatesEveryConfig();

        assertEq(uint8(usdyAssetConfig.assetPermitCapability), uint8(PermitCapability.UNSUPPORTED));
    }

    function _step6aDeployImmutableComponents() private {
        _broadcastKey(DEPLOYER_KEY);
        cashAdapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dvp))));
        usdyAdapter = IAssetAdapter(
            address(
                new UsdyRestrictedAdapter(
                    address(dvp),
                    address(usdy),
                    address(usdy).codehash,
                    address(usdyBlocklist),
                    address(usdyBlocklist).codehash,
                    address(usdyAllowlist),
                    address(usdyAllowlist).codehash,
                    address(usdySanctions),
                    address(usdySanctions).codehash,
                    PROVIDER_CALL_GAS
                )
            )
        );
        fundCalculator = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        emit log_string(unicode"6a  部署不可升级组件：两个 Adapter + Fund Calculator");
    }

    // 只构造配置结构体与哈希，不发任何交易。
    function _buildMarketConfigs() private {
        cashAdapterConfig = _adapterConfig(cashAdapter, 1);
        usdyAdapterConfig = _adapterConfig(usdyAdapter, 1);

        calculatorConfig = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(fundCalculator),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(fundCalculator).codehash,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        calculatorConfig.configHash = HTPHashing.hashPrincipalCalculatorConfig(calculatorConfig);

        cashTokenConfig = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE, 1, block.chainid, bytes32(uint256(uint160(address(cash)))), 1
            ),
            revision: 1,
            chainId: block.chainid,
            settlementToken: address(cash),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: 6,
            tokenCodeHash: address(cash).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: cashAdapterConfig.adapterConfigId,
            adapterConfigHash: cashAdapterConfig.configHash,
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        cashTokenConfig.configHash = HTPHashing.hashSettlementTokenConfig(cashTokenConfig);

        usdyAssetConfig = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: ECONOMIC_ASSET_ID_HASH,
            assetVersionId: ConfigId.assetVersion(1, ECONOMIC_ASSET_ID_HASH, block.chainid, address(usdy), 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: address(usdy),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.ERC1967_PROXY,
            assetDecimals: 18,
            tokenCodeHash: address(usdy).codehash,
            implementation: usdyImplementation,
            implementationCodeHash: usdyImplementation.codehash,
            assetPermitCapability: PermitCapability.UNSUPPORTED,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: usdyAdapterConfig.adapterConfigId,
            adapterConfigHash: usdyAdapterConfig.configHash,
            restrictionMode: RestrictionMode.TOKEN_ENFORCED,
            settlementToken: address(cash),
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            dvpContract: address(dvp),
            deploymentVersionHash: dvp.deploymentVersionHash(),
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        usdyAssetConfig.configHash = HTPHashing.hashAssetVersionConfig(usdyAssetConfig);

        marketRuleConfig = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, usdyAssetConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: usdyAssetConfig.assetVersionId,
            settlementToken: address(cash),
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            minCashPrincipal: 1_000_000,
            minExecutableQuantity: 1 ether,
            quantityStep: 1 ether,
            priceTick: 10_000,
            priceDecimals: 2,
            quantityDecimals: 1,
            quoteValidFrom: QUOTE_VALID_FROM,
            quoteValidUntil: CONFIG_WINDOW_UNTIL,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        marketRuleConfig.configHash = HTPHashing.hashMarketRuleConfig(marketRuleConfig);

        feeEpochConfig = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: FEE_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: QUOTE_VALID_FROM,
            quoteValidUntil: CONFIG_WINDOW_UNTIL,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        feeEpochConfig.configHash = HTPHashing.hashFeePolicyEpochConfig(feeEpochConfig);

        bytes32 matchedScopeHash =
            FeeScope.matchedHash(FEE_EPOCH, ScopeType.ASSET_VERSION, usdyAssetConfig.assetVersionId);
        feeConfig = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: FEE_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: usdyAssetConfig.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(cash),
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: QUOTE_VALID_FROM,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        feeConfig.feeConstraintHash = HTPHashing.hashFeeConstraint(feeConfig);
        feeConfig.configHash = HTPHashing.hashFeeConfig(feeConfig);
    }

    // 治理前置：registerFeeVersion 要求 Epoch 已存在且未封存，所以它必须早于登记批次。
    function _step6bGovernanceOpensFeeEpoch() private {
        _broadcast(GOVERNANCE);
        feeRegistry.createFeePolicyEpoch(feeEpochConfig);
        emit log_string(unicode"6b  governance.createFeePolicyEpoch  （登记费率的前置）");
    }

    // 登记批次：同一角色、同一批次登记全部七条配置。
    // 此时被引用的 Adapter / Calculator / 结算币 / Asset Version 都还没激活，登记依然成立。
    function _step6cConfigurerRegistersEveryConfig() private {
        _broadcast(CONFIGURER);
        adapterRegistry.registerAdapter(cashAdapterConfig);
        adapterRegistry.registerAdapter(usdyAdapterConfig);
        calculatorRegistry.registerPrincipalCalculator(calculatorConfig);
        settlementTokenRegistry.registerSettlementToken(cashTokenConfig);
        assetVersionRegistry.registerAssetVersion(usdyAssetConfig);
        marketRuleRegistry.registerMarketRule(marketRuleConfig);
        feeRegistry.registerFeeVersion(feeConfig);

        // 登记完成但全部尚未生效：此时没有任何配置可用于结算。
        assertEq(
            uint8(adapterRegistry.getAdapter(cashAdapterConfig.adapterConfigId).status), uint8(AdapterStatus.REGISTERED)
        );
        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(usdyAssetConfig.assetVersionId).status),
            uint8(AssetVersionStatus.REGISTERED)
        );
        // 结算币是整条引用链的共同前置：此刻它尚不可服务，
        // 证明上面六条登记确实是在「引用未激活」的状态下成立的。
        assertFalse(
            settlementTokenRegistry.isSettlementTokenConfigActive(cashTokenConfig.configId, cashTokenConfig.configHash)
        );
        emit log_string(unicode"6c  configurer 一批登记 7 条配置（引用尚未激活，登记仍成立）");
    }

    // 激活批次：必须按依赖序，因为激活会复查被引用配置是否 ACTIVE。
    // 顺序：Adapter/Calculator → 结算币 → Asset Version → Market Rule → Fee。
    function _step6dGovernanceActivatesEveryConfig() private {
        _broadcast(GOVERNANCE);
        adapterRegistry.activateAdapter(cashAdapterConfig.adapterConfigId, cashAdapterConfig.configHash);
        adapterRegistry.activateAdapter(usdyAdapterConfig.adapterConfigId, usdyAdapterConfig.configHash);
        calculatorRegistry.activatePrincipalCalculator(calculatorConfig.calculatorConfigId, calculatorConfig.configHash);
        settlementTokenRegistry.activateSettlementToken(cashTokenConfig.configId, cashTokenConfig.configHash);
        assetVersionRegistry.activateAssetVersion(usdyAssetConfig.assetVersionId, usdyAssetConfig.configHash);
        marketRuleRegistry.sealMarketRule(marketRuleConfig.marketRuleConfigId, marketRuleConfig.configHash);
        marketRuleRegistry.activateMarketRule(marketRuleConfig.marketRuleConfigId, marketRuleConfig.configHash);
        feeRegistry.sealFeePolicyEpoch(FEE_EPOCH, feeEpochConfig.configHash);
        feeRegistry.activateFeeVersion(feeConfig.feeVersionId, feeConfig.configHash);
        feeRegistry.activateFeePolicyEpoch(FEE_EPOCH, feeEpochConfig.configHash, feeConfig.feeVersionId);

        assertEq(
            uint8(adapterRegistry.getAdapter(usdyAdapterConfig.adapterConfigId).status), uint8(AdapterStatus.ACTIVE)
        );
        assertEq(
            uint8(assetVersionRegistry.getAssetVersion(usdyAssetConfig.assetVersionId).status),
            uint8(AssetVersionStatus.ACTIVE)
        );
        assertTrue(
            settlementTokenRegistry.isSettlementTokenConfigActive(cashTokenConfig.configId, cashTokenConfig.configHash)
        );
        emit log_string(unicode"6d  governance 一批激活全部配置（buyer 25bps / seller 15bps）");
    }

    function _step7OperatorsOnboardParticipants() private {
        emit log_string(unicode"======== STEP 7  运营方登记参与方、Eligibility，并现场再接入 Maker3 ========");

        _registerParticipant(maker1, bytes32(uint256(0xA001)), ParticipantType.MAKER);
        _registerParticipant(maker2, bytes32(uint256(0xA003)), ParticipantType.MAKER);
        _registerParticipant(investor1, bytes32(uint256(0xA002)), ParticipantType.INVESTOR);
        _registerParticipant(investor2, bytes32(uint256(0xA004)), ParticipantType.INVESTOR);
        _grantBothEligibilities(maker1);
        _grantBothEligibilities(maker2);
        _grantBothEligibilities(investor1);
        _grantBothEligibilities(investor2);
        emit log_string(unicode"configurer 登记 Maker1/2 与 Investor1/2");

        address maker3 = vm.addr(MAKER3_KEY);
        _registerParticipant(maker3, bytes32(uint256(0xA005)), ParticipantType.MAKER);
        _grantBothEligibilities(maker3);
        _broadcastKey(DEPLOYER_KEY);
        usdyAllowlist.set(maker3, true);
        emit log_named_address("liveOnboard.maker3", maker3);
        assertEq(uint8(participantRegistry.getParticipant(maker3).participantType), uint8(ParticipantType.MAKER));
        assertTrue(usdyAllowlist.isAllowed(maker3));
    }

    function _step8ApproveAndAllowDvp() private {
        emit log_string(unicode"======== STEP 8  把 DvP 加入 USDY allowlist，各方 approve 给 DvP ========");

        _broadcastKey(DEPLOYER_KEY);
        usdyAllowlist.set(address(dvp), true);
        _broadcastKey(MAKER1_KEY);
        usdy.approve(address(dvp), 100 ether);
        cash.approve(address(dvp), INITIAL_CASH);
        _broadcastKey(MAKER2_KEY);
        usdy.approve(address(dvp), 100 ether);
        cash.approve(address(dvp), INITIAL_CASH);
        _broadcastKey(INVESTOR2_KEY);
        usdy.approve(address(dvp), 20 ether);
        cash.approve(address(dvp), INITIAL_CASH);
        _broadcastKey(INVESTOR1_KEY);
        cash.approve(address(dvp), INITIAL_CASH);

        assertTrue(usdyAllowlist.isAllowed(address(dvp)));
        assertEq(usdy.allowance(maker1, address(dvp)), 100 ether);
        assertEq(cash.allowance(investor1, address(dvp)), INITIAL_CASH);
        assertEq(usdy.balanceOf(address(dvp)), 0);
    }

    function _step9PauserStopsThenGovernanceResumes() private {
        emit log_string(unicode"======== STEP 9  Pauser 紧急暂停，Executor 无法结算，Governance 恢复 ========");

        SettlementParams memory pausedTrade =
            _buildTrade(MAKER1_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 50);

        _broadcast(DVP_PAUSER);
        dvp.pauseGlobal(ReasonCode.SECURITY_INCIDENT, EVIDENCE_HASH);
        assertTrue(dvp.globalPaused());
        emit log_string("dvpPauser.pauseGlobal");

        _stopBroadcast();
        vm.expectRevert(HTPErrors.ContractPaused.selector);
        vm.prank(EXECUTOR);
        dvp.settle(pausedTrade);
        _assertUnused(pausedTrade);
        emit log_string(unicode"executor.settle 在暂停期间被拒绝，Hash/Nonce 未消费");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, DVP_PAUSER, Roles.GOVERNANCE_ROLE
            )
        );
        vm.prank(DVP_PAUSER);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        emit log_string(unicode"pauser 不能自己恢复");

        _broadcast(GOVERNANCE);
        dvp.unpauseGlobal(ReasonCode.GOVERNANCE_ACTION, EVIDENCE_HASH);
        assertFalse(dvp.globalPaused());
        emit log_string("governance.unpauseGlobal");
    }

    function _step10FourSuccessfulTrades() private {
        emit log_string(unicode"======== STEP 10  成交：Investor 买/卖 + Maker 对 Maker ========");

        _settleLogged(
            "Investor1 BUY vs Maker1",
            _buildTrade(MAKER1_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 1)
        );
        _settleLogged(
            "Investor2 SELL vs Maker2",
            _buildTrade(MAKER2_KEY, INVESTOR2_KEY, ParticipantType.INVESTOR, RequesterSide.SELL, 2)
        );
        _settleLogged(
            "Maker1 BUY vs Maker2", _buildTrade(MAKER2_KEY, MAKER1_KEY, ParticipantType.MAKER, RequesterSide.BUY, 3)
        );
        _settleLogged(
            "Maker2 SELL vs Maker1", _buildTrade(MAKER1_KEY, MAKER2_KEY, ParticipantType.MAKER, RequesterSide.SELL, 4)
        );

        assertEq(usdy.balanceOf(maker1), 110 ether);
        assertEq(usdy.balanceOf(maker2), 90 ether);
        assertEq(usdy.balanceOf(investor1), 10 ether);
        assertEq(usdy.balanceOf(investor2), 10 ether);
        assertEq(cash.balanceOf(COLLECTOR), 159_600);
        assertEq(usdy.balanceOf(address(dvp)), 0);
        assertEq(cash.balanceOf(address(dvp)), 0);
        emit log_named_uint("collector.cash.afterFourTrades", cash.balanceOf(COLLECTOR));
    }

    function _step11FailurePathsLeaveNoLocks() private {
        emit log_string(unicode"======== STEP 11  失败路径：权限、关系、限制变化、Permit，状态回滚 ========");

        _stopBroadcast();

        SettlementParams memory outsiderTrade =
            _buildTrade(MAKER1_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 91);
        ObservableState memory beforeOutsider = _observe();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, Roles.EXECUTOR_ROLE
            )
        );
        vm.prank(OUTSIDER);
        dvp.settle(outsiderTrade);
        _assertUnchanged(beforeOutsider);
        _assertUnused(outsiderTrade);
        emit log_string(unicode"非 Executor 不能 settle");

        SettlementParams memory investorMaker =
            _buildTrade(INVESTOR2_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 92);
        _assertPreCheckBlock(investorMaker, HTPErrors.ParticipantInactive.selector);
        ObservableState memory beforeInvestorMaker = _observe();
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantInactive.selector, investor2));
        vm.prank(EXECUTOR);
        dvp.settle(investorMaker);
        _assertUnchanged(beforeInvestorMaker);
        _assertUnused(investorMaker);
        emit log_string(unicode"Investor 不能充当 quoting maker");

        SettlementParams memory unregistered =
            _buildTrade(MAKER1_KEY, UNREGISTERED_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 93);
        address unknownWallet = vm.addr(UNREGISTERED_KEY);
        _assertPreCheckBlock(unregistered, HTPErrors.ParticipantInactive.selector);
        vm.expectRevert(abi.encodeWithSelector(HTPErrors.ParticipantInactive.selector, unknownWallet));
        vm.prank(EXECUTOR);
        dvp.settle(unregistered);
        _assertUnused(unregistered);
        emit log_string(unicode"未登记钱包不能成交");

        SettlementParams memory restricted =
            _buildTrade(MAKER1_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 94);
        _assertPreCheckPass(restricted);
        _broadcastKey(DEPLOYER_KEY);
        usdyBlocklist.set(restricted.snapshot.seller, true);
        _stopBroadcast();
        ObservableState memory beforeRestricted = _observe();
        vm.expectPartialRevert(HTPErrors.TransferRestricted.selector);
        vm.prank(EXECUTOR);
        dvp.settle(restricted);
        _assertUnchanged(beforeRestricted);
        _assertUnused(restricted);
        _broadcastKey(DEPLOYER_KEY);
        usdyBlocklist.set(restricted.snapshot.seller, false);
        _stopBroadcast();
        emit log_string(unicode"preCheck PASS 之后加入 Blocklist，settle 失败且无残留锁");

        SettlementParams memory permitRejected =
            _buildTrade(MAKER1_KEY, INVESTOR1_KEY, ParticipantType.INVESTOR, RequesterSide.BUY, 95);
        permitRejected.assetPermit = PermitData({
            usePermit: true,
            owner: permitRejected.snapshot.seller,
            token: permitRejected.snapshot.assetToken,
            value: permitRejected.snapshot.executedQuantity,
            deadline: permitRejected.snapshot.tradeDeadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        _assertPreCheckBlock(permitRejected, HTPErrors.InvalidSettlementParams.selector);
        vm.expectRevert(
            abi.encodeWithSelector(HTPErrors.PermitUnsupported.selector, permitRejected.snapshot.assetToken)
        );
        vm.prank(EXECUTOR);
        dvp.settle(permitRejected);
        _assertUnused(permitRejected);
        emit log_string(unicode"USDY PermitCapability.UNSUPPORTED，携带 permit 被拒绝");
    }

    function _fundActors() private {
        address[18] memory actors = [
            GOVERNANCE,
            DVP_PAUSER,
            REGISTRY_PAUSER,
            EXECUTOR,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            CONFIGURER,
            OUTSIDER,
            maker1,
            maker2,
            investor1,
            investor2,
            vm.addr(MAKER3_KEY)
        ];
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
    }

    function _fund(address account) private {
        (bool ok,) = account.call{value: 1 ether}("");
        require(ok, "FUND");
    }

    function _broadcast(address account) private {
        _stopBroadcast();
        vm.startBroadcast(account);
        broadcasting = true;
    }

    function _broadcastKey(uint256 key) private {
        _stopBroadcast();
        vm.startBroadcast(key);
        broadcasting = true;
    }

    function _stopBroadcast() private {
        if (broadcasting) {
            vm.stopBroadcast();
            broadcasting = false;
        }
    }

    function _writeAnvilAddresses() private {
        string memory k = "e2e";
        vm.serializeString(k, "rpc", "http://127.0.0.1:8545");
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "governance", GOVERNANCE);
        vm.serializeAddress(k, "dvp", address(dvp));
        vm.serializeAddress(k, "usdy", address(usdy));
        vm.serializeAddress(k, "cash", address(cash));
        vm.serializeAddress(k, "participantRegistry", address(participantRegistry));
        vm.serializeAddress(k, "assetVersionRegistry", address(assetVersionRegistry));
        vm.serializeAddress(k, "eligibilityRegistry", address(eligibilityRegistry));
        vm.serializeAddress(k, "feeRegistry", address(feeRegistry));
        vm.serializeAddress(k, "marketRuleRegistry", address(marketRuleRegistry));
        vm.serializeAddress(k, "settlementTokenRegistry", address(settlementTokenRegistry));
        vm.serializeAddress(k, "adapterRegistry", address(adapterRegistry));
        vm.serializeAddress(k, "calculatorRegistry", address(calculatorRegistry));
        vm.serializeAddress(k, "maker1", maker1);
        vm.serializeAddress(k, "maker2", maker2);
        vm.serializeAddress(k, "investor1", investor1);
        string memory json = vm.serializeAddress(k, "investor2", investor2);
        vm.writeJson(json, "../deploy/out/usdy-e2e.json");
        emit log_named_address("anvil.dvp", address(dvp));
        emit log_named_address("anvil.usdy", address(usdy));
    }

    function _proxy(address implementation, bytes memory initData) private returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }

    function _adapterConfig(IAssetAdapter adapter, uint32 revision) private view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = adapter.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, revision),
            revision: revision,
            chainId: block.chainid,
            adapter: address(adapter),
            interfaceVersion: InterfaceVersions.ASSET_ADAPTER_V1,
            codeHash: address(adapter).codehash,
            capabilities: capabilities,
            capabilityHash: capabilityHash,
            providerHash: adapter.providerHash(),
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAdapterConfig(config);
    }

    function _registerParticipant(address wallet, bytes32 participantIdHash, ParticipantType participantType) private {
        _broadcast(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: wallet,
                participantIdHash: participantIdHash,
                participantType: participantType,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _grantBothEligibilities(address wallet) private {
        _setEligibility(wallet);
    }

    function _setEligibility(address wallet) private {
        _broadcast(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: wallet,
                assetVersionId: usdyAssetConfig.assetVersionId,
                decision: Decision.PASS,
                validFrom: QUOTE_VALID_FROM,
                validUntil: SETTLEMENT_VALID_UNTIL,
                kycDecisionVersion: bytes32(uint256(0xD200)),
                permissionVersion: bytes32(uint256(0xD201)),
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _buildTrade(
        uint256 quotingMakerKey,
        uint256 requesterKey,
        ParticipantType requesterType,
        RequesterSide side,
        uint256 sequence
    ) private view returns (SettlementParams memory params) {
        address quotingMaker = vm.addr(quotingMakerKey);
        address requester = vm.addr(requesterKey);
        address buyer = side == RequesterSide.BUY ? requester : quotingMaker;
        address seller = side == RequesterSide.BUY ? quotingMaker : requester;
        TradeCashAmounts memory amounts = _tradeCashAmounts(requesterType, side);

        FundPriceTerms memory terms =
            FundPriceTerms({navPerUnit: 1_140_000, navDate: 20260810, navSourceHash: bytes32(uint256(0x201))});
        bytes memory priceData = abi.encode(terms);
        bytes32 priceTermsHash = HTPHashing.hashFundPriceTerms(terms);

        params.firmQuote = FirmQuote({
            schemaVersion: 1,
            rfqIdHash: bytes32(uint256(0x601) + sequence),
            quoteIdHash: bytes32(uint256(0x602) + sequence),
            // N10: Allocate the trade ID before quoting so the maker signature binds it.
            tradeIdHash: bytes32(uint256(0x501) + sequence),
            quoteVersion: 1,
            quotingMaker: quotingMaker,
            requester: requester,
            requesterType: requesterType,
            assetVersionId: usdyAssetConfig.assetVersionId,
            requesterSide: side,
            assetToken: address(usdy),
            settlementToken: address(cash),
            assetClass: AssetClass.FUND,
            priceTermsHash: priceTermsHash,
            priceData: priceData,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: usdyAdapterConfig.adapterConfigId,
            adapterConfigHash: usdyAdapterConfig.configHash,
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            marketRuleConfigId: marketRuleConfig.marketRuleConfigId,
            marketRuleConfigHash: marketRuleConfig.configHash,
            minExecutableQuantity: 1 ether,
            maxExecutableQuantity: 100 ether,
            stepQuantity: 1 ether,
            feePolicyEpoch: FEE_EPOCH,
            feeVersionId: feeConfig.feeVersionId,
            matchedScopeHash: feeConfig.matchedScopeHash,
            feeConstraintHash: feeConfig.feeConstraintHash,
            quoteNonce: 41 + sequence,
            expiresAt: QUOTE_EXPIRES_AT
        });

        params.snapshot = TradeTermsSnapshot({
            schemaVersion: 1,
            tradeIdHash: params.firmQuote.tradeIdHash,
            quoteHash: bytes32(0),
            chainId: block.chainid,
            dvpContract: address(dvp),
            requester: requester,
            requesterType: requesterType,
            quotingMaker: quotingMaker,
            requesterSide: side,
            buyer: buyer,
            seller: seller,
            assetVersionId: usdyAssetConfig.assetVersionId,
            assetToken: address(usdy),
            settlementToken: address(cash),
            assetDecimals: 18,
            settlementTokenDecimals: 6,
            executedQuantity: TRADE_QUANTITY,
            assetClass: AssetClass.FUND,
            priceTermsHash: priceTermsHash,
            priceData: priceData,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: usdyAdapterConfig.adapterConfigId,
            adapterConfigHash: usdyAdapterConfig.configHash,
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            marketRuleConfigId: marketRuleConfig.marketRuleConfigId,
            marketRuleConfigHash: marketRuleConfig.configHash,
            cashPrincipal: CASH_PRINCIPAL,
            buyerFee: amounts.buyerFee,
            sellerFee: amounts.sellerFee,
            buyerDebit: amounts.buyerDebit,
            sellerCredit: amounts.sellerCredit,
            collectorCredit: amounts.collectorCredit,
            collector: COLLECTOR,
            feePolicyEpoch: FEE_EPOCH,
            feeVersionId: feeConfig.feeVersionId,
            matchedScopeHash: feeConfig.matchedScopeHash,
            feeConstraintHash: feeConfig.feeConstraintHash,
            roundingMode: RoundingMode.DOWN,
            makerQuoteNonce: 41 + sequence,
            requesterTradeNonce: 52 + sequence,
            quoteExpiresAt: QUOTE_EXPIRES_AT,
            tradeDeadline: TRADE_DEADLINE,
            createdAt: CREATED_AT
        });

        params.tradeIntent = TradeIntent({
            schemaVersion: 1,
            tradeIdHash: params.snapshot.tradeIdHash,
            quoteHash: bytes32(0),
            snapshotHash: bytes32(0),
            requester: requester,
            requesterType: requesterType,
            quotingMaker: quotingMaker,
            assetVersionId: usdyAssetConfig.assetVersionId,
            requesterSide: side,
            buyer: buyer,
            seller: seller,
            assetToken: address(usdy),
            settlementToken: address(cash),
            executedQuantity: TRADE_QUANTITY,
            assetClass: AssetClass.FUND,
            priceTermsHash: priceTermsHash,
            priceData: priceData,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: usdyAdapterConfig.adapterConfigId,
            adapterConfigHash: usdyAdapterConfig.configHash,
            settlementTokenConfigId: cashTokenConfig.configId,
            settlementTokenConfigHash: cashTokenConfig.configHash,
            marketRuleConfigId: marketRuleConfig.marketRuleConfigId,
            marketRuleConfigHash: marketRuleConfig.configHash,
            cashPrincipal: CASH_PRINCIPAL,
            buyerFee: amounts.buyerFee,
            sellerFee: amounts.sellerFee,
            buyerDebit: amounts.buyerDebit,
            sellerCredit: amounts.sellerCredit,
            collectorCredit: amounts.collectorCredit,
            collector: COLLECTOR,
            feePolicyEpoch: FEE_EPOCH,
            feeVersionId: feeConfig.feeVersionId,
            matchedScopeHash: feeConfig.matchedScopeHash,
            feeConstraintHash: feeConfig.feeConstraintHash,
            roundingMode: RoundingMode.DOWN,
            tradeNonce: 52 + sequence,
            deadline: TRADE_DEADLINE
        });

        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        params.tradeIntent.snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.quotingMakerSignature = _sign(quotingMakerKey, quoteDigest);
        params.requesterSignature =
            _sign(requesterKey, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
    }

    function _tradeCashAmounts(ParticipantType requesterType, RequesterSide side)
        private
        pure
        returns (TradeCashAmounts memory amounts)
    {
        bool requesterIsInvestor = requesterType == ParticipantType.INVESTOR;
        amounts.buyerFee = requesterIsInvestor && side == RequesterSide.BUY ? BUYER_FEE : SELLER_FEE;
        amounts.sellerFee = requesterIsInvestor && side == RequesterSide.SELL ? BUYER_FEE : SELLER_FEE;
        amounts.buyerDebit = CASH_PRINCIPAL + amounts.buyerFee;
        amounts.sellerCredit = CASH_PRINCIPAL - amounts.sellerFee;
        amounts.collectorCredit = amounts.buyerFee + amounts.sellerFee;
    }

    function _sign(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settleLogged(string memory label, SettlementParams memory params) private {
        emit log_string(label);
        _assertPreCheckPass(params);
        uint256 sellerAssetBefore = usdy.balanceOf(params.snapshot.seller);
        uint256 buyerAssetBefore = usdy.balanceOf(params.snapshot.buyer);
        uint256 collectorBefore = cash.balanceOf(COLLECTOR);

        _broadcast(EXECUTOR);
        dvp.settle(params);

        assertEq(usdy.balanceOf(params.snapshot.seller), sellerAssetBefore - TRADE_QUANTITY);
        assertEq(usdy.balanceOf(params.snapshot.buyer), buyerAssetBefore + TRADE_QUANTITY);
        assertEq(cash.balanceOf(COLLECTOR), collectorBefore + params.snapshot.collectorCredit);
        _assertConsumed(params);
        emit log_named_address("  buyer", params.snapshot.buyer);
        emit log_named_address("  seller", params.snapshot.seller);
        emit log_named_uint("  collectorDelta", params.snapshot.collectorCredit);
    }

    struct ObservableState {
        uint256 maker1Asset;
        uint256 maker2Asset;
        uint256 investor1Asset;
        uint256 investor2Asset;
        uint256 dvpAsset;
        uint256 maker1Cash;
        uint256 maker2Cash;
        uint256 investor1Cash;
        uint256 investor2Cash;
        uint256 collectorCash;
        uint256 dvpCash;
        uint256 maker1AssetAllowance;
        uint256 maker2AssetAllowance;
        uint256 investor2AssetAllowance;
        uint256 maker1CashAllowance;
        uint256 maker2CashAllowance;
        uint256 investor1CashAllowance;
        uint256 investor2CashAllowance;
    }

    function _observe() private view returns (ObservableState memory state) {
        state.maker1Asset = usdy.balanceOf(maker1);
        state.maker2Asset = usdy.balanceOf(maker2);
        state.investor1Asset = usdy.balanceOf(investor1);
        state.investor2Asset = usdy.balanceOf(investor2);
        state.dvpAsset = usdy.balanceOf(address(dvp));
        state.maker1Cash = cash.balanceOf(maker1);
        state.maker2Cash = cash.balanceOf(maker2);
        state.investor1Cash = cash.balanceOf(investor1);
        state.investor2Cash = cash.balanceOf(investor2);
        state.collectorCash = cash.balanceOf(COLLECTOR);
        state.dvpCash = cash.balanceOf(address(dvp));
        state.maker1AssetAllowance = usdy.allowance(maker1, address(dvp));
        state.maker2AssetAllowance = usdy.allowance(maker2, address(dvp));
        state.investor2AssetAllowance = usdy.allowance(investor2, address(dvp));
        state.maker1CashAllowance = cash.allowance(maker1, address(dvp));
        state.maker2CashAllowance = cash.allowance(maker2, address(dvp));
        state.investor1CashAllowance = cash.allowance(investor1, address(dvp));
        state.investor2CashAllowance = cash.allowance(investor2, address(dvp));
    }

    function _assertPreCheckPass(SettlementParams memory params) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.PASS));
        assertEq(reason, bytes4(0));
    }

    function _assertPreCheckBlock(SettlementParams memory params, bytes4 expectedReason) private view {
        (Decision decision, bytes4 reason) = dvp.preCheck(params);
        assertEq(uint8(decision), uint8(Decision.BLOCK));
        assertEq(reason, expectedReason);
    }

    function _assertUnchanged(ObservableState memory beforeState) private view {
        ObservableState memory afterState = _observe();
        assertEq(keccak256(abi.encode(afterState)), keccak256(abi.encode(beforeState)));
    }

    function _assertUnused(SettlementParams memory params) private view {
        assertFalse(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertFalse(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertFalse(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.UNUSED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.UNUSED)
        );
    }

    function _assertConsumed(SettlementParams memory params) private view {
        assertTrue(dvp.usedQuoteHash(params.tradeIntent.quoteHash));
        assertTrue(dvp.usedSnapshotHash(params.tradeIntent.snapshotHash));
        assertTrue(dvp.usedTradeIdHash(params.tradeIntent.tradeIdHash));
        assertEq(
            uint8(
                dvp.getNonceStatus(params.firmQuote.quotingMaker, NonceType.MAKER_QUOTE, params.firmQuote.quoteNonce)
            ),
            uint8(NonceStatus.USED)
        );
        assertEq(
            uint8(
                dvp.getNonceStatus(
                    params.tradeIntent.requester, NonceType.REQUESTER_TRADE, params.tradeIntent.tradeNonce
                )
            ),
            uint8(NonceStatus.USED)
        );
    }
}
