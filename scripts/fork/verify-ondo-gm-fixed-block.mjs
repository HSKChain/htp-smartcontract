import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  concat,
  createPublicClient,
  decodeAbiParameters,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  http,
  keccak256,
  parseAbi,
  toBytes,
  toFunctionSelector,
} from "viem";

/** @typedef {`0x${string}`} Hex */
/** @typedef {import("viem").Address} Address */
/** @typedef {Record<string, any>} OndoGmEvidence */
/**
 * @typedef {{
 *   getChainId: () => Promise<number>,
 *   getBlock: (parameters: {blockTag: "finalized"} | {blockNumber: bigint}) => Promise<{number: bigint | null, hash: Hex | null}>,
 *   getCode: (parameters: {address: Address, blockNumber: bigint}) => Promise<Hex | undefined>,
 *   call: (parameters: {to: Address, data: Hex, blockNumber: bigint}) => Promise<{data?: Hex}>
 * }} FixedBlockClient
 */
/** @typedef {{provider: Address, selector: Hex, codeHash: Hex}} ProviderEntry */

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const defaultEvidencePath = resolve(root, "schema/v1/vectors/adapters/ondo-gm-aaplon.json");
const HASH_PATTERN = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const EXPECTED_GM_IDENTIFIER = getAddress(`0x${keccak256(toBytes("global_markets")).slice(-40)}`);
const PROVIDER_TYPEHASH = keccak256(toBytes("RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)"));
const PROVIDER_SET_TYPEHASH = keccak256(
  toBytes(
    "RestrictionProviderSet(RestrictionProvider[] providers)RestrictionProvider(address provider,bytes4 selector,bytes32 codeHash)",
  ),
);

const TOKEN_ABI = parseAbi([
  "function decimals() view returns (uint8)",
  "function compliance() view returns (address)",
  "function tokenPauseManager() view returns (address)",
]);
const VIEW_ABI = parseAbi([
  "function compliance() view returns (address)",
  "function gmIdentifier() view returns (address)",
]);
const COMPLIANCE_ABI = parseAbi([
  "function rwaTokenToBlocklist(address identifier) view returns (address)",
  "function rwaTokenToSanctionsList(address identifier) view returns (address)",
]);
const PAUSE_ABI = parseAbi(["function isTokenPaused(address token) view returns (bool)"]);
const BLOCKLIST_ABI = parseAbi(["function isBlocked(address account) view returns (bool)"]);
const SANCTIONS_ABI = parseAbi(["function isSanctioned(address account) view returns (bool)"]);

/** @param {{rpcUrl: unknown, evidence: OndoGmEvidence | null | undefined}} input */
export function assessOndoGmForkReadiness({ rpcUrl, evidence }) {
  const reasons = [];
  if (typeof rpcUrl !== "string" || rpcUrl.trim() === "") reasons.push("ETH_RPC_URL is missing");
  if (evidence?.approval !== "PRODUCTION_APPROVED") {
    reasons.push(`approval is ${String(evidence?.approval ?? "missing")}`);
  }
  const evidenceBlock = evidence?.evidenceBlock;
  if (!Number.isSafeInteger(evidenceBlock) || evidenceBlock <= 0) {
    reasons.push("approved evidenceBlock is missing");
  }
  if (typeof evidence?.evidenceBlockHash !== "string" || !HASH_PATTERN.test(evidence.evidenceBlockHash)) {
    reasons.push("approved evidenceBlockHash is missing");
  }
  return reasons.length === 0 ? { ready: true, reason: "" } : { ready: false, reason: reasons.join("; ") };
}

/** @param {unknown} value @param {string} label */
function requiredAddress(value, label) {
  if (typeof value !== "string" || !ADDRESS_PATTERN.test(value)) {
    throw new Error(`${label} must be a 20-byte address.`);
  }
  const address = getAddress(value);
  if (address === ZERO_ADDRESS) throw new Error(`${label} must not be zero.`);
  return address;
}

/** @param {unknown} value @param {string} label @returns {Hex} */
function requiredHash(value, label) {
  if (typeof value !== "string" || !HASH_PATTERN.test(value)) {
    throw new Error(`${label} must be a 32-byte hash.`);
  }
  return /** @type {Hex} */ (value.toLowerCase());
}

/** @param {unknown} actual @param {unknown} expected @param {string} label */
function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label} mismatch: expected=${String(expected)}, actual=${String(actual)}.`);
  }
}

/** @param {Hex} data @param {"address" | "bool" | "uint256"} type @param {string} label */
function decodeWord(data, type, label) {
  if (!/^0x[0-9a-fA-F]{64}$/u.test(data)) {
    throw new Error(`${label} returned malformed ${type} data.`);
  }
  if (type === "bool" && BigInt(data) > 1n) {
    throw new Error(`${label} returned malformed bool data.`);
  }
  try {
    return decodeAbiParameters([{ type }], data)[0];
  } catch {
    throw new Error(`${label} returned malformed ${type} data.`);
  }
}

/**
 * @param {FixedBlockClient} client
 * @param {Address} address
 * @param {any} abi
 * @param {string} functionName
 * @param {any[]} args
 * @param {bigint} blockNumber
 * @param {"address" | "bool" | "uint256"} outputType
 */
async function call(client, address, abi, functionName, args, blockNumber, outputType) {
  const result = await client.call({
    to: address,
    data: encodeFunctionData({ abi, functionName, args }),
    blockNumber,
  });
  if (typeof result.data !== "string") throw new Error(`${functionName}() returned no data.`);
  return decodeWord(result.data, outputType, `${functionName}()`);
}

/** @param {ProviderEntry} left @param {ProviderEntry} right */
function compareProviders(left, right) {
  const addressOrder = BigInt(left.provider) - BigInt(right.provider);
  if (addressOrder !== 0n) return addressOrder < 0n ? -1 : 1;
  return Number.parseInt(left.selector.slice(2), 16) - Number.parseInt(right.selector.slice(2), 16);
}

/**
 * @param {Record<string, Address>} addresses
 * @param {Record<string, Hex>} codeHashes
 */
export function hashOndoGmProviders(addresses, codeHashes) {
  const entries = [
    ["token", "compliance()"],
    ["token", "tokenPauseManager()"],
    ["complianceView", "compliance()"],
    ["complianceView", "gmIdentifier()"],
    ["compliance", "rwaTokenToBlocklist(address)"],
    ["compliance", "rwaTokenToSanctionsList(address)"],
    ["pauseManager", "isTokenPaused(address)"],
    ["blocklist", "isBlocked(address)"],
    ["sanctionsList", "isSanctioned(address)"],
  ].map(([target, signature]) => ({
    provider: addresses[target],
    selector: toFunctionSelector(signature),
    codeHash: codeHashes[target],
  }));
  const hashes = entries.sort(compareProviders).map((entry) =>
    keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "address" }, { type: "bytes4" }, { type: "bytes32" }],
        [PROVIDER_TYPEHASH, entry.provider, entry.selector, entry.codeHash],
      ),
    ),
  );
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [PROVIDER_SET_TYPEHASH, keccak256(concat(hashes))]),
  );
}

/** @param {FixedBlockClient} client @param {OndoGmEvidence} evidence */
export async function verifyOndoGmFixedBlock(client, evidence) {
  const readiness = assessOndoGmForkReadiness({ rpcUrl: "injected-client", evidence });
  if (!readiness.ready) throw new Error(`Ondo GM evidence is not approved: ${readiness.reason}.`);
  if (evidence.status !== "approved" || evidence.network !== "ethereum") {
    throw new Error("Ondo GM evidence must have approved status for the ethereum network.");
  }
  assertEqual(await client.getChainId(), 1, "Ethereum chainId");
  const blockNumber = BigInt(evidence.evidenceBlock);
  const finalized = await client.getBlock({ blockTag: "finalized" });
  if (finalized.number === null || finalized.number < blockNumber) {
    throw new Error(`Evidence block ${blockNumber} is not finalized (finalized=${String(finalized.number)}).`);
  }
  const block = await client.getBlock({ blockNumber });
  assertEqual(block.hash?.toLowerCase(), requiredHash(evidence.evidenceBlockHash, "evidenceBlockHash"), "block hash");

  const targets = ["token", "complianceView", "compliance", "pauseManager", "blocklist", "sanctionsList"];
  /** @type {Record<string, Address>} */
  const addresses = Object.fromEntries(
    targets.map((target) => [target, requiredAddress(evidence.candidateAddresses?.[target], target)]),
  );
  /** @type {Record<string, Hex>} */
  const codeHashes = Object.fromEntries(
    targets.map((target) => [target, requiredHash(evidence.runtimeCodeHashes?.[target], `${target} codeHash`)]),
  );
  if (evidence.decimals !== 18) throw new Error("AAPLon decimals baseline must be 18.");
  assertEqual(requiredAddress(evidence.gmIdentifier, "gmIdentifier"), EXPECTED_GM_IDENTIFIER, "approved GM identifier");
  for (const target of targets) {
    const code = await client.getCode({ address: addresses[target], blockNumber });
    if (typeof code !== "string" || !/^0x(?:[0-9a-fA-F]{2})+$/u.test(code)) {
      throw new Error(`${target} has no runtime bytecode at the evidence block.`);
    }
    assertEqual(keccak256(/** @type {Hex} */ (code)), codeHashes[target], `${target} runtime codeHash`);
  }

  assertEqual(
    await call(client, addresses.token, TOKEN_ABI, "decimals", [], blockNumber, "uint256"),
    BigInt(evidence.decimals),
    "token decimals",
  );
  assertEqual(
    await call(client, addresses.token, TOKEN_ABI, "compliance", [], blockNumber, "address"),
    addresses.complianceView,
    "token compliance",
  );
  assertEqual(
    await call(client, addresses.token, TOKEN_ABI, "tokenPauseManager", [], blockNumber, "address"),
    addresses.pauseManager,
    "token pause manager",
  );
  assertEqual(
    await call(client, addresses.complianceView, VIEW_ABI, "compliance", [], blockNumber, "address"),
    addresses.compliance,
    "underlying compliance",
  );
  const identifier = await call(
    client,
    addresses.complianceView,
    VIEW_ABI,
    "gmIdentifier",
    [],
    blockNumber,
    "address",
  );
  assertEqual(identifier, EXPECTED_GM_IDENTIFIER, "GM identifier");
  assertEqual(
    await call(
      client,
      addresses.compliance,
      COMPLIANCE_ABI,
      "rwaTokenToBlocklist",
      [identifier],
      blockNumber,
      "address",
    ),
    addresses.blocklist,
    "GM blocklist",
  );
  assertEqual(
    await call(
      client,
      addresses.compliance,
      COMPLIANCE_ABI,
      "rwaTokenToSanctionsList",
      [identifier],
      blockNumber,
      "address",
    ),
    addresses.sanctionsList,
    "GM sanctions list",
  );
  await call(client, addresses.pauseManager, PAUSE_ABI, "isTokenPaused", [addresses.token], blockNumber, "bool");
  await call(client, addresses.blocklist, BLOCKLIST_ABI, "isBlocked", [ZERO_ADDRESS], blockNumber, "bool");
  await call(client, addresses.sanctionsList, SANCTIONS_ABI, "isSanctioned", [ZERO_ADDRESS], blockNumber, "bool");
  assertEqual(hashOndoGmProviders(addresses, codeHashes), requiredHash(evidence.providerHash, "providerHash"), "providerHash");
}

async function runCli() {
  const evidencePath =
    process.env.ONDO_GM_EVIDENCE_PATH === undefined
      ? defaultEvidencePath
      : resolve(process.env.ONDO_GM_EVIDENCE_PATH);
  const evidence = JSON.parse(readFileSync(evidencePath, "utf8"));
  const rpcUrl = process.env.ETH_RPC_URL;
  const readiness = assessOndoGmForkReadiness({ rpcUrl, evidence });
  if (!readiness.ready) {
    console.log(
      `SKIP: Ethereum Ondo GM fixed-block verification: ${readiness.reason}. ` +
        "This skip does not count as production evidence.",
    );
    return;
  }
  const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 0 }) });
  /** @type {FixedBlockClient} */
  const fixedBlockClient = {
    getChainId: () => client.getChainId(),
    getBlock: (parameters) =>
      "blockTag" in parameters
        ? client.getBlock({ blockTag: parameters.blockTag })
        : client.getBlock({ blockNumber: parameters.blockNumber }),
    getCode: (parameters) => client.getCode(parameters),
    call: (parameters) => client.call(parameters),
  };
  await verifyOndoGmFixedBlock(fixedBlockClient, evidence);
  console.log(`Ethereum Ondo GM fixed-block verification passed at block ${evidence.evidenceBlock}.`);
}

if (process.argv[1] !== undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  runCli().catch((error) => {
    const rpcUrl = process.env.ETH_RPC_URL;
    const message = error instanceof Error ? error.message : String(error);
    console.error(
      `Ethereum Ondo GM fixed-block verification failed: ${
        typeof rpcUrl === "string" && rpcUrl !== "" ? message.replaceAll(rpcUrl, "<redacted ETH_RPC_URL>") : message
      }`,
    );
    process.exitCode = 1;
  });
}
