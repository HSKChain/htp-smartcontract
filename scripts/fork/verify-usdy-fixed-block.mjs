import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  decodeAbiParameters,
  getAddress,
  http,
  keccak256,
} from "viem";

/** @typedef {`0x${string}`} Hex */
/** @typedef {import("viem").Address} Address */
/** @typedef {"token" | "blocklist" | "allowlist" | "sanctionsList"} ProviderTarget */
/** @typedef {ProviderTarget | "implementation"} CandidateTarget */
/**
 * @typedef {object} DeploymentBaseline
 * @property {unknown} [deploymentKind]
 * @property {unknown} [codeHash]
 * @property {unknown} [tokenCodeHash]
 * @property {unknown} [implementation]
 * @property {unknown} [implementationCodeHash]
 * @property {unknown} [decimals]
 */
/**
 * @typedef {object} ProviderEntry
 * @property {unknown} target
 * @property {unknown} provider
 * @property {unknown} codeHash
 * @property {unknown} selector
 * @property {unknown} selectorSignature
 * @property {unknown} [deploymentKind]
 * @property {unknown} [implementation]
 * @property {unknown} [implementationCodeHash]
 */
/**
 * @typedef {object} UsdyEvidence
 * @property {unknown} approval
 * @property {unknown} status
 * @property {unknown} network
 * @property {unknown} evidenceBlock
 * @property {unknown} evidenceBlockHash
 * @property {Record<string, unknown> | null | undefined} candidateAddresses
 * @property {DeploymentBaseline | null | undefined} tokenBaseline
 * @property {ProviderEntry[] | null | undefined} providerEntries
 */
/**
 * @typedef {object} FixedBlockClient
 * @property {() => Promise<number>} getChainId
 * @property {(parameters: {blockTag: "finalized"} | {blockNumber: bigint}) => Promise<{number: bigint | null, hash: Hex | null}>} getBlock
 * @property {(parameters: {address: Address, blockNumber: bigint}) => Promise<Hex | undefined>} getCode
 * @property {(parameters: {address: Address, slot: Hex, blockNumber: bigint}) => Promise<Hex | undefined>} getStorageAt
 * @property {(parameters: {to: Address, data: Hex, blockNumber: bigint}) => Promise<{data?: Hex}>} call
 */

export const ERC1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const defaultEvidencePath = resolve(root, "schema/v1/vectors/adapters/usdy.json");
const HASH_PATTERN = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const SELECTOR_PATTERN = /^0x[0-9a-fA-F]{8}$/;
const ZERO_ADDRESS_ARGUMENT = "0".repeat(64);
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/**
 * Determines whether a run can produce evidence. Candidate vectors and an RPC
 * alone are intentionally insufficient.
 *
 * @param {{rpcUrl: unknown, evidence: Partial<UsdyEvidence> | null | undefined}} input
 */
export function assessUsdyForkReadiness({ rpcUrl, evidence }) {
  const reasons = [];
  if (typeof rpcUrl !== "string" || rpcUrl.trim() === "") {
    reasons.push("ETH_RPC_URL is missing");
  }
  if (evidence?.approval !== "PRODUCTION_APPROVED") {
    reasons.push(`approval is ${String(evidence?.approval ?? "missing")}`);
  }
  const evidenceBlock = evidence?.evidenceBlock;
  if (
    typeof evidenceBlock !== "number" ||
    !Number.isSafeInteger(evidenceBlock) ||
    evidenceBlock <= 0
  ) {
    reasons.push("approved evidenceBlock is missing");
  }
  if (typeof evidence?.evidenceBlockHash !== "string" || !HASH_PATTERN.test(evidence.evidenceBlockHash)) {
    reasons.push("approved evidenceBlockHash is missing");
  }
  return reasons.length === 0
    ? { ready: true, reason: "" }
    : { ready: false, reason: reasons.join("; ") };
}

/**
 * @param {unknown} value
 * @param {string} label
 */
function requiredAddress(value, label) {
  if (typeof value !== "string" || !ADDRESS_PATTERN.test(value)) {
    throw new Error(`${label} must be a 20-byte address.`);
  }
  return getAddress(value);
}

/**
 * @param {unknown} value
 * @param {string} label
 */
function requiredHash(value, label) {
  if (typeof value !== "string" || !HASH_PATTERN.test(value)) {
    throw new Error(`${label} must be a 32-byte hash.`);
  }
  return value.toLowerCase();
}

/**
 * @param {unknown} value
 * @param {string} label
 */
function requiredSelector(value, label) {
  if (typeof value !== "string" || !SELECTOR_PATTERN.test(value)) {
    throw new Error(`${label} must be a 4-byte selector.`);
  }
  return value.toLowerCase();
}

/**
 * @param {unknown} value
 * @returns {Address | null}
 */
function nonzeroAddress(value) {
  if (typeof value !== "string" || !ADDRESS_PATTERN.test(value)) return null;
  const parsed = getAddress(value);
  return parsed === ZERO_ADDRESS ? null : parsed;
}

/**
 * @param {unknown} value
 * @returns {value is ProviderTarget}
 */
function isProviderTarget(value) {
  return (
    value === "token" ||
    value === "blocklist" ||
    value === "allowlist" ||
    value === "sanctionsList"
  );
}

/**
 * @param {unknown} code
 * @param {string} label
 */
function codeHash(code, label) {
  if (typeof code !== "string" || !/^0x(?:[0-9a-fA-F]{2})+$/.test(code)) {
    throw new Error(`${label} has no runtime bytecode at the evidence block.`);
  }
  return keccak256(/** @type {`0x${string}`} */ (code));
}

/**
 * @param {unknown} actual
 * @param {unknown} expected
 * @param {string} label
 */
function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label} mismatch: expected=${String(expected)}, actual=${String(actual)}.`);
  }
}

/**
 * @param {unknown} data
 * @param {"address" | "bool" | "uint256"} type
 * @param {string} label
 */
function decodeWord(data, type, label) {
  if (typeof data !== "string") {
    throw new Error(`${label} returned no data.`);
  }
  try {
    return decodeAbiParameters(
      [{ type }],
      /** @type {`0x${string}`} */ (data),
    )[0];
  } catch {
    throw new Error(`${label} returned malformed ${type} data.`);
  }
}

/**
 * Verifies one address against a DIRECT or ERC1967_PROXY deployment baseline
 * at a single evidence block. DIRECT evidence must not carry a nonzero
 * implementation and must not read the proxy slot.
 *
 * @param {FixedBlockClient} client
 * @param {Address} target
 * @param {DeploymentBaseline | null | undefined} baseline
 * @param {bigint} blockNumber
 * @param {string} label
 */
export async function verifyDeploymentBaseline(client, target, baseline, blockNumber, label) {
  if (baseline === null || baseline === undefined || typeof baseline !== "object") {
    throw new Error(`${label} deployment baseline is missing.`);
  }
  const kind = baseline.deploymentKind;
  if (kind !== "ERC1967_PROXY" && kind !== "DIRECT") {
    throw new Error(`${label} deploymentKind must be ERC1967_PROXY or DIRECT.`);
  }
  const expectedCodeHash = requiredHash(
    baseline.codeHash ?? baseline.tokenCodeHash,
    `${label} codeHash`,
  );
  const runtimeCode = await client.getCode({ address: target, blockNumber });
  assertEqual(codeHash(runtimeCode, label), expectedCodeHash, `${label} runtime codeHash`);

  const implementation = nonzeroAddress(baseline.implementation);
  if (kind === "DIRECT") {
    if (implementation !== null) {
      throw new Error(`${label} DIRECT evidence must not carry a nonzero implementation.`);
    }
    return;
  }

  const expectedImplementation = requiredAddress(baseline.implementation, `${label} implementation`);
  const implementationWord = await client.getStorageAt({
    address: target,
    slot: ERC1967_IMPLEMENTATION_SLOT,
    blockNumber,
  });
  if (typeof implementationWord !== "string" || !HASH_PATTERN.test(implementationWord)) {
    throw new Error(`${label} ERC1967 implementation slot returned malformed data.`);
  }
  const actualImplementation = getAddress(`0x${implementationWord.slice(-40)}`);
  if (actualImplementation === ZERO_ADDRESS) {
    throw new Error(`${label} ERC1967 implementation slot is zero.`);
  }
  assertEqual(actualImplementation, expectedImplementation, `${label} ERC1967 implementation`);
  const implementationCode = await client.getCode({
    address: expectedImplementation,
    blockNumber,
  });
  assertEqual(
    codeHash(implementationCode, `${label} implementation`),
    requiredHash(baseline.implementationCodeHash, `${label} implementationCodeHash`),
    `${label} implementation runtime codeHash`,
  );
}

/**
 * Verifies the complete USDY candidate baseline against one finalized Ethereum
 * block. The client is injected so this interface is offline-testable.
 *
 * @param {FixedBlockClient} client
 * @param {UsdyEvidence} evidence
 */
export async function verifyUsdyFixedBlock(client, evidence) {
  const readiness = assessUsdyForkReadiness({ rpcUrl: "injected-client", evidence });
  if (!readiness.ready) {
    throw new Error(`USDY evidence is not approved: ${readiness.reason}.`);
  }
  if (evidence.status !== "approved" || evidence.network !== "ethereum") {
    throw new Error("USDY evidence must have approved status for the ethereum network.");
  }
  if (typeof evidence.evidenceBlock !== "number") {
    throw new Error("USDY evidenceBlock must be a number.");
  }

  const blockNumber = BigInt(evidence.evidenceBlock);
  const chainId = await client.getChainId();
  assertEqual(chainId, 1, "Ethereum chainId");
  const finalizedBlock = await client.getBlock({ blockTag: "finalized" });
  if (finalizedBlock.number === null || finalizedBlock.number < blockNumber) {
    throw new Error(
      `Evidence block ${blockNumber} is not finalized (finalized=${String(finalizedBlock.number)}).`,
    );
  }
  const evidenceBlock = await client.getBlock({ blockNumber });
  assertEqual(
    evidenceBlock.hash?.toLowerCase(),
    requiredHash(evidence.evidenceBlockHash, "evidenceBlockHash"),
    "Evidence block hash",
  );

  const candidates = evidence.candidateAddresses;
  /** @type {Record<ProviderTarget, Address>} */
  const addresses = {
    token: requiredAddress(candidates?.token, "candidate token"),
    blocklist: requiredAddress(candidates?.blocklist, "candidate blocklist"),
    allowlist: requiredAddress(candidates?.allowlist, "candidate allowlist"),
    sanctionsList: requiredAddress(candidates?.sanctionsList, "candidate sanctionsList"),
  };
  const baseline = evidence.tokenBaseline;
  if (baseline?.deploymentKind !== "ERC1967_PROXY") {
    throw new Error("USDY token baseline deploymentKind must be ERC1967_PROXY.");
  }
  const baselineDecimals = baseline.decimals;
  if (
    typeof baselineDecimals !== "number" ||
    !Number.isInteger(baselineDecimals) ||
    baselineDecimals < 0 ||
    baselineDecimals > 255
  ) {
    throw new Error("USDY token baseline decimals must be an integer from 0 to 255.");
  }

  await verifyDeploymentBaseline(client, addresses.token, baseline, blockNumber, "token");

  const decimalsResult = await client.call({
    to: addresses.token,
    data: "0x313ce567",
    blockNumber,
  });
  assertEqual(
    decodeWord(decimalsResult.data, "uint256", "decimals()"),
    BigInt(baselineDecimals),
    "token decimals",
  );

  if (!Array.isArray(evidence.providerEntries) || evidence.providerEntries.length === 0) {
    throw new Error("Approved USDY evidence must contain providerEntries.");
  }
  /** @type {Map<ProviderTarget, string>} */
  const targetCodeHashes = new Map();
  /** @type {Set<ProviderTarget>} */
  const verifiedTargets = new Set();
  /** @type {Record<string, ProviderTarget | undefined>} */
  const getterTargets = {
    "blocklist()": "blocklist",
    "allowlist()": "allowlist",
    "sanctionsList()": "sanctionsList",
  };
  for (const [index, entry] of evidence.providerEntries.entries()) {
    const target = entry?.target;
    if (!isProviderTarget(target)) {
      throw new Error(`providerEntries[${index}] has an unsupported target.`);
    }
    const provider = requiredAddress(entry.provider, `providerEntries[${index}].provider`);
    assertEqual(provider, addresses[target], `providerEntries[${index}] provider`);
    const expectedCodeHash = requiredHash(
      entry.codeHash,
      `providerEntries[${index}].codeHash`,
    );
    const previousCodeHash = targetCodeHashes.get(target);
    if (previousCodeHash !== undefined && previousCodeHash !== expectedCodeHash) {
      throw new Error(`Conflicting approved code hashes for provider target ${target}.`);
    }
    targetCodeHashes.set(target, expectedCodeHash);
    if (!verifiedTargets.has(target)) {
      verifiedTargets.add(target);
      if (target === "token") {
        assertEqual(
          expectedCodeHash,
          requiredHash(baseline.tokenCodeHash ?? baseline.codeHash, "tokenCodeHash"),
          "token provider codeHash",
        );
      } else {
        await verifyDeploymentBaseline(
          client,
          provider,
          {
            deploymentKind: entry.deploymentKind,
            codeHash: entry.codeHash,
            implementation: entry.implementation,
            implementationCodeHash: entry.implementationCodeHash,
          },
          blockNumber,
          target,
        );
      }
    }
    const selector = requiredSelector(entry.selector, `providerEntries[${index}].selector`);
    if (typeof entry.selectorSignature !== "string") {
      throw new Error(`providerEntries[${index}].selectorSignature must be a string.`);
    }
    const signature = entry.selectorSignature;
    const getterTarget = getterTargets[signature];
    const data = /** @type {Hex} */ (
      signature === "paused()" || getterTarget !== undefined
        ? selector
        : `${selector}${ZERO_ADDRESS_ARGUMENT}`
    );
    const result = await client.call({
      to: provider,
      data,
      blockNumber,
    });
    if (getterTarget !== undefined) {
      const actualProvider = decodeWord(result.data, "address", signature);
      assertEqual(actualProvider, addresses[getterTarget], `${signature} provider getter`);
    } else {
      decodeWord(result.data, "bool", signature);
    }
  }

  const providerTargets =
    /** @type {const} */ (["token", "blocklist", "allowlist", "sanctionsList"]);
  for (const target of providerTargets) {
    if (!verifiedTargets.has(target)) {
      throw new Error(`Approved USDY evidence is missing provider target ${target}.`);
    }
  }
}

async function runCli() {
  const evidencePath =
    process.env.USDY_EVIDENCE_PATH === undefined
      ? defaultEvidencePath
      : resolve(process.env.USDY_EVIDENCE_PATH);
  const evidence =
    /** @type {UsdyEvidence} */ (JSON.parse(readFileSync(evidencePath, "utf8")));
  const rpcUrl = process.env.ETH_RPC_URL;
  const readiness = assessUsdyForkReadiness({ rpcUrl, evidence });
  if (!readiness.ready) {
    console.log(
      `SKIP: Ethereum USDY fixed-block fork verification: ${readiness.reason}. ` +
        "This skip does not count as production evidence.",
    );
    return;
  }

  const client = createPublicClient({
    transport: http(rpcUrl, { retryCount: 0 }),
  });
  /** @type {FixedBlockClient} */
  const fixedBlockClient = {
    getChainId: () => client.getChainId(),
    getBlock: (parameters) =>
      "blockTag" in parameters
        ? client.getBlock({ blockTag: parameters.blockTag })
        : client.getBlock({ blockNumber: parameters.blockNumber }),
    getCode: (parameters) => client.getCode(parameters),
    getStorageAt: (parameters) => client.getStorageAt(parameters),
    call: (parameters) => client.call(parameters),
  };
  await verifyUsdyFixedBlock(fixedBlockClient, evidence);
  console.log(
    `Ethereum USDY fixed-block verification passed at block ${evidence.evidenceBlock}.`,
  );
}

if (
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1])
) {
  runCli().catch((error) => {
    const rpcUrl = process.env.ETH_RPC_URL;
    const message = error instanceof Error ? error.message : String(error);
    const sanitized =
      typeof rpcUrl === "string" && rpcUrl !== ""
        ? message.replaceAll(rpcUrl, "<redacted ETH_RPC_URL>")
        : message;
    console.error(`Ethereum USDY fixed-block verification failed: ${sanitized}`);
    process.exitCode = 1;
  });
}
