import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

import {
  preflightDeploymentConfig,
  soliditySecurityLimits,
  validateDeploymentConfig,
} from "./validate-config.mjs";

const repositoryRoot = resolve(new URL("../..", import.meta.url).pathname);
const templatePaths = [
  "deploy/config.example.json",
  "deploy/chains/ethereum.placeholder.json",
  "deploy/chains/bsc.placeholder.json",
  "deploy/chains/hsk.placeholder.json",
];

/** @param {string} path */
function readJson(path) {
  return JSON.parse(readFileSync(resolve(repositoryRoot, path), "utf8"));
}

/** @returns {any} */
function example() {
  return structuredClone(readJson("deploy/config.example.json"));
}

/** @param {unknown} value */
function errors(value) {
  return validateDeploymentConfig(value).errors.join("\n");
}

const roleNames = [
  "deployer",
  "defaultAdmin",
  "governance",
  "upgrader",
  "pauser",
  "executor",
  "configurer",
];

const operatorRoleNames = roleNames.slice(5);
const frozenSecurityLimits = {
  adapterProviderCallGasMax: soliditySecurityLimits.adapterProviderCallGasMax,
  calculatorStaticcallGas: 100_000,
  registryImplementationStaticcallGas: 200_000,
  registryReadStaticcallGas: 300_000,
  tokenViewStaticcallGas: 30_000,
  tokenWriteCallGas: 100_000,
  eip1271MaxChecksPerSettlement: 2,
  eip1271GasPolicy: "FORWARD_REMAINING_GAS_EIP150",
  maxDependentDvps: 32,
};

const localInputAddressPaths = [
  ["deploymentInputs", "tokens", "assetToken"],
  ["deploymentInputs", "tokens", "settlementToken"],
  ["deploymentInputs", "tokens", "erc1404Token"],
  ["deploymentInputs", "tokens", "usdyToken"],
  ["deploymentInputs", "providers", "usdyBlocklist"],
  ["deploymentInputs", "providers", "usdyAllowlist"],
  ["deploymentInputs", "providers", "usdySanctionsList"],
  ["deploymentInputs", "participants", "maker"],
  ["deploymentInputs", "participants", "requester"],
  ["deploymentInputs", "collector"],
];

test("LOCAL_TEST example is valid and exported preflight marks it deployable", () => {
  const config = example();
  assert.equal(config.mode, "LOCAL_TEST");
  assert.equal(config.usage, "LOCAL_ONLY");
  assert.equal(config.network.name, "LOCAL");
  assert.equal(config.network.chainId, 31_337);
  assert.equal(config.expectedFirstCreateNonce, 0);
  assert.equal("timelock" in config, false);
  assert.equal("governanceStatus" in config, false);
  assert.deepEqual(preflightDeploymentConfig(config, { currentCreateNonce: 0 }), {
    valid: true,
    mode: "LOCAL_TEST",
    deployable: true,
    governanceReady: true,
    expectedFirstCreateNonce: 0,
    errors: [],
  });
});

test("security and Gas limits are frozen in every deployment manifest", () => {
  for (const path of templatePaths) {
    assert.deepEqual(readJson(path).securityLimits, frozenSecurityLimits, path);
  }

  for (const [field, value] of Object.entries(frozenSecurityLimits)) {
    const config = example();
    config.securityLimits[field] = typeof value === "number" ? value + 1 : `${value}_MUTATED`;
    assert.match(errors(config), new RegExp(field, "u"), `${field} accepted a mutable value`);
  }

  const missing = example();
  delete missing.securityLimits;
  assert.match(errors(missing), /securityLimits/u);
});

test("Adapter provider call Gas cannot exceed the frozen maximum", () => {
  const boundary = example();
  boundary.deploymentInputs.providers.providerCallGas =
    frozenSecurityLimits.adapterProviderCallGasMax;
  assert.equal(errors(boundary), "");

  const above = example();
  above.deploymentInputs.providers.providerCallGas =
    frozenSecurityLimits.adapterProviderCallGasMax + 1;
  assert.match(errors(above), /providerCallGas/u);
});

test("chain placeholders validate but preflight never marks them deployable", () => {
  const expectedNetworks = ["Ethereum", "BSC", "HSK"];

  templatePaths.slice(1).forEach((path, index) => {
    const config = readJson(path);
    assert.equal(config.mode, "CHAIN_PLACEHOLDER");
    assert.equal(config.usage, "NOT_DEPLOYABLE");
    assert.equal(config.network.name, expectedNetworks[index]);
    assert.equal(config.network.chainId, null);
    assert.deepEqual(preflightDeploymentConfig(config), {
      valid: true,
      mode: "CHAIN_PLACEHOLDER",
      deployable: false,
      governanceReady: false,
      expectedFirstCreateNonce: null,
      errors: [],
    });
    assert.equal(config.expectedFirstCreateNonce, null);
    assert.equal("timelock" in config, false);
    assert.equal("governanceStatus" in config, false);
    assert.deepEqual(config.externalPolicy, {
      approvalStatus: "UNAPPROVED",
      rpcUrls: null,
      finalityConfirmations: null,
      gasPolicy: null,
      transactionType: null,
    });
    assert.ok(Object.values(config.roles).every((value) => value === null));
    assert.ok(localInputAddressPaths.every((segments) => {
      let value = config;
      for (const segment of segments) value = value[segment];
      return value === null;
    }));
  });

  const ethereum = readJson(templatePaths[1]);
  const bsc = readJson(templatePaths[2]);
  ethereum.roles.deployer = "0x1111111111111111111111111111111111111111";
  assert.notEqual(ethereum.roles.deployer, bsc.roles.deployer);
});

test("mode discriminant prevents placeholders from masquerading as deployable configs", () => {
  const placeholder = readJson(templatePaths[1]);
  placeholder.mode = "LOCAL_TEST";
  assert.equal(preflightDeploymentConfig(placeholder).deployable, false);
  assert.match(errors(placeholder), /usage|environment|chainId|roles/u);

  const local = example();
  local.mode = "CHAIN_PLACEHOLDER";
  assert.equal(preflightDeploymentConfig(local).deployable, false);
  assert.match(errors(local), /usage|environment|chainId|roles/u);
});

test("LOCAL_TEST requires the complete deployment role topology", () => {
  const config = example();
  assert.deepEqual(Object.keys(config.roles).sort(), [...roleNames].sort());
  for (const role of roleNames) {
    const mutated = example();
    delete mutated.roles[role];
    assert.match(errors(mutated), new RegExp(role, "u"));
  }
});

test("LOCAL_TEST keeps the configurer separate from the executor by default", () => {
  const config = example();
  assert.equal(new Set(Object.values(config.roles).map((value) => value.toLowerCase())).size, 5);
  assert.notEqual(config.roles.configurer, config.roles.executor);
  assert.equal(errors(config), "");
});

test("LOCAL_TEST still allows one address to hold both operator roles", () => {
  const config = example();
  for (const role of operatorRoleNames) config.roles[role] = config.roles.executor;
  assert.equal(errors(config), "");
});

test("LOCAL_TEST allows one address to hold every deployment role including deployer", () => {
  const config = example();
  const shared = "0x0000000000000000000000000000000000009001";
  for (const role of roleNames) config.roles[role] = shared;
  assert.equal(errors(config), "");
  assert.deepEqual(preflightDeploymentConfig(config, { currentCreateNonce: 0 }), {
    valid: true,
    mode: "LOCAL_TEST",
    deployable: true,
    governanceReady: true,
    expectedFirstCreateNonce: 0,
    errors: [],
  });
});

test("LOCAL_TEST rejects zero, null, and malformed role addresses", () => {
  for (const role of roleNames) {
    for (const address of [null, "0x0000000000000000000000000000000000000000", "0x1234"]) {
      const config = example();
      config.roles[role] = address;
      assert.match(errors(config), new RegExp(`roles/${role}|roles\\.${role}`, "u"));
    }
  }
});

test("LOCAL_TEST requires all Token, Asset, Adapter provider, participant, and collector fixture addresses", () => {
  for (const segments of localInputAddressPaths) {
    const config = example();
    let parent = config;
    for (const segment of segments.slice(0, -1)) parent = parent[segment];
    const leaf = segments[segments.length - 1];
    if (leaf === undefined) throw new Error("fixture path cannot be empty");
    parent[leaf] = "0x0000000000000000000000000000000000000000";
    assert.match(errors(config), new RegExp(leaf, "u"));
  }
});

test("Token decimals must stay within the production-supported 0..36 range", () => {
  for (const field of ["assetDecimals", "settlementTokenDecimals"]) {
    for (const value of [-1, 37, 77, 1.5, "18"]) {
      const config = example();
      config.deploymentInputs.tokens[field] = value;
      assert.match(errors(config), new RegExp(field, "u"), `${field} accepted ${String(value)}`);
    }
  }
});

test("initial Fee config is participant-type based and validates caps", () => {
  const config = example();
  assert.deepEqual(Object.keys(config.deploymentInputs.fee).sort(), [
    "investorCapAmount",
    "investorHasCap",
    "investorRateBps",
    "makerCapAmount",
    "makerHasCap",
    "makerRateBps",
  ]);

  const disabledWithAmount = example();
  disabledWithAmount.deploymentInputs.fee.makerCapAmount = 1;
  assert.match(errors(disabledWithAmount), /makerCapAmount.*zero/iu);

  const enabledWithoutAmount = example();
  enabledWithoutAmount.deploymentInputs.fee.investorCapAmount = 0;
  assert.match(errors(enabledWithoutAmount), /investorCapAmount.*positive/iu);
});

test("initial MarketRule config binds price and quantity decimals", () => {
  const wrongPriceDecimals = example();
  wrongPriceDecimals.deploymentInputs.marketRule.priceDecimals = 18;
  assert.match(errors(wrongPriceDecimals), /priceDecimals.*settlementTokenDecimals/iu);

  const wrongQuantityDecimals = example();
  wrongQuantityDecimals.deploymentInputs.marketRule.quantityDecimals = 6;
  assert.match(errors(wrongQuantityDecimals), /quantityDecimals.*assetDecimals/iu);
});

test("version fields accept only canonical numeric SemVer", () => {
  for (const field of ["configVersion", "deploymentVersion"]) {
    for (const version of ["v1.2.3", "01.2.3", "1.02.3", "1.2", "1.2.3-alpha", "1.2.3+build"]) {
      const config = example();
      config[field] = version;
      assert.match(errors(config), new RegExp(field, "u"), `${field} accepted ${version}`);
    }
  }
});

test("LOCAL_TEST chainId must be a positive safe integer", () => {
  for (const chainId of [0, -1, 1.5, "1", Number.MAX_SAFE_INTEGER + 1]) {
    const config = example();
    config.network.chainId = chainId;
    assert.match(errors(config), /chainId/u, `accepted ${String(chainId)}`);
  }
});

test("LOCAL_TEST nonce preflight preserves and matches the broadcaster current nonce", () => {
  const config = example();
  config.expectedFirstCreateNonce = 42;
  assert.deepEqual(preflightDeploymentConfig(config, { currentCreateNonce: 42 }), {
    valid: true,
    mode: "LOCAL_TEST",
    deployable: true,
    governanceReady: true,
    expectedFirstCreateNonce: 42,
    errors: [],
  });
});

test("stale or missing current nonce cannot pass LOCAL_TEST deployment preflight", () => {
  const config = example();
  config.expectedFirstCreateNonce = 7;

  const stale = preflightDeploymentConfig(config, { currentCreateNonce: 8 });
  assert.equal(stale.valid, false);
  assert.equal(stale.deployable, false);
  assert.equal(stale.expectedFirstCreateNonce, 7);
  assert.match(stale.errors.join("\n"), /stale|currentCreateNonce|nonce mismatch/iu);

  const missing = preflightDeploymentConfig(config);
  assert.equal(missing.valid, false);
  assert.equal(missing.deployable, false);
  assert.match(missing.errors.join("\n"), /currentCreateNonce.*required/iu);
});

test("malformed and negative expectedFirstCreateNonce values are rejected", () => {
  for (const nonce of [-1, 1.5, "0", null, true]) {
    const config = example();
    config.expectedFirstCreateNonce = nonce;
    const result = preflightDeploymentConfig(config, { currentCreateNonce: 0 });
    assert.equal(result.deployable, false);
    assert.match(result.errors.join("\n"), /expectedFirstCreateNonce/u, `accepted ${String(nonce)}`);
  }
});

test("unsafe and uint64-overflow nonce values are rejected without precision loss", () => {
  for (const nonce of [Number.MAX_SAFE_INTEGER + 1, 2 ** 64]) {
    const config = example();
    config.expectedFirstCreateNonce = nonce;
    const result = preflightDeploymentConfig(config, { currentCreateNonce: 0 });
    assert.equal(result.deployable, false);
    assert.equal(result.expectedFirstCreateNonce, null);
    assert.match(result.errors.join("\n"), /expectedFirstCreateNonce/u, `accepted ${String(nonce)}`);
  }
});

test("CHAIN_PLACEHOLDER keeps chainId, roles, deployment inputs, and policies unapproved/null", () => {
  const config = readJson(templatePaths[1]);
  config.expectedFirstCreateNonce = 0;
  config.network.chainId = 1;
  config.roles.deployer = "0x1111111111111111111111111111111111111111";
  config.deploymentInputs.collector = "0x2222222222222222222222222222222222222222";
  config.externalPolicy.finalityConfirmations = 12;
  const result = preflightDeploymentConfig(config);
  assert.equal(result.deployable, false);
  assert.equal(result.expectedFirstCreateNonce, null);
  assert.match(result.errors.join("\n"), /expectedFirstCreateNonce/u);
  assert.match(result.errors.join("\n"), /chainId/u);
  assert.match(result.errors.join("\n"), /roles\/deployer|roles\.deployer/u);
  assert.match(result.errors.join("\n"), /collector/u);
  assert.match(result.errors.join("\n"), /finalityConfirmations/u);
});

test("governanceMultisig is not part of the deployment config", () => {
  const config = example();
  config.roles.governanceMultisig = "0x0000000000000000000000000000000000003002";
  assert.match(errors(config), /governanceMultisig|additional properties/iu);
});

test("unapproved external policy cannot contain invented values", () => {
  const mutations = {
    rpcUrls: ["https://rpc.invalid"],
    finalityConfirmations: 12,
    gasPolicy: { maxGas: 1 },
    transactionType: "EIP1559",
  };

  for (const [field, value] of Object.entries(mutations)) {
    const config = readJson(templatePaths[1]);
    config.externalPolicy[field] = value;
    assert.match(errors(config), new RegExp(field, "u"), `${field} accepted an invented value`);
  }

  const config = readJson(templatePaths[1]);
  config.externalPolicy.approvalStatus = "APPROVED";
  assert.match(errors(config), /approvalStatus/u);
});

test("forbidden secret, signing, KMS, PII, and env fields are rejected even when null", () => {
  const forbiddenFields = [
    "privateKey",
    "mnemonic",
    "walletMnemonic",
    "raw",
    "rawTx",
    "rawTransaction",
    "signature",
    "kms",
    "kmsKeyId",
    "pii",
    "piiRecord",
    "customerEmail",
    "phone",
    ".env",
    "envFile",
  ];

  for (const field of forbiddenFields) {
    const config = example();
    config.metadata = { nested: { [field]: null } };
    assert.match(errors(config), /forbidden field/iu, `${field} was not rejected`);
  }
});

test("sensitive values are rejected even under an innocuous field name", () => {
  const sensitiveValues = [
    "-----BEGIN PRIVATE KEY-----",
    "arn:aws:kms:ap-southeast-1:123456789012:key/12345678-1234-1234-1234-123456789012",
    "person@example.com",
    ".env.production",
  ];

  for (const value of sensitiveValues) {
    const config = example();
    config.note = value;
    assert.match(errors(config), /forbidden value/iu, `${value} was not rejected`);
  }
});

test("unknown fields fail closed", () => {
  const config = example();
  config.unreviewedOverride = true;
  assert.match(errors(config), /additional properties|unreviewedOverride/iu);
});
