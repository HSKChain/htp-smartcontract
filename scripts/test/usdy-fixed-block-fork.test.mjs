import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters, keccak256 } from "viem";

import {
  ERC1967_IMPLEMENTATION_SLOT,
  assessUsdyForkReadiness,
  verifyUsdyFixedBlock,
} from "../fork/verify-usdy-fixed-block.mjs";

/** @typedef {import("viem").Address} Address */
/** @typedef {`0x${string}`} Hex */
/** @typedef {"token" | "blocklist" | "allowlist" | "sanctionsList"} ProviderTarget */
/** @typedef {"blocklist" | "allowlist" | "sanctionsList"} ListTarget */
/** @typedef {{blockTag: "finalized"} | {blockNumber: bigint}} BlockParameters */
/** @typedef {{address: Address, blockNumber: bigint}} CodeParameters */
/** @typedef {{address: Address, blockNumber: bigint, slot: Hex}} StorageParameters */
/** @typedef {{data: Hex, blockNumber: bigint}} CallParameters */
/**
 * @typedef {object} MockFixedBlockClient
 * @property {Array<{method: string, address?: Address, blockNumber?: bigint}>} calls
 * @property {() => Promise<number>} getChainId
 * @property {(parameters: BlockParameters) => Promise<{number: bigint | null, hash: Hex | null}>} getBlock
 * @property {(parameters: CodeParameters) => Promise<Hex | undefined>} getCode
 * @property {(parameters: StorageParameters) => Promise<Hex>} getStorageAt
 * @property {(parameters: CallParameters) => Promise<{data: Hex}>} call
 */

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const goldenPath = resolve(root, "schema/v1/vectors/adapters/usdy.json");
/** @type {Address} */
const token = "0x0000000000000000000000000000000000001001";
/** @type {Address} */
const blocklist = "0x0000000000000000000000000000000000001002";
/** @type {Address} */
const allowlist = "0x0000000000000000000000000000000000001003";
/** @type {Address} */
const sanctionsList = "0x0000000000000000000000000000000000001004";
/** @type {Address} */
const implementation = "0x0000000000000000000000000000000000001005";
/** @type {Address} */
const allowlistImplementation = "0x0000000000000000000000000000000000001006";
/** @type {Address} */
const wrongImplementation = "0x0000000000000000000000000000000000001007";
/** @type {Hex} */
const tokenCode = "0x60016000f3";
/** @type {Record<ProviderTarget, Hex>} */
const providerCodes = {
  token: tokenCode,
  blocklist: "0x60026000f3",
  allowlist: "0x60036000f3",
  sanctionsList: "0x60046000f3",
};
/** @type {Hex} */
const implementationCode = "0x60056000f3";
/** @type {Hex} */
const allowlistImplementationCode = "0x60066000f3";

function approvedEvidence() {
  /** @type {Record<ListTarget, Address>} */
  const listAddresses = { blocklist, allowlist, sanctionsList };
  /** @type {Array<[ProviderTarget, Hex, string]>} */
  const providerRows = [
    ["token", "0x5c975abb", "paused()"],
    ["token", "0xd64e5396", "blocklist()"],
    ["token", "0x2b47da52", "allowlist()"],
    ["token", "0xec571c6a", "sanctionsList()"],
    ["blocklist", "0xfbac3951", "isBlocked(address)"],
    ["allowlist", "0xbabcc539", "isAllowed(address)"],
    ["sanctionsList", "0xdf592f7d", "isSanctioned(address)"],
  ];
  const providerEntries = providerRows.map(([target, selector, selectorSignature]) => ({
    target,
    selector,
    selectorSignature,
    provider: target === "token" ? token : listAddresses[target],
    codeHash: keccak256(providerCodes[target]),
    deploymentKind: target === "token" || target === "allowlist" ? "ERC1967_PROXY" : "DIRECT",
    ...(target === "token"
      ? {
          implementation,
          implementationCodeHash: keccak256(implementationCode),
        }
      : target === "allowlist"
        ? {
            implementation: allowlistImplementation,
            implementationCodeHash: keccak256(allowlistImplementationCode),
          }
        : {}),
  }));
  return {
    approval: "PRODUCTION_APPROVED",
    status: "approved",
    network: "ethereum",
    evidenceBlock: 1_234_567,
    evidenceBlockHash: /** @type {Hex} */ (`0x${"ab".repeat(32)}`),
    candidateAddresses: { token, blocklist, allowlist, sanctionsList },
    tokenBaseline: {
      deploymentKind: "ERC1967_PROXY",
      decimals: 18,
      tokenCodeHash: keccak256(tokenCode),
      implementation,
      implementationCodeHash: keccak256(implementationCode),
    },
    providerEntries,
  };
}

/**
 * @param {ReturnType<typeof approvedEvidence>} [evidence]
 * @returns {MockFixedBlockClient}
 */
function fixedBlockClient(evidence = approvedEvidence()) {
  /** @type {Array<{method: string, address?: Address, blockNumber?: bigint}>} */
  const calls = [];
  /** @type {Record<string, Address>} */
  const addressByGetter = {
    "0xd64e5396": blocklist,
    "0x2b47da52": allowlist,
    "0xec571c6a": sanctionsList,
  };
  /** @type {Record<Address, Hex>} */
  const codeByAddress = {
    [token]: tokenCode,
    [blocklist]: providerCodes.blocklist,
    [allowlist]: providerCodes.allowlist,
    [sanctionsList]: providerCodes.sanctionsList,
    [implementation]: implementationCode,
    [allowlistImplementation]: allowlistImplementationCode,
  };
  /** @type {Record<Address, Address>} */
  const implementationByProxy = {
    [token]: implementation,
    [allowlist]: allowlistImplementation,
  };
  return {
    calls,
    async getChainId() {
      calls.push({ method: "getChainId" });
      return 1;
    },
    async getBlock(/** @type {BlockParameters} */ parameters) {
      calls.push({
        method: "getBlock",
        blockNumber: "blockNumber" in parameters ? parameters.blockNumber : undefined,
      });
      if ("blockTag" in parameters) {
        return {
          number: BigInt(evidence.evidenceBlock + 10),
          hash: /** @type {Hex} */ (`0x${"cd".repeat(32)}`),
        };
      }
      return { number: parameters.blockNumber, hash: evidence.evidenceBlockHash };
    },
    async getCode(/** @type {CodeParameters} */ { address, blockNumber }) {
      calls.push({ method: "getCode", address, blockNumber });
      return codeByAddress[address];
    },
    async getStorageAt(
      /** @type {StorageParameters} */ { address, blockNumber, slot },
    ) {
      calls.push({ method: "getStorageAt", address, blockNumber });
      assert.equal(slot, ERC1967_IMPLEMENTATION_SLOT);
      const proxyImplementation = implementationByProxy[address];
      return encodeAbiParameters(
        [{ type: "address" }],
        [proxyImplementation ?? "0x0000000000000000000000000000000000000000"],
      );
    },
    async call(/** @type {CallParameters} */ { data, blockNumber }) {
      calls.push({ method: "call", blockNumber });
      const selector = data.slice(0, 10);
      if (selector === "0x313ce567") {
        return { data: encodeAbiParameters([{ type: "uint256" }], [18n]) };
      }
      if (selector in addressByGetter) {
        return { data: encodeAbiParameters([{ type: "address" }], [addressByGetter[selector]]) };
      }
      return { data: encodeAbiParameters([{ type: "bool" }], [false]) };
    },
  };
}

test("current Phase17 USDY candidate explicitly remains fork-skipped", () => {
  const evidence = JSON.parse(readFileSync(goldenPath, "utf8"));
  const readiness = assessUsdyForkReadiness({ rpcUrl: "", evidence });

  assert.equal(evidence.approval, "NOT_PRODUCTION_APPROVED");
  assert.equal(readiness.ready, false);
  assert.match(readiness.reason, /ETH_RPC_URL/);
  assert.match(readiness.reason, /NOT_PRODUCTION_APPROVED/);
  assert.match(readiness.reason, /evidenceBlock/);
});

test("offline CLI emits an explicit non-evidence skip", () => {
  const env = { ...process.env };
  delete env.ETH_RPC_URL;
  const output = execFileSync(
    process.execPath,
    ["scripts/fork/verify-usdy-fixed-block.mjs"],
    { cwd: root, env, encoding: "utf8" },
  );

  assert.match(output, /^SKIP:/);
  assert.match(output, /does not count as production evidence/i);
});

test("approved evidence verifies token proxy, allowlist proxy and direct lists at one block", async () => {
  const evidence = approvedEvidence();
  const client = fixedBlockClient(evidence);

  await verifyUsdyFixedBlock(client, evidence);

  const fixedBlock = BigInt(evidence.evidenceBlock);
  assert.ok(
    client.calls
      .filter(({ method }) => method !== "getChainId" && method !== "getBlock")
      .every(({ blockNumber }) => blockNumber === fixedBlock),
  );
  const storageAddresses = client.calls
    .filter(({ method }) => method === "getStorageAt")
    .map(({ address }) => address);
  assert.deepEqual(new Set(storageAddresses), new Set([token, allowlist]));
  assert.equal(storageAddresses.includes(blocklist), false);
  assert.equal(storageAddresses.includes(sanctionsList), false);
});

test("fixed-block verification detects token implementation runtime mutations", async () => {
  const evidence = approvedEvidence();
  const client = fixedBlockClient(evidence);
  const originalGetCode = client.getCode;
  client.getCode = async (parameters) =>
    parameters.address === implementation
      ? "0x60076000f3"
      : originalGetCode(parameters);

  await assert.rejects(
    () => verifyUsdyFixedBlock(client, evidence),
    /token implementation runtime codeHash mismatch/,
  );
});

test("provider proxy implementation address mismatch fails", async () => {
  const evidence = approvedEvidence();
  const allowlistEntry = evidence.providerEntries.find((entry) => entry.target === "allowlist");
  assert.ok(allowlistEntry);
  allowlistEntry.implementation = wrongImplementation;
  const client = fixedBlockClient(evidence);

  await assert.rejects(
    () => verifyUsdyFixedBlock(client, evidence),
    /allowlist ERC1967 implementation mismatch/,
  );
});

test("provider implementation codeHash mismatch fails", async () => {
  const evidence = approvedEvidence();
  const client = fixedBlockClient(evidence);
  const originalGetCode = client.getCode;
  client.getCode = async (parameters) =>
    parameters.address === allowlistImplementation
      ? "0x60076000f3"
      : originalGetCode(parameters);

  await assert.rejects(
    () => verifyUsdyFixedBlock(client, evidence),
    /allowlist implementation runtime codeHash mismatch/,
  );
});

test("implementation slot malformed or zero fails", async () => {
  const evidence = approvedEvidence();
  const malformedClient = fixedBlockClient(evidence);
  malformedClient.getStorageAt = async () => "0x1234";
  await assert.rejects(
    () => verifyUsdyFixedBlock(malformedClient, evidence),
    /token ERC1967 implementation slot returned malformed data/,
  );

  const zeroClient = fixedBlockClient(evidence);
  zeroClient.getStorageAt = async () =>
    encodeAbiParameters([{ type: "address" }], ["0x0000000000000000000000000000000000000000"]);
  await assert.rejects(
    () => verifyUsdyFixedBlock(zeroClient, evidence),
    /token ERC1967 implementation slot is zero/,
  );
});

test("DIRECT evidence carrying implementation fails without reading the proxy slot", async () => {
  const evidence = approvedEvidence();
  const blocklistEntry = evidence.providerEntries.find((entry) => entry.target === "blocklist");
  assert.ok(blocklistEntry);
  blocklistEntry.implementation = blocklist;
  const client = fixedBlockClient(evidence);

  await assert.rejects(
    () => verifyUsdyFixedBlock(client, evidence),
    /blocklist DIRECT evidence must not carry a nonzero implementation/,
  );
  assert.equal(
    client.calls.some(({ method, address }) => method === "getStorageAt" && address === blocklist),
    false,
  );
});

test("runtime codeHash drift fails", async () => {
  const evidence = approvedEvidence();
  const client = fixedBlockClient(evidence);
  const originalGetCode = client.getCode;
  client.getCode = async (parameters) =>
    parameters.address === blocklist ? "0x60076000f3" : originalGetCode(parameters);

  await assert.rejects(
    () => verifyUsdyFixedBlock(client, evidence),
    /blocklist runtime codeHash mismatch/,
  );
});
