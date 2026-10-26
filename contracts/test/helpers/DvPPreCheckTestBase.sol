// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {CoreDeploymentTopology} from "script/CoreDeploymentTopology.sol";
import {CoreDeployment, DeploymentConfig, DeploymentRoles, DirectOperation} from "script/DeployTypes.sol";
import {DeploymentOperationBuilder} from "script/DeploymentOperationBuilder.sol";
import {UnrestrictedERC20Adapter} from "src/adapters/UnrestrictedERC20Adapter.sol";
import {FundPrincipalCalculator} from "src/calculators/FundPrincipalCalculator.sol";
import {DvPSettlement} from "src/DvPSettlement.sol";
import {IAssetAdapter} from "src/interfaces/IAssetAdapter.sol";
import {IPrincipalCalculator} from "src/interfaces/IPrincipalCalculator.sol";
import {InterfaceVersions} from "src/interfaces/InterfaceVersions.sol";
import {ConfigId} from "src/libraries/ConfigId.sol";
import {FeeMath} from "src/libraries/FeeMath.sol";
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
import {
    AdapterCapabilities,
    AdapterConfig,
    AssetClass,
    AssetVersionConfig,
    Decision,
    EligibilityInput,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    ParticipantInput,
    ParticipantType,
    PermitCapability,
    PrincipalCalculatorConfig,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementParams,
    SettlementTokenConfig,
    TokenDeploymentKind,
    TokenStandard
} from "src/types/HTPTypes.sol";
import {SchemaFixtures} from "../generated/SchemaFixtures.sol";
import {RegistryTestBase} from "./RegistryTestBase.sol";

contract DvPPreCheckToken {
    uint8 private immutable TOKEN_DECIMALS;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;
    mapping(address account => uint256 value) public balanceOf;
    uint256 public permitCalls;
    uint8 public transferMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes4 public callbackRevertSelector;

    constructor(uint8 decimals_) {
        TOKEN_DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return TOKEN_DECIMALS;
    }

    function setAllowance(address owner, address spender, uint256 value) external {
        allowance[owner][spender] = value;
    }

    function setBalance(address account, uint256 value) external {
        balanceOf[account] = value;
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        ++permitCalls;
        _runCallback();
        allowance[owner][spender] = value;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _runCallback();
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= value, "ALLOWANCE");
        require(balanceOf[from] >= value, "BALANCE");
        allowance[from][msg.sender] = currentAllowance - value;
        balanceOf[from] -= value;
        uint256 received = transferMode == 3 && value != 0 ? value - 1 : value;
        balanceOf[to] += received;
        if (transferMode == 5) balanceOf[msg.sender] += 1;
        if (transferMode == 6) balanceOf[from] += value * 2;
        if (transferMode == 1) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (transferMode == 2) return false;
        if (transferMode == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0x1f, 1)
            }
        }
        return true;
    }

    function _runCallback() private {
        if (callbackTarget == address(0)) return;
        bytes memory returnData;
        (callbackSucceeded, returnData) = callbackTarget.call(callbackData);
        if (returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            callbackRevertSelector = selector;
        }
    }
}

abstract contract DvPPreCheckTestBase is RegistryTestBase, CoreDeploymentTopology {
    uint256 internal constant MAKER_KEY = 0xA11CE;
    uint256 internal constant REQUESTER_KEY = 0xB0B;
    address internal constant DVP_PAUSER = address(0x2001);
    address internal constant EXECUTOR = address(0x3001);
    address internal constant REGISTRY_PAUSER = address(0x2301);
    address internal constant CONFIGURER = address(0x3301);
    address internal constant COLLECTOR = address(0xC011);
    bytes32 internal constant EVIDENCE_HASH = bytes32(uint256(0xE313));
    bytes32 internal constant ECONOMIC_ASSET_ID_HASH = bytes32(uint256(0xA55E7));
    uint64 internal constant FEE_EPOCH = 1;
    uint64 internal constant QUOTE_VALID_FROM = 1_780_000_000;
    uint64 internal constant CREATED_AT = 1_780_000_100;
    // 单笔成交的窗口受 ProtocolSecurityLimits.MAX_QUOTE_LIFETIME（1 小时）约束，
    // 与 Epoch / MarketRule 的配置窗口是两个尺度：前者按一次 RFQ 的寿命计，
    // 后者按一个费率周期计。CONFIG_WINDOW_UNTIL 承担后者，不受该上限影响。
    uint64 internal constant TRADE_DEADLINE = CREATED_AT + 2_000;
    uint64 internal constant QUOTE_EXPIRES_AT = CREATED_AT + 3_000;
    uint64 internal constant CONFIG_WINDOW_UNTIL = 1_785_000_000;
    uint64 internal constant SETTLEMENT_VALID_UNTIL = 1_790_000_000;

    AdapterRegistry internal adapterRegistry;
    PrincipalCalculatorRegistry internal calculatorRegistry;
    SettlementTokenRegistry internal settlementTokenRegistry;
    AssetVersionRegistry internal assetVersionRegistry;
    EligibilityRegistry internal eligibilityRegistry;
    FeeRegistry internal feeRegistry;
    MarketRuleRegistry internal marketRuleRegistry;
    ParticipantRegistry internal participantRegistry;
    DvPSettlement internal dvp;
    DvPPreCheckToken internal assetToken;
    DvPPreCheckToken internal settlementToken;
    IAssetAdapter internal adapter;
    IPrincipalCalculator internal calculator;
    AdapterConfig internal adapterConfig;
    PrincipalCalculatorConfig internal calculatorConfig;
    SettlementTokenConfig internal settlementTokenConfig;
    AssetVersionConfig internal assetVersionConfig;
    FeeConfig internal feeConfig;
    MarketRuleConfig internal marketRuleConfig;
    CoreDeployment internal coreDeployment;
    address private predictedDvpAddress;

    function setUp() public virtual override {
        super.setUp();
        // Eight implementation/proxy pairs and the Validator Factory are created
        // before the DvP. Pinning the CREATE address lets Eligibility initialize
        // atomically with the real settlement consumer instead of a temporary mock.
        predictedDvpAddress = _predictDvpAddress(address(this), uint64(vm.getNonce(address(this))));
        _deployProductionCore();
        _activateConfigurationGraph();
        _activateParticipantsAndEligibility();
        vm.warp(CREATED_AT);
    }

    function _validPreCheckParams() internal view returns (SettlementParams memory params) {
        params.firmQuote = SchemaFixtures.firmQuote();
        params.tradeIntent = SchemaFixtures.tradeIntent();
        params.snapshot = SchemaFixtures.snapshot();

        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);
        params.firmQuote.quotingMaker = maker;
        params.firmQuote.requester = requester;
        params.firmQuote.assetVersionId = assetVersionConfig.assetVersionId;
        params.firmQuote.assetToken = address(assetToken);
        params.firmQuote.settlementToken = address(settlementToken);
        params.firmQuote.principalCalculatorConfigId = calculatorConfig.calculatorConfigId;
        params.firmQuote.principalCalculatorConfigHash = calculatorConfig.configHash;
        params.firmQuote.adapterConfigId = adapterConfig.adapterConfigId;
        params.firmQuote.adapterConfigHash = adapterConfig.configHash;
        params.firmQuote.settlementTokenConfigId = settlementTokenConfig.configId;
        params.firmQuote.settlementTokenConfigHash = settlementTokenConfig.configHash;
        params.firmQuote.marketRuleConfigId = marketRuleConfig.marketRuleConfigId;
        params.firmQuote.marketRuleConfigHash = marketRuleConfig.configHash;
        params.firmQuote.feePolicyEpoch = FEE_EPOCH;
        params.firmQuote.feeVersionId = feeConfig.feeVersionId;
        params.firmQuote.matchedScopeHash = feeConfig.matchedScopeHash;
        params.firmQuote.feeConstraintHash = feeConfig.feeConstraintHash;
        params.firmQuote.expiresAt = QUOTE_EXPIRES_AT;

        params.snapshot.chainId = block.chainid;
        params.snapshot.dvpContract = address(dvp);
        params.snapshot.requester = requester;
        params.snapshot.quotingMaker = maker;
        params.snapshot.buyer = requester;
        params.snapshot.seller = maker;
        params.snapshot.assetVersionId = assetVersionConfig.assetVersionId;
        params.snapshot.assetToken = address(assetToken);
        params.snapshot.settlementToken = address(settlementToken);
        params.snapshot.principalCalculatorConfigId = calculatorConfig.calculatorConfigId;
        params.snapshot.principalCalculatorConfigHash = calculatorConfig.configHash;
        params.snapshot.adapterConfigId = adapterConfig.adapterConfigId;
        params.snapshot.adapterConfigHash = adapterConfig.configHash;
        params.snapshot.settlementTokenConfigId = settlementTokenConfig.configId;
        params.snapshot.settlementTokenConfigHash = settlementTokenConfig.configHash;
        params.snapshot.marketRuleConfigId = marketRuleConfig.marketRuleConfigId;
        params.snapshot.marketRuleConfigHash = marketRuleConfig.configHash;
        params.snapshot.collector = COLLECTOR;
        params.snapshot.feePolicyEpoch = FEE_EPOCH;
        params.snapshot.feeVersionId = feeConfig.feeVersionId;
        params.snapshot.matchedScopeHash = feeConfig.matchedScopeHash;
        params.snapshot.feeConstraintHash = feeConfig.feeConstraintHash;
        params.snapshot.quoteExpiresAt = QUOTE_EXPIRES_AT;
        params.snapshot.tradeDeadline = TRADE_DEADLINE;
        params.snapshot.createdAt = CREATED_AT;

        params.tradeIntent.tradeIdHash = params.snapshot.tradeIdHash;
        params.tradeIntent.requester = requester;
        params.tradeIntent.quotingMaker = maker;
        params.tradeIntent.buyer = requester;
        params.tradeIntent.seller = maker;
        params.tradeIntent.assetVersionId = assetVersionConfig.assetVersionId;
        params.tradeIntent.assetToken = address(assetToken);
        params.tradeIntent.settlementToken = address(settlementToken);
        params.tradeIntent.principalCalculatorConfigId = calculatorConfig.calculatorConfigId;
        params.tradeIntent.principalCalculatorConfigHash = calculatorConfig.configHash;
        params.tradeIntent.adapterConfigId = adapterConfig.adapterConfigId;
        params.tradeIntent.adapterConfigHash = adapterConfig.configHash;
        params.tradeIntent.settlementTokenConfigId = settlementTokenConfig.configId;
        params.tradeIntent.settlementTokenConfigHash = settlementTokenConfig.configHash;
        params.tradeIntent.marketRuleConfigId = marketRuleConfig.marketRuleConfigId;
        params.tradeIntent.marketRuleConfigHash = marketRuleConfig.configHash;
        params.tradeIntent.collector = COLLECTOR;
        params.tradeIntent.feePolicyEpoch = FEE_EPOCH;
        params.tradeIntent.feeVersionId = feeConfig.feeVersionId;
        params.tradeIntent.matchedScopeHash = feeConfig.matchedScopeHash;
        params.tradeIntent.feeConstraintHash = feeConfig.feeConstraintHash;
        params.tradeIntent.deadline = TRADE_DEADLINE;
        _resign(params);
    }

    function _resign(SettlementParams memory params) internal view {
        bytes32 quoteDigest = HTPHashing.hashFirmQuoteDigest(dvp.domainSeparatorV4(), params.firmQuote);
        params.tradeIntent.quoteHash = quoteDigest;
        params.snapshot.quoteHash = quoteDigest;
        bytes32 snapshotHash = HTPHashing.hashTradeTermsSnapshot(params.snapshot);
        params.tradeIntent.snapshotHash = snapshotHash;
        params.quotingMakerSignature = _sign(MAKER_KEY, quoteDigest);
        params.requesterSignature =
            _sign(REQUESTER_KEY, HTPHashing.hashTradeIntentDigest(dvp.domainSeparatorV4(), params.tradeIntent));
    }

    function _applyFeeAmounts(
        SettlementParams memory params,
        ParticipantType buyerParticipantType,
        ParticipantType sellerParticipantType,
        FeeConfig memory config
    ) internal pure {
        (uint256 buyerFee, uint256 sellerFee, uint256 buyerDebit, uint256 sellerCredit, uint256 collectorCredit) =
            FeeMath.calculate(params.snapshot.cashPrincipal, buyerParticipantType, sellerParticipantType, config);
        params.tradeIntent.buyerFee = buyerFee;
        params.snapshot.buyerFee = buyerFee;
        params.tradeIntent.sellerFee = sellerFee;
        params.snapshot.sellerFee = sellerFee;
        params.tradeIntent.buyerDebit = buyerDebit;
        params.snapshot.buyerDebit = buyerDebit;
        params.tradeIntent.sellerCredit = sellerCredit;
        params.snapshot.sellerCredit = sellerCredit;
        params.tradeIntent.collectorCredit = collectorCredit;
        params.snapshot.collectorCredit = collectorCredit;
    }

    function _zeroCollectorParams() internal returns (SettlementParams memory params) {
        return _alternateFeeParams(0, 0);
    }

    function _zeroSellerParams() internal returns (SettlementParams memory params) {
        return _alternateFeeParams(0, 10_000);
    }

    function _alternateFeeParams(uint16 investorRateBps, uint16 makerRateBps)
        private
        returns (SettlementParams memory params)
    {
        uint64 epochNumber = 2;
        uint64 validFrom = CREATED_AT + 1;
        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: epochNumber,
            chainId: block.chainid,
            quoteValidFrom: validFrom,
            quoteValidUntil: CONFIG_WINDOW_UNTIL,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);

        bytes32 matchedScopeHash =
            FeeScope.matchedHash(epochNumber, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId);
        FeeConfig memory alternateFee = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: epochNumber,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionConfig.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: investorRateBps,
            investorHasCap: false,
            investorCapAmount: 0,
            makerRateBps: makerRateBps,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: validFrom,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        alternateFee.feeConstraintHash = HTPHashing.hashFeeConstraint(alternateFee);
        alternateFee.configHash = HTPHashing.hashFeeConfig(alternateFee);
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(alternateFee);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(epochNumber, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(alternateFee.feeVersionId, alternateFee.configHash);
        vm.warp(validFrom);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(epochNumber, epoch.configHash, alternateFee.feeVersionId);

        params = _validPreCheckParams();
        params.firmQuote.feePolicyEpoch = epochNumber;
        params.tradeIntent.feePolicyEpoch = epochNumber;
        params.snapshot.feePolicyEpoch = epochNumber;
        params.firmQuote.feeVersionId = alternateFee.feeVersionId;
        params.tradeIntent.feeVersionId = alternateFee.feeVersionId;
        params.snapshot.feeVersionId = alternateFee.feeVersionId;
        params.firmQuote.matchedScopeHash = alternateFee.matchedScopeHash;
        params.tradeIntent.matchedScopeHash = alternateFee.matchedScopeHash;
        params.snapshot.matchedScopeHash = alternateFee.matchedScopeHash;
        params.firmQuote.feeConstraintHash = alternateFee.feeConstraintHash;
        params.tradeIntent.feeConstraintHash = alternateFee.feeConstraintHash;
        params.snapshot.feeConstraintHash = alternateFee.feeConstraintHash;
        uint256 buyerFee = params.snapshot.cashPrincipal * investorRateBps / 10_000;
        uint256 sellerFee = params.snapshot.cashPrincipal * makerRateBps / 10_000;
        uint256 buyerDebit = params.snapshot.cashPrincipal + buyerFee;
        uint256 sellerCredit = params.snapshot.cashPrincipal - sellerFee;
        uint256 collectorCredit = buyerFee + sellerFee;
        params.tradeIntent.buyerFee = buyerFee;
        params.snapshot.buyerFee = buyerFee;
        params.tradeIntent.sellerFee = sellerFee;
        params.snapshot.sellerFee = sellerFee;
        params.tradeIntent.buyerDebit = buyerDebit;
        params.snapshot.buyerDebit = buyerDebit;
        params.tradeIntent.sellerCredit = sellerCredit;
        params.snapshot.sellerCredit = sellerCredit;
        params.tradeIntent.collectorCredit = collectorCredit;
        params.snapshot.collectorCredit = collectorCredit;
        params.snapshot.createdAt = validFrom;
        _resign(params);
    }

    function _deployProductionCore() private {
        DeploymentRoles memory roles = _productionRoles();
        DeploymentConfig memory config =
            DeploymentConfig({roles: roles, deploymentVersion: bytes("1.2.3"), chainId: block.chainid});
        coreDeployment = _deployCoreTopology(config, predictedDvpAddress);
        adapterRegistry = AdapterRegistry(coreDeployment.adapterRegistry.proxy);
        calculatorRegistry = PrincipalCalculatorRegistry(coreDeployment.calculatorRegistry.proxy);
        settlementTokenRegistry = SettlementTokenRegistry(coreDeployment.settlementTokenRegistry.proxy);
        assetVersionRegistry = AssetVersionRegistry(coreDeployment.assetVersionRegistry.proxy);
        eligibilityRegistry = EligibilityRegistry(coreDeployment.eligibilityRegistry.proxy);
        feeRegistry = FeeRegistry(coreDeployment.feeRegistry.proxy);
        marketRuleRegistry = MarketRuleRegistry(coreDeployment.marketRuleRegistry.proxy);
        participantRegistry = ParticipantRegistry(coreDeployment.participantRegistry.proxy);
        dvp = DvPSettlement(coreDeployment.dvp);
        assertEq(address(dvp), predictedDvpAddress);
        vm.prank(address(timelock));
        dvp.grantRole(Roles.PAUSER_ROLE, DVP_PAUSER);
        _registerDependentDvps();
    }

    function _registerDependentDvps() private {
        DirectOperation[] memory operations =
            new DeploymentOperationBuilder().dependentDvpRegistration(coreDeployment, EVIDENCE_HASH);
        vm.startPrank(address(timelock));
        for (uint256 i; i < operations.length; ++i) {
            (bool success,) = operations[i].target.call(operations[i].data);
            require(success, "DEPENDENT_DVP");
        }
        vm.stopPrank();
    }

    function _productionRoles() private view returns (DeploymentRoles memory roles) {
        roles = DeploymentRoles({
            defaultAdmin: address(timelock),
            governance: address(timelock),
            upgrader: address(timelock),
            pauser: REGISTRY_PAUSER,
            executor: EXECUTOR,
            configurer: CONFIGURER
        });
    }

    function _activateConfigurationGraph() private {
        adapter = IAssetAdapter(address(new UnrestrictedERC20Adapter(address(dvp))));
        calculator = IPrincipalCalculator(address(new FundPrincipalCalculator()));
        assetToken = new DvPPreCheckToken(18);
        settlementToken = new DvPPreCheckToken(6);

        adapterConfig = _adapterConfig();
        vm.prank(CONFIGURER);
        adapterRegistry.registerAdapter(adapterConfig);
        vm.prank(address(timelock));
        adapterRegistry.activateAdapter(adapterConfig.adapterConfigId, adapterConfig.configHash);

        calculatorConfig = _calculatorConfig();
        vm.prank(CONFIGURER);
        calculatorRegistry.registerPrincipalCalculator(calculatorConfig);
        vm.prank(address(timelock));
        calculatorRegistry.activatePrincipalCalculator(calculatorConfig.calculatorConfigId, calculatorConfig.configHash);

        settlementTokenConfig = _settlementTokenConfig();
        vm.prank(CONFIGURER);
        settlementTokenRegistry.registerSettlementToken(settlementTokenConfig);
        vm.prank(address(timelock));
        settlementTokenRegistry.activateSettlementToken(
            settlementTokenConfig.configId, settlementTokenConfig.configHash
        );

        assetVersionConfig = _assetVersionConfig();
        vm.prank(CONFIGURER);
        assetVersionRegistry.registerAssetVersion(assetVersionConfig);
        vm.prank(address(timelock));
        assetVersionRegistry.activateAssetVersion(assetVersionConfig.assetVersionId, assetVersionConfig.configHash);

        marketRuleConfig = _marketRuleConfig();
        vm.prank(CONFIGURER);
        marketRuleRegistry.registerMarketRule(marketRuleConfig);
        vm.prank(address(timelock));
        marketRuleRegistry.sealMarketRule(marketRuleConfig.marketRuleConfigId, marketRuleConfig.configHash);
        vm.warp(QUOTE_VALID_FROM);
        vm.prank(address(timelock));
        marketRuleRegistry.activateMarketRule(marketRuleConfig.marketRuleConfigId, marketRuleConfig.configHash);

        FeePolicyEpochConfig memory epoch = FeePolicyEpochConfig({
            schemaVersion: 1,
            feePolicyEpoch: FEE_EPOCH,
            chainId: block.chainid,
            quoteValidFrom: QUOTE_VALID_FROM,
            quoteValidUntil: CONFIG_WINDOW_UNTIL,
            settlementValidUntil: SETTLEMENT_VALID_UNTIL,
            configHash: bytes32(0)
        });
        epoch.configHash = HTPHashing.hashFeePolicyEpochConfig(epoch);
        vm.prank(address(timelock));
        feeRegistry.createFeePolicyEpoch(epoch);
        feeConfig = _feeConfig();
        vm.prank(CONFIGURER);
        feeRegistry.registerFeeVersion(feeConfig);
        vm.prank(address(timelock));
        feeRegistry.sealFeePolicyEpoch(FEE_EPOCH, epoch.configHash);
        vm.prank(address(timelock));
        feeRegistry.activateFeeVersion(feeConfig.feeVersionId, feeConfig.configHash);
        vm.warp(QUOTE_VALID_FROM);
        vm.prank(address(timelock));
        feeRegistry.activateFeePolicyEpoch(FEE_EPOCH, epoch.configHash, feeConfig.feeVersionId);
    }

    function _activateParticipantsAndEligibility() private {
        address maker = vm.addr(MAKER_KEY);
        address requester = vm.addr(REQUESTER_KEY);
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: maker,
                participantIdHash: bytes32(uint256(0xA001)),
                participantType: ParticipantType.MAKER,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
        vm.prank(CONFIGURER);
        participantRegistry.setParticipant(
            ParticipantInput({
                wallet: requester,
                participantIdHash: bytes32(uint256(0xA002)),
                participantType: ParticipantType.INVESTOR,
                validUntil: SETTLEMENT_VALID_UNTIL,
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );

        _setEligibility(maker);
        _setEligibility(requester);

        assetToken.setAllowance(maker, address(dvp), 10 ether);
        settlementToken.setAllowance(requester, address(dvp), 11_428_500);
        assetToken.setBalance(maker, 100 ether);
        settlementToken.setBalance(requester, 100_000_000);
    }

    function _setEligibility(address wallet) internal {
        vm.prank(CONFIGURER);
        eligibilityRegistry.setEligibility(
            EligibilityInput({
                wallet: wallet,
                assetVersionId: assetVersionConfig.assetVersionId,
                decision: Decision.PASS,
                validFrom: QUOTE_VALID_FROM,
                validUntil: SETTLEMENT_VALID_UNTIL,
                kycDecisionVersion: bytes32(uint256(0xD100)),
                permissionVersion: bytes32(uint256(0xD101)),
                evidenceHash: EVIDENCE_HASH
            }),
            0
        );
    }

    function _adapterConfig() private view returns (AdapterConfig memory config) {
        AdapterCapabilities memory capabilities = adapter.capabilities();
        bytes32 capabilityHash = HTPHashing.hashAdapterCapabilities(capabilities);
        config = AdapterConfig({
            schemaVersion: 1,
            adapterConfigId: ConfigId.derive(ConfigId.ADAPTER_NAMESPACE, 1, block.chainid, capabilityHash, 1),
            revision: 1,
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

    function _calculatorConfig() private view returns (PrincipalCalculatorConfig memory config) {
        config = PrincipalCalculatorConfig({
            schemaVersion: 1,
            calculatorConfigId: ConfigId.derive(
                ConfigId.PRINCIPAL_CALCULATOR_NAMESPACE, 1, block.chainid, bytes32(uint256(AssetClass.FUND)), 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetClass: AssetClass.FUND,
            calculator: address(calculator),
            interfaceVersion: InterfaceVersions.PRINCIPAL_CALCULATOR_V1,
            codeHash: address(calculator).codehash,
            replacesId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashPrincipalCalculatorConfig(config);
    }

    function _settlementTokenConfig() private view returns (SettlementTokenConfig memory config) {
        config = SettlementTokenConfig({
            schemaVersion: 1,
            configId: ConfigId.derive(
                ConfigId.SETTLEMENT_TOKEN_NAMESPACE,
                1,
                block.chainid,
                bytes32(uint256(uint160(address(settlementToken)))),
                1
            ),
            revision: 1,
            chainId: block.chainid,
            settlementToken: address(settlementToken),
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            settlementTokenDecimals: 6,
            tokenCodeHash: address(settlementToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            permitCapability: PermitCapability.EIP2612,
            replacesConfigId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashSettlementTokenConfig(config);
    }

    function _assetVersionConfig() private view returns (AssetVersionConfig memory config) {
        config = AssetVersionConfig({
            schemaVersion: 1,
            economicAssetIdHash: ECONOMIC_ASSET_ID_HASH,
            assetVersionId: ConfigId.assetVersion(1, ECONOMIC_ASSET_ID_HASH, block.chainid, address(assetToken), 1),
            chainId: block.chainid,
            versionNo: 1,
            assetToken: address(assetToken),
            tokenStandard: TokenStandard.ERC20,
            tokenDeploymentKind: TokenDeploymentKind.DIRECT,
            assetDecimals: 18,
            tokenCodeHash: address(assetToken).codehash,
            implementation: address(0),
            implementationCodeHash: bytes32(0),
            assetPermitCapability: PermitCapability.EIP2612,
            assetClass: AssetClass.FUND,
            principalCalculatorConfigId: calculatorConfig.calculatorConfigId,
            principalCalculatorConfigHash: calculatorConfig.configHash,
            adapterConfigId: adapterConfig.adapterConfigId,
            adapterConfigHash: adapterConfig.configHash,
            restrictionMode: RestrictionMode.UNRESTRICTED,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            dvpContract: address(dvp),
            deploymentVersionHash: DEPLOYMENT_VERSION_HASH,
            replacesAssetVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.configHash = HTPHashing.hashAssetVersionConfig(config);
    }

    function _feeConfig() private view returns (FeeConfig memory config) {
        bytes32 matchedScopeHash =
            FeeScope.matchedHash(FEE_EPOCH, ScopeType.ASSET_VERSION, assetVersionConfig.assetVersionId);
        config = FeeConfig({
            schemaVersion: 1,
            feeVersionId: ConfigId.derive(ConfigId.FEE_NAMESPACE, 1, block.chainid, matchedScopeHash, 1),
            revision: 1,
            chainId: block.chainid,
            feePolicyEpoch: FEE_EPOCH,
            scopeType: ScopeType.ASSET_VERSION,
            scopeKeyHash: assetVersionConfig.assetVersionId,
            matchedScopeHash: matchedScopeHash,
            investorRateBps: 25,
            investorHasCap: true,
            investorCapAmount: 50_000,
            makerRateBps: 15,
            makerHasCap: false,
            makerCapAmount: 0,
            roundingMode: RoundingMode.DOWN,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            collector: COLLECTOR,
            validFrom: QUOTE_VALID_FROM,
            validUntil: SETTLEMENT_VALID_UNTIL,
            feeConstraintHash: bytes32(0),
            replacesFeeVersionId: bytes32(0),
            configHash: bytes32(0)
        });
        config.feeConstraintHash = HTPHashing.hashFeeConstraint(config);
        config.configHash = HTPHashing.hashFeeConfig(config);
    }

    function _marketRuleConfig() private view returns (MarketRuleConfig memory config) {
        config = MarketRuleConfig({
            schemaVersion: 1,
            marketRuleConfigId: ConfigId.derive(
                ConfigId.MARKET_RULE_NAMESPACE, 1, block.chainid, assetVersionConfig.assetVersionId, 1
            ),
            revision: 1,
            chainId: block.chainid,
            assetVersionId: assetVersionConfig.assetVersionId,
            settlementToken: address(settlementToken),
            settlementTokenConfigId: settlementTokenConfig.configId,
            settlementTokenConfigHash: settlementTokenConfig.configHash,
            minCashPrincipal: 1,
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
        config.configHash = HTPHashing.hashMarketRuleConfig(config);
    }

    function _sign(uint256 privateKey, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
