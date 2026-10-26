import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters, keccak256 } from "viem";

import {
  assessOndoGmForkReadiness,
  hashOndoGmProviders,
  verifyOndoGmFixedBlock,
} from "../fork/verify-ondo-gm-fixed-block.mjs";

/** @typedef {`0x${string}`} Hex */
/** @typedef {import("viem").Address} Address */
/**
 * @typedef {{
 *   calls: Array<{method: string, address?: Address, blockNumber?: bigint}>,
 *   getChainId: () => Promise<number>,
 *   getBlock: (parameters: {blockTag: "finalized"} | {blockNumber: bigint}) => Promise<{number: bigint | null, hash: Hex | null}>,
 *   getCode: (parameters: {address: Address, blockNumber: bigint}) => Promise<Hex | undefined>,
 *   call: (parameters: {to: Address, data: Hex, blockNumber: bigint}) => Promise<{data: Hex}>
 * }} MockFixedBlockClient
 */

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const goldenPath = resolve(root, "schema/v1/vectors/adapters/ondo-gm-aaplon.json");
/** @type {Address} */
const gmIdentifier = "0x428ecb70e90d1527a5f5e177789f51747b883f34";
/** @type {Record<string, Address>} */
const addresses = {
  token: "0x0000000000000000000000000000000000001001",
  complianceView: "0x0000000000000000000000000000000000001002",
  compliance: "0x0000000000000000000000000000000000001003",
  pauseManager: "0x0000000000000000000000000000000000001004",
  blocklist: "0x0000000000000000000000000000000000001005",
  sanctionsList: "0x0000000000000000000000000000000000001006",
};
/** @type {Record<string, Hex>} */
const codes = {
  token: "0x60016000f3",
  complianceView: "0x60026000f3",
  compliance: "0x60036000f3",
  pauseManager: "0x60046000f3",
  blocklist: "0x60056000f3",
  sanctionsList: "0x60066000f3",
};

/** @returns {Record<string, any>} */
function approvedEvidence() {
  /** @type {Record<string, Hex>} */
  const runtimeCodeHashes = Object.fromEntries(
    Object.entries(codes).map(([target, code]) => [target, keccak256(code)]),
  );
  return {
    approval: "PRODUCTION_APPROVED",
    status: "approved",
    network: "ethereum",
    evidenceBlock: 1_234_567,
    evidenceBlockHash: `0x${"ab".repeat(32)}`,
    decimals: 18,
    gmIdentifier,
    candidateAddresses: addresses,
    runtimeCodeHashes,
    providerHash: hashOndoGmProviders(addresses, runtimeCodeHashes),
  };
}

/** @param {Record<string, any>} [evidence] @returns {MockFixedBlockClient} */
function fixedBlockClient(evidence = approvedEvidence()) {
  /** @type {Array<{method: string, address?: Address, blockNumber?: bigint}>} */
  const calls = [];
  return {
    calls,
    async getChainId() {
      calls.push({ method: "getChainId" });
      return 1;
    },
    async getBlock(/** @type {{blockTag: "finalized"} | {blockNumber: bigint}} */ parameters) {
      calls.push({
        method: "getBlock",
        blockNumber: "blockNumber" in parameters ? parameters.blockNumber : undefined,
      });
      return "blockTag" in parameters
        ? { number: BigInt(evidence.evidenceBlock + 10), hash: `0x${"cd".repeat(32)}` }
        : { number: parameters.blockNumber, hash: evidence.evidenceBlockHash };
    },
    async getCode(
      /** @type {{address: Address, blockNumber: bigint}} */ { address, blockNumber },
    ) {
      calls.push({ method: "getCode", address, blockNumber });
      const target = Object.entries(addresses).find(([, candidate]) => candidate === address)?.[0];
      return target === undefined ? undefined : codes[target];
    },
    async call(
      /** @type {{to: Address, data: Hex, blockNumber: bigint}} */ { to, data, blockNumber },
    ) {
      calls.push({ method: "call", address: to, blockNumber });
      const selector = data.slice(0, 10);
      if (selector === "0x313ce567") return { data: encodeAbiParameters([{ type: "uint256" }], [18n]) };
      if (selector === "0x6290865d") {
        const value = to === addresses.token ? addresses.complianceView : addresses.compliance;
        return { data: encodeAbiParameters([{ type: "address" }], [value]) };
      }
      if (selector === "0x461ad792") {
        return { data: encodeAbiParameters([{ type: "address" }], [addresses.pauseManager]) };
      }
      if (selector === "0x03cad645") {
        return { data: encodeAbiParameters([{ type: "address" }], [gmIdentifier]) };
      }
      if (selector === "0xfed5f4b3") {
        return { data: encodeAbiParameters([{ type: "address" }], [addresses.blocklist]) };
      }
      if (selector === "0xefdc8834") {
        return { data: encodeAbiParameters([{ type: "address" }], [addresses.sanctionsList]) };
      }
      return { data: encodeAbiParameters([{ type: "bool" }], [false]) };
    },
  };
}

test("AAPLon candidate remains explicitly unapproved and fork-skipped", () => {
  const evidence = JSON.parse(readFileSync(goldenPath, "utf8"));
  const readiness = assessOndoGmForkReadiness({ rpcUrl: "", evidence });

  assert.equal(evidence.candidateAddresses.token, "0x14c3abf95cb9c93a8b82c1cdcb76d72cb87b2d4c");
  assert.equal(evidence.approval, "NOT_PRODUCTION_APPROVED");
  assert.equal(readiness.ready, false);
  assert.match(readiness.reason, /ETH_RPC_URL/);
  assert.match(readiness.reason, /NOT_PRODUCTION_APPROVED/);
});

test("CLI skip is explicit and cannot count as production evidence", () => {
  const env = { ...process.env };
  delete env.ETH_RPC_URL;
  const output = execFileSync(process.execPath, ["scripts/fork/verify-ondo-gm-fixed-block.mjs"], {
    cwd: root,
    env,
    encoding: "utf8",
  });
  assert.match(output, /^SKIP:/);
  assert.match(output, /does not count as production evidence/i);
});

test("approved evidence verifies the complete public provider graph at one fixed block", async () => {
  const evidence = approvedEvidence();
  const client = fixedBlockClient(evidence);

  await verifyOndoGmFixedBlock(client, evidence);

  const fixedBlock = BigInt(evidence.evidenceBlock);
  assert.ok(
    client.calls
      .filter(({ method }) => method !== "getChainId" && method !== "getBlock")
      .every(({ blockNumber }) => blockNumber === fixedBlock),
  );
  assert.equal("getStorageAt" in client, false);
});

test("runtime code drift and public provider graph drift fail closed", async () => {
  const evidence = approvedEvidence();
  const codeDriftClient = fixedBlockClient(evidence);
  const originalGetCode = codeDriftClient.getCode;
  codeDriftClient.getCode = async (parameters) =>
    parameters.address === addresses.blocklist ? "0x60076000f3" : originalGetCode(parameters);
  await assert.rejects(
    () => verifyOndoGmFixedBlock(codeDriftClient, evidence),
    /blocklist runtime codeHash mismatch/,
  );

  const providerDriftClient = fixedBlockClient(evidence);
  const originalCall = providerDriftClient.call;
  providerDriftClient.call = async (parameters) =>
    parameters.data.startsWith("0xfed5f4b3")
      ? { data: encodeAbiParameters([{ type: "address" }], [addresses.sanctionsList]) }
      : originalCall(parameters);
  await assert.rejects(() => verifyOndoGmFixedBlock(providerDriftClient, evidence), /GM blocklist mismatch/);
});

test("providerHash and GM identifier drift are rejected", async () => {
  const evidence = approvedEvidence();
  evidence.providerHash = `0x${"11".repeat(32)}`;
  await assert.rejects(() => verifyOndoGmFixedBlock(fixedBlockClient(evidence), evidence), /providerHash mismatch/);

  const identifierClient = fixedBlockClient(approvedEvidence());
  const originalCall = identifierClient.call;
  identifierClient.call = async (parameters) =>
    parameters.data.startsWith("0x03cad645")
      ? { data: encodeAbiParameters([{ type: "address" }], [addresses.blocklist]) }
      : originalCall(parameters);
  await assert.rejects(
    () => verifyOndoGmFixedBlock(identifierClient, approvedEvidence()),
    /GM identifier mismatch/,
  );
});

test("provider responses must be one canonical ABI word", async () => {
  const nonCanonicalBoolClient = fixedBlockClient();
  const originalBoolCall = nonCanonicalBoolClient.call;
  nonCanonicalBoolClient.call = async (parameters) =>
    parameters.to === addresses.pauseManager
      ? { data: /** @type {Hex} */ (`0x${"0".repeat(63)}2`) }
      : originalBoolCall(parameters);
  await assert.rejects(
    () => verifyOndoGmFixedBlock(nonCanonicalBoolClient, approvedEvidence()),
    /isTokenPaused\(\) returned malformed bool data/,
  );

  const trailingDataClient = fixedBlockClient();
  const originalTrailingCall = trailingDataClient.call;
  trailingDataClient.call = async (parameters) => {
    const result = await originalTrailingCall(parameters);
    return parameters.to === addresses.sanctionsList
      ? { data: /** @type {Hex} */ (`${result.data}${"0".repeat(64)}`) }
      : result;
  };
  await assert.rejects(
    () => verifyOndoGmFixedBlock(trailingDataClient, approvedEvidence()),
    /isSanctioned\(\) returned malformed bool data/,
  );
});
