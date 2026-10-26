// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { assertAdapterChainPolicy, loadPlatform, normalizeRequest } from "./deploy-adapter.mjs";
import {
  assertMainnetOndoEvidence,
  detectTokenDeployment,
  normalizeConfig,
  recoverPending,
} from "./deploy-platform.mjs";

const ADDRESS = "0x0000000000000000000000000000000000001001";

function validConfig() {
  return {
    expectedChainId: 133,
    finalityConfirmations: 5,
    deploymentVersion: "1.0.0",
    evidenceHash: `0x${"11".repeat(32)}`,
    roles: {
      defaultAdmin: ADDRESS,
      governance: ADDRESS,
      upgrader: ADDRESS,
      pauser: ADDRESS,
      executor: ADDRESS,
      configurer: ADDRESS,
    },
    settlementToken: {
      address: "0x0000000000000000000000000000000000002001",
      decimals: 6,
      permitCapability: "UNSUPPORTED",
      deploymentKind: "DIRECT",
      implementation: null,
    },
    calculators: ["FUND"],
    assetAdapters: {
      usdyRestricted: {
        token: "0x0000000000000000000000000000000000003001",
      },
      ondoGm: null,
      erc1404: null,
    },
    globalFee: {
      investorRateBps: 25,
      investorHasCap: false,
      investorCapAmount: "0",
      makerRateBps: 15,
      makerHasCap: false,
      makerCapAmount: "0",
      collector: ADDRESS,
    },
  };
}

test("platform config requires strict chain, boolean, and field types", () => {
  assert.equal(normalizeConfig(validConfig()).expectedChainId, 133);
  assert.throws(() => normalizeConfig({ ...validConfig(), expectedChainId: null }), /expectedChainId 必须是正整数/u);
  assert.throws(() => normalizeConfig({ ...validConfig(), unexpected: true }), /config 包含未知字段/u);
  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        globalFee: { ...validConfig().globalFee, investorHasCap: "false" },
      }),
    /investorHasCap 必须是 boolean/u,
  );
  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        settlementToken: { ...validConfig().settlementToken, rpcUrl: "https://example.com" },
      }),
    /不允许包含 RPC 字段/u,
  );
  for (const investorCapAmount of [true, 9_007_199_254_740_992, "01"]) {
    assert.throws(
      () =>
        normalizeConfig({
          ...validConfig(),
          globalFee: { ...validConfig().globalFee, investorCapAmount },
        }),
      /非负十进制字符串/u,
    );
  }
  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        globalFee: { ...validConfig().globalFee, investorCapAmount: (1n << 256n).toString() },
      }),
    /超出 uint256/u,
  );
});

test("platform config enforces Ethereum and HSK asset profiles", () => {
  const ethereum = {
    ...validConfig(),
    expectedChainId: 1,
    calculators: ["FUND", "STOCK"],
    assetAdapters: {
      ...validConfig().assetAdapters,
      ondoGm: { token: "0x0000000000000000000000000000000000003002" },
    },
  };
  assert.equal(normalizeConfig(ethereum).assetAdapters.ondoGm.token, "0x0000000000000000000000000000000000003002");
  assert.throws(
    () => normalizeConfig({ ...ethereum, assetAdapters: { ...ethereum.assetAdapters, ondoGm: null } }),
    /Ethereum 主网部署必须同时配置/u,
  );
  assert.throws(
    () => normalizeConfig({ ...ethereum, calculators: ["FUND"] }),
    /必须同时包含 FUND 和 STOCK/u,
  );

  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        assetAdapters: {
          ...validConfig().assetAdapters,
          ondoGm: { token: "0x0000000000000000000000000000000000003002" },
        },
      }),
    /HSK 部署只允许 USDY/u,
  );
  assert.throws(() => assertAdapterChainPolicy(177, "ondoGm"), /HSK 只上 USDY/u);
  assert.doesNotThrow(() => assertAdapterChainPolicy(1, "ondoGm"));
});

test("Ethereum platform deployment rejects unapproved Ondo evidence before RPC reads", async () => {
  await assert.rejects(
    () =>
      assertMainnetOndoEvidence({
        chainId: 1,
        config: {
          assetAdapters: {
            ondoGm: { token: "0x14c3abf95cb9c93a8b82c1cdcb76d72cb87b2d4c" },
          },
        },
        publicClient: {},
      }),
    /evidence is not approved|approval is NOT_PRODUCTION_APPROVED/u,
  );
});

test("tracked Ethereum and HSK platform profiles remain valid", () => {
  for (const path of ["deploy/ops-platform.ethereum.example.json", "deploy/ops-platform.example.json"]) {
    assert.doesNotThrow(() => normalizeConfig(JSON.parse(readFileSync(path, "utf8"))), path);
  }
});

test("platform config requires explicit external token deployment metadata", () => {
  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        settlementToken: {
          ...validConfig().settlementToken,
          deploymentKind: "ERC1967_PROXY",
          implementation: null,
        },
      }),
    /必须显式提供 implementation/u,
  );
  assert.throws(
    () =>
      normalizeConfig({
        ...validConfig(),
        settlementToken: {
          ...validConfig().settlementToken,
          implementation: "0x0000000000000000000000000000000000002002",
        },
      }),
    /DIRECT 时 implementation 必须为空/u,
  );
});

test("ERC-1967 settlement metadata must match the implementation slot", async () => {
  const token = "0x0000000000000000000000000000000000002001";
  const implementation = "0x0000000000000000000000000000000000002002";
  const wrongImplementation = "0x0000000000000000000000000000000000002003";
  const publicClient = {
    getCode: async () => "0x6000",
    getStorageAt: async () => `0x${"0".repeat(24)}${implementation.slice(2)}`,
  };
  const metadata = {
    deploymentKind: 2,
    implementation,
  };

  assert.equal((await detectTokenDeployment(publicClient, token, metadata)).implementation, implementation);
  await assert.rejects(
    () => detectTokenDeployment(publicClient, token, { ...metadata, implementation: wrongImplementation }),
    /implementation slot=.*不一致/u,
  );
});

test("resume stops when an unrecorded transaction still occupies the nonce", async () => {
  const entry = {
    status: "pending",
    from: ADDRESS,
    nonce: 5,
  };
  const state = { steps: { write: entry } };
  const ctx = {
    state,
    publicClient: {
      getTransactionCount: async ({ blockTag }) => (blockTag === "latest" ? 5 : 6),
    },
    saveState() {
      throw new Error("pending state must not be deleted");
    },
  };
  const step = { id: "write", kind: "write", check: async () => false };

  await assert.rejects(() => recoverPending(ctx, step, entry), /为避免重复交易/u);
  assert.equal(state.steps.write, entry);
});

test("adapter deployment rejects non-numeric report chain IDs", () => {
  const directory = mkdtempSync(join(tmpdir(), "htp-adapter-report-"));
  const reportPath = join(directory, "report.json");
  try {
    writeFileSync(
      reportPath,
      JSON.stringify({
        metadata: { chainId: "133", finalityConfirmations: 5 },
        addresses: {
          dvp: "0x0000000000000000000000000000000000002001",
          registries: { adapter: "0x0000000000000000000000000000000000002002" },
        },
      }),
    );
    assert.throws(() => loadPlatform(reportPath), /合法的 chainId/u);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("adapter CLI accepts canonical numeric provider gas", () => {
  assert.equal(
    normalizeRequest({
      type: "erc1404",
      token: "0x0000000000000000000000000000000000002001",
      providerCallGas: "50000",
    }).spec.providerCallGas,
    50_000,
  );
  assert.equal(
    normalizeRequest({
      type: "ondo-gm",
      token: "0x0000000000000000000000000000000000002002",
    }).key,
    "ondoGm",
  );
});
