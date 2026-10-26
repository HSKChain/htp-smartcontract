// @ts-nocheck
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  assertSameOndoFamily,
  buildListingConfigs,
  listingSteps,
  normalizeAssetConfig,
} from "./list-asset.mjs";
import { Enum, ZERO_ADDRESS, ZERO_BYTES32 } from "./lib/htp-hash.mjs";

const HASH = (byte) => `0x${String(byte).padStart(2, "0").repeat(32)}`;
const ADDRESS = (suffix) => `0x${suffix.padStart(40, "0")}`;

test("tracked asset listing profiles remain valid and HSK rejects Ondo", () => {
  for (const path of [
    "deploy/ops-asset.ondo-stock.ethereum.example.json",
    "deploy/ops-asset.usdy.ethereum.example.json",
    "deploy/ops-asset.usdy.hsk.example.json",
  ]) {
    assert.doesNotThrow(() => normalizeAssetConfig(JSON.parse(readFileSync(path, "utf8"))), path);
  }
  const ondo = JSON.parse(readFileSync("deploy/ops-asset.ondo-stock.ethereum.example.json", "utf8"));
  assert.throws(() => normalizeAssetConfig({ ...ondo, expectedChainId: 177 }), /HSK 只允许上架 USDY/u);
  assert.throws(() => normalizeAssetConfig({ ...ondo, calculator: "FUND" }), /calculator 必须与 assetClass 相同/u);
});

test("second Ondo family token reuses adapter config and creates only asset/market writes", () => {
  const raw = JSON.parse(readFileSync("deploy/ops-asset.ondo-stock.ethereum.example.json", "utf8"));
  const first = normalizeAssetConfig({ ...raw, assetToken: ADDRESS("101") });
  const second = normalizeAssetConfig({ ...raw, assetToken: ADDRESS("102") });
  const platform = {
    chainId: 1,
    deploymentVersion: "1.0.0",
    dvp: ADDRESS("201"),
    settlementToken: ADDRESS("202"),
    adapter: {
      id: HASH("11"),
      hash: HASH("12"),
      tokenStandard: Enum.TokenStandard.ERC20,
      restrictionMode: Enum.RestrictionMode.TOKEN_ENFORCED,
    },
    calculator: { id: HASH("21"), hash: HASH("22") },
    settlement: { id: HASH("31"), hash: HASH("32"), decimals: 6 },
    feeEpoch: { quoteValidFrom: 100, quoteValidUntil: 200, settlementValidUntil: 300 },
  };
  const deployment = {
    kind: Enum.TokenDeploymentKind.DIRECT,
    tokenCodeHash: HASH("41"),
    implementation: ZERO_ADDRESS,
    implementationCodeHash: ZERO_BYTES32,
  };
  const firstConfigs = buildListingConfigs(first, platform, deployment, 18);
  const secondConfigs = buildListingConfigs(second, platform, deployment, 18);

  assert.equal(firstConfigs.asset.adapterConfigId, secondConfigs.asset.adapterConfigId);
  assert.equal(firstConfigs.asset.adapterConfigHash, secondConfigs.asset.adapterConfigHash);
  assert.notEqual(firstConfigs.asset.assetVersionId, secondConfigs.asset.assetVersionId);
  assert.throws(() => buildListingConfigs(first, platform, deployment, 0), /decimals 必须是 1-36/u);
  assert.deepEqual(
    listingSteps().map(({ id, kind }) => ({ id, kind })),
    [
      { id: "asset.register", kind: "write" },
      { id: "asset.activate", kind: "write" },
      { id: "market.register", kind: "write" },
      { id: "market.seal", kind: "write" },
      { id: "market.activate", kind: "write" },
    ],
  );
});

test("Ondo family comparison ignores token address but rejects provider drift", () => {
  const reference = Object.fromEntries(
    [
      "tokenCodeHash",
      "complianceView",
      "complianceViewCodeHash",
      "compliance",
      "complianceCodeHash",
      "gmIdentifier",
      "pauseManager",
      "pauseManagerCodeHash",
      "blocklist",
      "blocklistCodeHash",
      "sanctionsList",
      "sanctionsListCodeHash",
    ].map((field, index) => [field, field.endsWith("Hash") ? HASH(String((index % 9) + 1)) : ADDRESS(String(index + 1))]),
  );
  assert.doesNotThrow(() => assertSameOndoFamily(reference, { ...reference, token: ADDRESS("999") }));
  assert.throws(
    () => assertSameOndoFamily(reference, { ...reference, pauseManager: ADDRESS("999") }),
    /pauseManager 不一致/u,
  );
});
