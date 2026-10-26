// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// GENERATED FILE — DO NOT EDIT.
// generatedFrom schema-tools SchemaModel ABI layout
// typesSource derived from contracts/src/types/HTPTypes.sol AST
// solc 0.8.36

import {
    AdapterStatus,
    AssetClass,
    AssetVersionStatus,
    CalculatorStatus,
    Decision,
    FeePolicyEpochStatus,
    FeeVersionStatus,
    MarketRuleStatus,
    NonceType,
    ParticipantStatus,
    ParticipantType,
    PermitCapability,
    PrecheckMethod,
    RequesterSide,
    RestrictionMode,
    RoundingMode,
    ScopeType,
    SettlementTokenStatus,
    TokenDeploymentKind,
    TokenStandard,
    AdapterCapabilities,
    AdapterConfig,
    AdapterRecord,
    AssetVersionConfig,
    AssetVersionRecord,
    BondPriceTerms,
    EligibilityInput,
    EligibilityRecord,
    FeeConfig,
    FeePolicyEpochConfig,
    FeePolicyEpochRecord,
    FeeVersionRecord,
    FirmQuote,
    FundPriceTerms,
    MarketRuleConfig,
    MarketRuleRecord,
    NonceCancellation,
    ParticipantInput,
    ParticipantRecord,
    PermitData,
    PrincipalCalculatorConfig,
    PrincipalCalculatorRecord,
    RestrictionProvider,
    RestrictionProviderSet,
    SettlementParams,
    SettlementTokenConfig,
    SettlementTokenRecord,
    StockPriceTerms,
    TradeIntent,
    TradeTermsSnapshot
} from "src/types/HTPTypes.sol";
import {AbiAssertions} from "test/helpers/AbiAssertions.sol";

contract SchemaLayoutTest is AbiAssertions {
    function testLayout_AdapterCapabilities() public pure {
        AdapterCapabilities memory value;
        value.tokenStandard = TokenStandard.ERC1404;
        value.restrictionMode = RestrictionMode.ISSUER_EXTERNAL;
        value.precheckMethod = PrecheckMethod.NO_PRECHECK;
        value.transferLegMask = 4;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 128);
        assertEq(_word(encoded, 0 + 0), 2);
        assertEq(_word(encoded, 0 + 32), 3);
        assertEq(_word(encoded, 0 + 64), 1);
        assertEq(_word(encoded, 0 + 96), 4);
    }

    function testLayout_AdapterConfig() public pure {
        AdapterConfig memory value;
        value.schemaVersion = 1;
        value.adapterConfigId = bytes32(uint256(2));
        value.revision = 3;
        value.chainId = 4;
        value.adapter = address(uint160(5));
        value.interfaceVersion = bytes32(uint256(6));
        value.codeHash = bytes32(uint256(7));
        value.capabilities.tokenStandard = TokenStandard.ERC20;
        value.capabilities.restrictionMode = RestrictionMode.PLATFORM;
        value.capabilities.precheckMethod = PrecheckMethod.ERC1404_CHECK;
        value.capabilities.transferLegMask = 11;
        value.capabilityHash = bytes32(uint256(12));
        value.providerHash = bytes32(uint256(13));
        value.replacesId = bytes32(uint256(14));
        value.configHash = bytes32(uint256(15));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 480);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 1);
        assertEq(_word(encoded, 0 + 256), 2);
        assertEq(_word(encoded, 0 + 288), 2);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 13);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
    }

    function testLayout_AdapterRecord() public pure {
        AdapterRecord memory value;
        value.config.schemaVersion = 1;
        value.config.adapterConfigId = bytes32(uint256(2));
        value.config.revision = 3;
        value.config.chainId = 4;
        value.config.adapter = address(uint160(5));
        value.config.interfaceVersion = bytes32(uint256(6));
        value.config.codeHash = bytes32(uint256(7));
        value.config.capabilities.tokenStandard = TokenStandard.ERC20;
        value.config.capabilities.restrictionMode = RestrictionMode.PLATFORM;
        value.config.capabilities.precheckMethod = PrecheckMethod.ERC1404_CHECK;
        value.config.capabilities.transferLegMask = 11;
        value.config.capabilityHash = bytes32(uint256(12));
        value.config.providerHash = bytes32(uint256(13));
        value.config.replacesId = bytes32(uint256(14));
        value.config.configHash = bytes32(uint256(15));
        value.status = AdapterStatus.REGISTERED;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 544);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 1);
        assertEq(_word(encoded, 0 + 256), 2);
        assertEq(_word(encoded, 0 + 288), 2);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 13);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 1);
        assertEq(_word(encoded, 0 + 512), 1);
    }

    function testLayout_AssetVersionConfig() public pure {
        AssetVersionConfig memory value;
        value.schemaVersion = 1;
        value.economicAssetIdHash = bytes32(uint256(2));
        value.assetVersionId = bytes32(uint256(3));
        value.chainId = 4;
        value.versionNo = 5;
        value.assetToken = address(uint160(6));
        value.tokenStandard = TokenStandard.ERC1404;
        value.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        value.assetDecimals = 9;
        value.tokenCodeHash = bytes32(uint256(10));
        value.implementation = address(uint160(11));
        value.implementationCodeHash = bytes32(uint256(12));
        value.assetPermitCapability = PermitCapability.EIP2612;
        value.assetClass = AssetClass.BOND;
        value.principalCalculatorConfigId = bytes32(uint256(15));
        value.principalCalculatorConfigHash = bytes32(uint256(16));
        value.adapterConfigId = bytes32(uint256(17));
        value.adapterConfigHash = bytes32(uint256(18));
        value.restrictionMode = RestrictionMode.TOKEN_ENFORCED;
        value.settlementToken = address(uint160(20));
        value.settlementTokenConfigId = bytes32(uint256(21));
        value.settlementTokenConfigHash = bytes32(uint256(22));
        value.dvpContract = address(uint160(23));
        value.deploymentVersionHash = bytes32(uint256(24));
        value.replacesAssetVersionId = bytes32(uint256(25));
        value.configHash = bytes32(uint256(26));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 832);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 2);
        assertEq(_word(encoded, 0 + 224), 1);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 2);
        assertEq(_word(encoded, 0 + 416), 3);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 4);
        assertEq(_word(encoded, 0 + 608), 20);
        assertEq(_word(encoded, 0 + 640), 21);
        assertEq(_word(encoded, 0 + 672), 22);
        assertEq(_word(encoded, 0 + 704), 23);
        assertEq(_word(encoded, 0 + 736), 24);
        assertEq(_word(encoded, 0 + 768), 25);
        assertEq(_word(encoded, 0 + 800), 26);
    }

    function testLayout_AssetVersionRecord() public pure {
        AssetVersionRecord memory value;
        value.config.schemaVersion = 1;
        value.config.economicAssetIdHash = bytes32(uint256(2));
        value.config.assetVersionId = bytes32(uint256(3));
        value.config.chainId = 4;
        value.config.versionNo = 5;
        value.config.assetToken = address(uint160(6));
        value.config.tokenStandard = TokenStandard.ERC1404;
        value.config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        value.config.assetDecimals = 9;
        value.config.tokenCodeHash = bytes32(uint256(10));
        value.config.implementation = address(uint160(11));
        value.config.implementationCodeHash = bytes32(uint256(12));
        value.config.assetPermitCapability = PermitCapability.EIP2612;
        value.config.assetClass = AssetClass.BOND;
        value.config.principalCalculatorConfigId = bytes32(uint256(15));
        value.config.principalCalculatorConfigHash = bytes32(uint256(16));
        value.config.adapterConfigId = bytes32(uint256(17));
        value.config.adapterConfigHash = bytes32(uint256(18));
        value.config.restrictionMode = RestrictionMode.TOKEN_ENFORCED;
        value.config.settlementToken = address(uint160(20));
        value.config.settlementTokenConfigId = bytes32(uint256(21));
        value.config.settlementTokenConfigHash = bytes32(uint256(22));
        value.config.dvpContract = address(uint160(23));
        value.config.deploymentVersionHash = bytes32(uint256(24));
        value.config.replacesAssetVersionId = bytes32(uint256(25));
        value.config.configHash = bytes32(uint256(26));
        value.status = AssetVersionStatus.DEPRECATED;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 896);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 2);
        assertEq(_word(encoded, 0 + 224), 1);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 2);
        assertEq(_word(encoded, 0 + 416), 3);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 4);
        assertEq(_word(encoded, 0 + 608), 20);
        assertEq(_word(encoded, 0 + 640), 21);
        assertEq(_word(encoded, 0 + 672), 22);
        assertEq(_word(encoded, 0 + 704), 23);
        assertEq(_word(encoded, 0 + 736), 24);
        assertEq(_word(encoded, 0 + 768), 25);
        assertEq(_word(encoded, 0 + 800), 26);
        assertEq(_word(encoded, 0 + 832), 4);
        assertEq(_word(encoded, 0 + 864), 1);
    }

    function testLayout_BondPriceTerms() public pure {
        BondPriceTerms memory value;
        value.cleanPricePerUnit = 1;
        value.accruedInterestPerUnit = 2;
        value.settlementDate = 3;
        value.sourceHash = bytes32(uint256(4));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 128);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
    }

    function testLayout_EligibilityInput() public pure {
        EligibilityInput memory value;
        value.wallet = address(uint160(1));
        value.assetVersionId = bytes32(uint256(2));
        value.decision = Decision.PASS;
        value.validFrom = 4;
        value.validUntil = 5;
        value.kycDecisionVersion = bytes32(uint256(6));
        value.permissionVersion = bytes32(uint256(7));
        value.evidenceHash = bytes32(uint256(8));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 256);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 1);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
    }

    function testLayout_EligibilityRecord() public pure {
        EligibilityRecord memory value;
        value.eligibilityKey = bytes32(uint256(1));
        value.wallet = address(uint160(2));
        value.assetVersionId = bytes32(uint256(3));
        value.decision = Decision.BLOCK;
        value.validFrom = 5;
        value.validUntil = 6;
        value.kycDecisionVersion = bytes32(uint256(7));
        value.permissionVersion = bytes32(uint256(8));
        value.recordVersion = 9;
        value.paused = true;
        value.revoked = true;
        value.evidenceHash = bytes32(uint256(12));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 384);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 2);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 1);
        assertEq(_word(encoded, 0 + 320), 1);
        assertEq(_word(encoded, 0 + 352), 12);
    }

    function testLayout_FeeConfig() public pure {
        FeeConfig memory value;
        value.schemaVersion = 1;
        value.feeVersionId = bytes32(uint256(2));
        value.revision = 3;
        value.chainId = 4;
        value.feePolicyEpoch = 5;
        value.scopeType = ScopeType.CHAIN;
        value.scopeKeyHash = bytes32(uint256(7));
        value.matchedScopeHash = bytes32(uint256(8));
        value.investorRateBps = 9;
        value.investorHasCap = true;
        value.investorCapAmount = 11;
        value.makerRateBps = 12;
        value.makerHasCap = true;
        value.makerCapAmount = 14;
        value.roundingMode = RoundingMode.DOWN;
        value.settlementToken = address(uint160(16));
        value.settlementTokenConfigId = bytes32(uint256(17));
        value.settlementTokenConfigHash = bytes32(uint256(18));
        value.collector = address(uint160(19));
        value.validFrom = 20;
        value.validUntil = 21;
        value.feeConstraintHash = bytes32(uint256(22));
        value.replacesFeeVersionId = bytes32(uint256(23));
        value.configHash = bytes32(uint256(24));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 768);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 2);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 1);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 1);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 1);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 19);
        assertEq(_word(encoded, 0 + 608), 20);
        assertEq(_word(encoded, 0 + 640), 21);
        assertEq(_word(encoded, 0 + 672), 22);
        assertEq(_word(encoded, 0 + 704), 23);
        assertEq(_word(encoded, 0 + 736), 24);
    }

    function testLayout_FeePolicyEpochConfig() public pure {
        FeePolicyEpochConfig memory value;
        value.schemaVersion = 1;
        value.feePolicyEpoch = 2;
        value.chainId = 3;
        value.quoteValidFrom = 4;
        value.quoteValidUntil = 5;
        value.settlementValidUntil = 6;
        value.configHash = bytes32(uint256(7));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 224);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
    }

    function testLayout_FeePolicyEpochRecord() public pure {
        FeePolicyEpochRecord memory value;
        value.config.schemaVersion = 1;
        value.config.feePolicyEpoch = 2;
        value.config.chainId = 3;
        value.config.quoteValidFrom = 4;
        value.config.quoteValidUntil = 5;
        value.config.settlementValidUntil = 6;
        value.config.configHash = bytes32(uint256(7));
        value.status = FeePolicyEpochStatus.DRAFT;
        value.isSealed = true;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 320);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 1);
        assertEq(_word(encoded, 0 + 256), 1);
        assertEq(_word(encoded, 0 + 288), 1);
    }

    function testLayout_FeeVersionRecord() public pure {
        FeeVersionRecord memory value;
        value.config.schemaVersion = 1;
        value.config.feeVersionId = bytes32(uint256(2));
        value.config.revision = 3;
        value.config.chainId = 4;
        value.config.feePolicyEpoch = 5;
        value.config.scopeType = ScopeType.CHAIN;
        value.config.scopeKeyHash = bytes32(uint256(7));
        value.config.matchedScopeHash = bytes32(uint256(8));
        value.config.investorRateBps = 9;
        value.config.investorHasCap = true;
        value.config.investorCapAmount = 11;
        value.config.makerRateBps = 12;
        value.config.makerHasCap = true;
        value.config.makerCapAmount = 14;
        value.config.roundingMode = RoundingMode.DOWN;
        value.config.settlementToken = address(uint160(16));
        value.config.settlementTokenConfigId = bytes32(uint256(17));
        value.config.settlementTokenConfigHash = bytes32(uint256(18));
        value.config.collector = address(uint160(19));
        value.config.validFrom = 20;
        value.config.validUntil = 21;
        value.config.feeConstraintHash = bytes32(uint256(22));
        value.config.replacesFeeVersionId = bytes32(uint256(23));
        value.config.configHash = bytes32(uint256(24));
        value.status = FeeVersionStatus.REGISTERED;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 832);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 2);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 1);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 1);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 1);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 19);
        assertEq(_word(encoded, 0 + 608), 20);
        assertEq(_word(encoded, 0 + 640), 21);
        assertEq(_word(encoded, 0 + 672), 22);
        assertEq(_word(encoded, 0 + 704), 23);
        assertEq(_word(encoded, 0 + 736), 24);
        assertEq(_word(encoded, 0 + 768), 1);
        assertEq(_word(encoded, 0 + 800), 1);
    }

    function testLayout_FirmQuote() public pure {
        FirmQuote memory value;
        value.schemaVersion = 1;
        value.rfqIdHash = bytes32(uint256(2));
        value.quoteIdHash = bytes32(uint256(3));
        value.tradeIdHash = bytes32(uint256(4));
        value.quoteVersion = 5;
        value.quotingMaker = address(uint160(6));
        value.requester = address(uint160(7));
        value.requesterType = ParticipantType.INVESTOR;
        value.assetVersionId = bytes32(uint256(9));
        value.requesterSide = RequesterSide.BUY;
        value.assetToken = address(uint160(11));
        value.settlementToken = address(uint160(12));
        value.assetClass = AssetClass.FUND;
        value.priceTermsHash = bytes32(uint256(14));
        value.principalCalculatorConfigId = bytes32(uint256(15));
        value.principalCalculatorConfigHash = bytes32(uint256(16));
        value.adapterConfigId = bytes32(uint256(17));
        value.adapterConfigHash = bytes32(uint256(18));
        value.settlementTokenConfigId = bytes32(uint256(19));
        value.settlementTokenConfigHash = bytes32(uint256(20));
        value.marketRuleConfigId = bytes32(uint256(21));
        value.marketRuleConfigHash = bytes32(uint256(22));
        value.minExecutableQuantity = 23;
        value.maxExecutableQuantity = 24;
        value.stepQuantity = 25;
        value.feePolicyEpoch = 26;
        value.feeVersionId = bytes32(uint256(27));
        value.matchedScopeHash = bytes32(uint256(28));
        value.feeConstraintHash = bytes32(uint256(29));
        value.quoteNonce = 30;
        value.expiresAt = 31;
        bytes memory encoded = abi.encode(value);
        uint256 head = 32;
        assertEq(_word(encoded, 0), 32);
        assertEq(encoded.length, 1088);
        assertEq(_word(encoded, head + 0), 1);
        assertEq(_word(encoded, head + 32), 2);
        assertEq(_word(encoded, head + 64), 3);
        assertEq(_word(encoded, head + 96), 4);
        assertEq(_word(encoded, head + 128), 5);
        assertEq(_word(encoded, head + 160), 6);
        assertEq(_word(encoded, head + 192), 7);
        assertEq(_word(encoded, head + 224), 1);
        assertEq(_word(encoded, head + 256), 9);
        assertEq(_word(encoded, head + 288), 1);
        assertEq(_word(encoded, head + 320), 11);
        assertEq(_word(encoded, head + 352), 12);
        assertEq(_word(encoded, head + 384), 2);
        assertEq(_word(encoded, head + 416), 14);
        assertEq(_word(encoded, head + 448), 1024);
        assertEq(_word(encoded, head + 480), 15);
        assertEq(_word(encoded, head + 512), 16);
        assertEq(_word(encoded, head + 544), 17);
        assertEq(_word(encoded, head + 576), 18);
        assertEq(_word(encoded, head + 608), 19);
        assertEq(_word(encoded, head + 640), 20);
        assertEq(_word(encoded, head + 672), 21);
        assertEq(_word(encoded, head + 704), 22);
        assertEq(_word(encoded, head + 736), 23);
        assertEq(_word(encoded, head + 768), 24);
        assertEq(_word(encoded, head + 800), 25);
        assertEq(_word(encoded, head + 832), 26);
        assertEq(_word(encoded, head + 864), 27);
        assertEq(_word(encoded, head + 896), 28);
        assertEq(_word(encoded, head + 928), 29);
        assertEq(_word(encoded, head + 960), 30);
        assertEq(_word(encoded, head + 992), 31);
    }

    function testLayout_FundPriceTerms() public pure {
        FundPriceTerms memory value;
        value.navPerUnit = 1;
        value.navDate = 2;
        value.navSourceHash = bytes32(uint256(3));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 96);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
    }

    function testLayout_MarketRuleConfig() public pure {
        MarketRuleConfig memory value;
        value.schemaVersion = 1;
        value.marketRuleConfigId = bytes32(uint256(2));
        value.revision = 3;
        value.chainId = 4;
        value.assetVersionId = bytes32(uint256(5));
        value.settlementToken = address(uint160(6));
        value.settlementTokenConfigId = bytes32(uint256(7));
        value.settlementTokenConfigHash = bytes32(uint256(8));
        value.minCashPrincipal = 9;
        value.minExecutableQuantity = 10;
        value.quantityStep = 11;
        value.priceTick = 12;
        value.priceDecimals = 13;
        value.quantityDecimals = 14;
        value.quoteValidFrom = 15;
        value.quoteValidUntil = 16;
        value.settlementValidUntil = 17;
        value.replacesConfigId = bytes32(uint256(18));
        value.configHash = bytes32(uint256(19));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 608);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 13);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 19);
    }

    function testLayout_MarketRuleRecord() public pure {
        MarketRuleRecord memory value;
        value.config.schemaVersion = 1;
        value.config.marketRuleConfigId = bytes32(uint256(2));
        value.config.revision = 3;
        value.config.chainId = 4;
        value.config.assetVersionId = bytes32(uint256(5));
        value.config.settlementToken = address(uint160(6));
        value.config.settlementTokenConfigId = bytes32(uint256(7));
        value.config.settlementTokenConfigHash = bytes32(uint256(8));
        value.config.minCashPrincipal = 9;
        value.config.minExecutableQuantity = 10;
        value.config.quantityStep = 11;
        value.config.priceTick = 12;
        value.config.priceDecimals = 13;
        value.config.quantityDecimals = 14;
        value.config.quoteValidFrom = 15;
        value.config.quoteValidUntil = 16;
        value.config.settlementValidUntil = 17;
        value.config.replacesConfigId = bytes32(uint256(18));
        value.config.configHash = bytes32(uint256(19));
        value.status = MarketRuleStatus.DRAFT;
        value.isSealed = true;
        value.paused = true;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 736);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 13);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 16);
        assertEq(_word(encoded, 0 + 512), 17);
        assertEq(_word(encoded, 0 + 544), 18);
        assertEq(_word(encoded, 0 + 576), 19);
        assertEq(_word(encoded, 0 + 608), 1);
        assertEq(_word(encoded, 0 + 640), 1);
        assertEq(_word(encoded, 0 + 672), 1);
        assertEq(_word(encoded, 0 + 704), 1);
    }

    function testLayout_NonceCancellation() public pure {
        NonceCancellation memory value;
        value.signer = address(uint160(1));
        value.nonceType = NonceType.MAKER_QUOTE;
        value.nonce = 3;
        value.deadline = 4;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 128);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 1);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
    }

    function testLayout_ParticipantInput() public pure {
        ParticipantInput memory value;
        value.wallet = address(uint160(1));
        value.participantIdHash = bytes32(uint256(2));
        value.participantType = ParticipantType.MAKER;
        value.validUntil = 4;
        value.evidenceHash = bytes32(uint256(5));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 160);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 2);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
    }

    function testLayout_ParticipantRecord() public pure {
        ParticipantRecord memory value;
        value.wallet = address(uint160(1));
        value.participantIdHash = bytes32(uint256(2));
        value.participantType = ParticipantType.MAKER;
        value.status = ParticipantStatus.PAUSED;
        value.validUntil = 5;
        value.version = 6;
        value.evidenceHash = bytes32(uint256(7));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 224);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 2);
        assertEq(_word(encoded, 0 + 96), 2);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
    }

    function testLayout_PermitData() public pure {
        PermitData memory value;
        value.usePermit = true;
        value.owner = address(uint160(2));
        value.token = address(uint160(3));
        value.value = 4;
        value.deadline = 5;
        value.v = 6;
        value.r = bytes32(uint256(7));
        value.s = bytes32(uint256(8));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 256);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
    }

    function testLayout_PrincipalCalculatorConfig() public pure {
        PrincipalCalculatorConfig memory value;
        value.schemaVersion = 1;
        value.calculatorConfigId = bytes32(uint256(2));
        value.revision = 3;
        value.chainId = 4;
        value.assetClass = AssetClass.BOND;
        value.calculator = address(uint160(6));
        value.interfaceVersion = bytes32(uint256(7));
        value.codeHash = bytes32(uint256(8));
        value.replacesId = bytes32(uint256(9));
        value.configHash = bytes32(uint256(10));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 320);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 3);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
    }

    function testLayout_PrincipalCalculatorRecord() public pure {
        PrincipalCalculatorRecord memory value;
        value.config.schemaVersion = 1;
        value.config.calculatorConfigId = bytes32(uint256(2));
        value.config.revision = 3;
        value.config.chainId = 4;
        value.config.assetClass = AssetClass.BOND;
        value.config.calculator = address(uint160(6));
        value.config.interfaceVersion = bytes32(uint256(7));
        value.config.codeHash = bytes32(uint256(8));
        value.config.replacesId = bytes32(uint256(9));
        value.config.configHash = bytes32(uint256(10));
        value.status = CalculatorStatus.DEPRECATED;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 384);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 3);
        assertEq(_word(encoded, 0 + 160), 6);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 4);
        assertEq(_word(encoded, 0 + 352), 1);
    }

    function testLayout_RestrictionProvider() public pure {
        RestrictionProvider memory value;
        value.provider = address(uint160(1));
        value.selector = bytes4(uint32(2));
        value.codeHash = bytes32(uint256(3));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 96);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), uint256(bytes32(bytes4(uint32(2)))));
        assertEq(_word(encoded, 0 + 64), 3);
    }

    function testLayout_RestrictionProviderSet() public pure {
        RestrictionProviderSet memory value;

        bytes memory encoded = abi.encode(value);
        uint256 head = 32;
        assertEq(_word(encoded, 0), 32);
        assertEq(encoded.length, 96);
        assertEq(_word(encoded, head + 0), 32);
    }

    function testLayout_SettlementParams() public pure {
        SettlementParams memory value;
        value.assetPermit.usePermit = true;
        value.assetPermit.owner = address(uint160(2));
        value.assetPermit.token = address(uint160(3));
        value.assetPermit.value = 4;
        value.assetPermit.deadline = 5;
        value.assetPermit.v = 6;
        value.assetPermit.r = bytes32(uint256(7));
        value.assetPermit.s = bytes32(uint256(8));
        value.settlementPermit.usePermit = true;
        value.settlementPermit.owner = address(uint160(10));
        value.settlementPermit.token = address(uint160(11));
        value.settlementPermit.value = 12;
        value.settlementPermit.deadline = 13;
        value.settlementPermit.v = 14;
        value.settlementPermit.r = bytes32(uint256(15));
        value.settlementPermit.s = bytes32(uint256(16));
        bytes memory encoded = abi.encode(value);
        uint256 head = 32;
        assertEq(_word(encoded, 0), 32);
        assertEq(encoded.length, 4576);
        assertEq(_word(encoded, head + 0), 672);
        assertEq(_word(encoded, head + 32), 1728);
        assertEq(_word(encoded, head + 64), 3008);
        assertEq(_word(encoded, head + 96), 4480);
        assertEq(_word(encoded, head + 128), 4512);
        assertEq(_word(encoded, head + 160), 1);
        assertEq(_word(encoded, head + 192), 2);
        assertEq(_word(encoded, head + 224), 3);
        assertEq(_word(encoded, head + 256), 4);
        assertEq(_word(encoded, head + 288), 5);
        assertEq(_word(encoded, head + 320), 6);
        assertEq(_word(encoded, head + 352), 7);
        assertEq(_word(encoded, head + 384), 8);
        assertEq(_word(encoded, head + 416), 1);
        assertEq(_word(encoded, head + 448), 10);
        assertEq(_word(encoded, head + 480), 11);
        assertEq(_word(encoded, head + 512), 12);
        assertEq(_word(encoded, head + 544), 13);
        assertEq(_word(encoded, head + 576), 14);
        assertEq(_word(encoded, head + 608), 15);
        assertEq(_word(encoded, head + 640), 16);
    }

    function testLayout_SettlementTokenConfig() public pure {
        SettlementTokenConfig memory value;
        value.schemaVersion = 1;
        value.configId = bytes32(uint256(2));
        value.revision = 3;
        value.chainId = 4;
        value.settlementToken = address(uint160(5));
        value.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        value.settlementTokenDecimals = 7;
        value.tokenCodeHash = bytes32(uint256(8));
        value.implementation = address(uint160(9));
        value.implementationCodeHash = bytes32(uint256(10));
        value.adapterConfigId = bytes32(uint256(11));
        value.adapterConfigHash = bytes32(uint256(12));
        value.permitCapability = PermitCapability.EIP2612;
        value.replacesConfigId = bytes32(uint256(14));
        value.configHash = bytes32(uint256(15));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 480);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 1);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 2);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
    }

    function testLayout_SettlementTokenRecord() public pure {
        SettlementTokenRecord memory value;
        value.config.schemaVersion = 1;
        value.config.configId = bytes32(uint256(2));
        value.config.revision = 3;
        value.config.chainId = 4;
        value.config.settlementToken = address(uint160(5));
        value.config.tokenDeploymentKind = TokenDeploymentKind.DIRECT;
        value.config.settlementTokenDecimals = 7;
        value.config.tokenCodeHash = bytes32(uint256(8));
        value.config.implementation = address(uint160(9));
        value.config.implementationCodeHash = bytes32(uint256(10));
        value.config.adapterConfigId = bytes32(uint256(11));
        value.config.adapterConfigHash = bytes32(uint256(12));
        value.config.permitCapability = PermitCapability.EIP2612;
        value.config.replacesConfigId = bytes32(uint256(14));
        value.config.configHash = bytes32(uint256(15));
        value.status = SettlementTokenStatus.REGISTERED;
        value.exists = true;
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 544);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
        assertEq(_word(encoded, 0 + 128), 5);
        assertEq(_word(encoded, 0 + 160), 1);
        assertEq(_word(encoded, 0 + 192), 7);
        assertEq(_word(encoded, 0 + 224), 8);
        assertEq(_word(encoded, 0 + 256), 9);
        assertEq(_word(encoded, 0 + 288), 10);
        assertEq(_word(encoded, 0 + 320), 11);
        assertEq(_word(encoded, 0 + 352), 12);
        assertEq(_word(encoded, 0 + 384), 2);
        assertEq(_word(encoded, 0 + 416), 14);
        assertEq(_word(encoded, 0 + 448), 15);
        assertEq(_word(encoded, 0 + 480), 1);
        assertEq(_word(encoded, 0 + 512), 1);
    }

    function testLayout_StockPriceTerms() public pure {
        StockPriceTerms memory value;
        value.unitPrice = 1;
        value.priceAsOf = 2;
        value.referenceMarketHash = bytes32(uint256(3));
        value.priceSourceHash = bytes32(uint256(4));
        bytes memory encoded = abi.encode(value);
        assertEq(encoded.length, 128);
        assertEq(_word(encoded, 0 + 0), 1);
        assertEq(_word(encoded, 0 + 32), 2);
        assertEq(_word(encoded, 0 + 64), 3);
        assertEq(_word(encoded, 0 + 96), 4);
    }

    function testLayout_TradeIntent() public pure {
        TradeIntent memory value;
        value.schemaVersion = 1;
        value.tradeIdHash = bytes32(uint256(2));
        value.quoteHash = bytes32(uint256(3));
        value.snapshotHash = bytes32(uint256(4));
        value.requester = address(uint160(5));
        value.requesterType = ParticipantType.INVESTOR;
        value.quotingMaker = address(uint160(7));
        value.assetVersionId = bytes32(uint256(8));
        value.requesterSide = RequesterSide.SELL;
        value.buyer = address(uint160(10));
        value.seller = address(uint160(11));
        value.assetToken = address(uint160(12));
        value.settlementToken = address(uint160(13));
        value.executedQuantity = 14;
        value.assetClass = AssetClass.STOCK;
        value.priceTermsHash = bytes32(uint256(16));
        value.principalCalculatorConfigId = bytes32(uint256(17));
        value.principalCalculatorConfigHash = bytes32(uint256(18));
        value.adapterConfigId = bytes32(uint256(19));
        value.adapterConfigHash = bytes32(uint256(20));
        value.settlementTokenConfigId = bytes32(uint256(21));
        value.settlementTokenConfigHash = bytes32(uint256(22));
        value.marketRuleConfigId = bytes32(uint256(23));
        value.marketRuleConfigHash = bytes32(uint256(24));
        value.cashPrincipal = 25;
        value.buyerFee = 26;
        value.sellerFee = 27;
        value.buyerDebit = 28;
        value.sellerCredit = 29;
        value.collectorCredit = 30;
        value.collector = address(uint160(31));
        value.feePolicyEpoch = 32;
        value.feeVersionId = bytes32(uint256(33));
        value.matchedScopeHash = bytes32(uint256(34));
        value.feeConstraintHash = bytes32(uint256(35));
        value.roundingMode = RoundingMode.DOWN;
        value.tradeNonce = 37;
        value.deadline = 38;
        bytes memory encoded = abi.encode(value);
        uint256 head = 32;
        assertEq(_word(encoded, 0), 32);
        assertEq(encoded.length, 1312);
        assertEq(_word(encoded, head + 0), 1);
        assertEq(_word(encoded, head + 32), 2);
        assertEq(_word(encoded, head + 64), 3);
        assertEq(_word(encoded, head + 96), 4);
        assertEq(_word(encoded, head + 128), 5);
        assertEq(_word(encoded, head + 160), 1);
        assertEq(_word(encoded, head + 192), 7);
        assertEq(_word(encoded, head + 224), 8);
        assertEq(_word(encoded, head + 256), 2);
        assertEq(_word(encoded, head + 288), 10);
        assertEq(_word(encoded, head + 320), 11);
        assertEq(_word(encoded, head + 352), 12);
        assertEq(_word(encoded, head + 384), 13);
        assertEq(_word(encoded, head + 416), 14);
        assertEq(_word(encoded, head + 448), 1);
        assertEq(_word(encoded, head + 480), 16);
        assertEq(_word(encoded, head + 512), 1248);
        assertEq(_word(encoded, head + 544), 17);
        assertEq(_word(encoded, head + 576), 18);
        assertEq(_word(encoded, head + 608), 19);
        assertEq(_word(encoded, head + 640), 20);
        assertEq(_word(encoded, head + 672), 21);
        assertEq(_word(encoded, head + 704), 22);
        assertEq(_word(encoded, head + 736), 23);
        assertEq(_word(encoded, head + 768), 24);
        assertEq(_word(encoded, head + 800), 25);
        assertEq(_word(encoded, head + 832), 26);
        assertEq(_word(encoded, head + 864), 27);
        assertEq(_word(encoded, head + 896), 28);
        assertEq(_word(encoded, head + 928), 29);
        assertEq(_word(encoded, head + 960), 30);
        assertEq(_word(encoded, head + 992), 31);
        assertEq(_word(encoded, head + 1024), 32);
        assertEq(_word(encoded, head + 1056), 33);
        assertEq(_word(encoded, head + 1088), 34);
        assertEq(_word(encoded, head + 1120), 35);
        assertEq(_word(encoded, head + 1152), 1);
        assertEq(_word(encoded, head + 1184), 37);
        assertEq(_word(encoded, head + 1216), 38);
    }

    function testLayout_TradeTermsSnapshot() public pure {
        TradeTermsSnapshot memory value;
        value.schemaVersion = 1;
        value.tradeIdHash = bytes32(uint256(2));
        value.quoteHash = bytes32(uint256(3));
        value.chainId = 4;
        value.dvpContract = address(uint160(5));
        value.requester = address(uint160(6));
        value.requesterType = ParticipantType.MAKER;
        value.quotingMaker = address(uint160(8));
        value.requesterSide = RequesterSide.SELL;
        value.buyer = address(uint160(10));
        value.seller = address(uint160(11));
        value.assetVersionId = bytes32(uint256(12));
        value.assetToken = address(uint160(13));
        value.settlementToken = address(uint160(14));
        value.assetDecimals = 15;
        value.settlementTokenDecimals = 16;
        value.executedQuantity = 17;
        value.assetClass = AssetClass.STOCK;
        value.priceTermsHash = bytes32(uint256(19));
        value.principalCalculatorConfigId = bytes32(uint256(20));
        value.principalCalculatorConfigHash = bytes32(uint256(21));
        value.adapterConfigId = bytes32(uint256(22));
        value.adapterConfigHash = bytes32(uint256(23));
        value.settlementTokenConfigId = bytes32(uint256(24));
        value.settlementTokenConfigHash = bytes32(uint256(25));
        value.marketRuleConfigId = bytes32(uint256(26));
        value.marketRuleConfigHash = bytes32(uint256(27));
        value.cashPrincipal = 28;
        value.buyerFee = 29;
        value.sellerFee = 30;
        value.buyerDebit = 31;
        value.sellerCredit = 32;
        value.collectorCredit = 33;
        value.collector = address(uint160(34));
        value.feePolicyEpoch = 35;
        value.feeVersionId = bytes32(uint256(36));
        value.matchedScopeHash = bytes32(uint256(37));
        value.feeConstraintHash = bytes32(uint256(38));
        value.roundingMode = RoundingMode.DOWN;
        value.makerQuoteNonce = 40;
        value.requesterTradeNonce = 41;
        value.quoteExpiresAt = 42;
        value.tradeDeadline = 43;
        value.createdAt = 44;
        bytes memory encoded = abi.encode(value);
        uint256 head = 32;
        assertEq(_word(encoded, 0), 32);
        assertEq(encoded.length, 1504);
        assertEq(_word(encoded, head + 0), 1);
        assertEq(_word(encoded, head + 32), 2);
        assertEq(_word(encoded, head + 64), 3);
        assertEq(_word(encoded, head + 96), 4);
        assertEq(_word(encoded, head + 128), 5);
        assertEq(_word(encoded, head + 160), 6);
        assertEq(_word(encoded, head + 192), 2);
        assertEq(_word(encoded, head + 224), 8);
        assertEq(_word(encoded, head + 256), 2);
        assertEq(_word(encoded, head + 288), 10);
        assertEq(_word(encoded, head + 320), 11);
        assertEq(_word(encoded, head + 352), 12);
        assertEq(_word(encoded, head + 384), 13);
        assertEq(_word(encoded, head + 416), 14);
        assertEq(_word(encoded, head + 448), 15);
        assertEq(_word(encoded, head + 480), 16);
        assertEq(_word(encoded, head + 512), 17);
        assertEq(_word(encoded, head + 544), 1);
        assertEq(_word(encoded, head + 576), 19);
        assertEq(_word(encoded, head + 608), 1440);
        assertEq(_word(encoded, head + 640), 20);
        assertEq(_word(encoded, head + 672), 21);
        assertEq(_word(encoded, head + 704), 22);
        assertEq(_word(encoded, head + 736), 23);
        assertEq(_word(encoded, head + 768), 24);
        assertEq(_word(encoded, head + 800), 25);
        assertEq(_word(encoded, head + 832), 26);
        assertEq(_word(encoded, head + 864), 27);
        assertEq(_word(encoded, head + 896), 28);
        assertEq(_word(encoded, head + 928), 29);
        assertEq(_word(encoded, head + 960), 30);
        assertEq(_word(encoded, head + 992), 31);
        assertEq(_word(encoded, head + 1024), 32);
        assertEq(_word(encoded, head + 1056), 33);
        assertEq(_word(encoded, head + 1088), 34);
        assertEq(_word(encoded, head + 1120), 35);
        assertEq(_word(encoded, head + 1152), 36);
        assertEq(_word(encoded, head + 1184), 37);
        assertEq(_word(encoded, head + 1216), 38);
        assertEq(_word(encoded, head + 1248), 1);
        assertEq(_word(encoded, head + 1280), 40);
        assertEq(_word(encoded, head + 1312), 41);
        assertEq(_word(encoded, head + 1344), 42);
        assertEq(_word(encoded, head + 1376), 43);
        assertEq(_word(encoded, head + 1408), 44);
    }
}
