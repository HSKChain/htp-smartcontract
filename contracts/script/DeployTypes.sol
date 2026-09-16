// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {
    AdapterConfig,
    AssetVersionConfig,
    EligibilityInput,
    FeeConfig,
    FeePolicyEpochConfig,
    MarketRuleConfig,
    ParticipantInput,
    PrincipalCalculatorConfig,
    SettlementTokenConfig
} from "../src/types/HTPTypes.sol";

struct DeploymentRoles {
    address defaultAdmin;
    address governance;
    address upgrader;
    address pauser;
    address executor;
    // 八个 Registry 共用的唯一运营配置角色持有人。
    address configurer;
}

struct DeploymentConfig {
    DeploymentRoles roles;
    bytes deploymentVersion;
    uint256 chainId;
}

struct RegistryDeployment {
    address implementation;
    address proxy;
    bytes32 implementationCodeHash;
}

struct CoreDeployment {
    RegistryDeployment adapterRegistry;
    RegistryDeployment calculatorRegistry;
    RegistryDeployment settlementTokenRegistry;
    RegistryDeployment assetVersionRegistry;
    RegistryDeployment eligibilityRegistry;
    RegistryDeployment feeRegistry;
    RegistryDeployment marketRuleRegistry;
    RegistryDeployment participantRegistry;
    address currentStateValidatorFactory;
    address dvp;
}

struct ExampleAdapterInputs {
    address erc1404Token;
    address usdyToken;
    address usdyBlocklist;
    address usdyAllowlist;
    address usdySanctionsList;
    uint256 providerCallGas;
}

struct ExampleImplementations {
    address stockCalculator;
    address fundCalculator;
    address bondCalculator;
    address unrestrictedAdapter;
    address erc1404Adapter;
    address usdyAdapter;
}

struct ExampleBusinessInputs {
    address assetToken;
    uint8 assetDecimals;
    address settlementToken;
    uint8 settlementTokenDecimals;
    bytes32 economicAssetIdHash;
    address maker;
    address requester;
    address collector;
    uint64 quoteValidFrom;
    uint64 quoteValidUntil;
    uint64 settlementValidUntil;
    bytes32 evidenceHash;
}

struct ExampleConfigs {
    PrincipalCalculatorConfig[3] calculators;
    AdapterConfig[3] adapters;
    SettlementTokenConfig settlementToken;
    AssetVersionConfig assetVersion;
    ParticipantInput[2] participants;
    EligibilityInput[2] eligibilities;
    FeePolicyEpochConfig feeEpoch;
    FeeConfig fee;
    MarketRuleConfig marketRule;
}

struct DirectOperation {
    address target;
    bytes data;
}
