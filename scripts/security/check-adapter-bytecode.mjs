import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const contractsOut = resolve(repositoryRoot, "contracts/out");
const contractsSourceRoot = resolve(repositoryRoot, "contracts/src");
const adaptersSourceRoot = resolve(contractsSourceRoot, "adapters");
const fixturesSourceRoot = resolve(repositoryRoot, "contracts/test/fixtures");

const approvedMethods = new Map([
  ["capabilities()", "34a18fc3"],
  ["capabilityHash()", "b61a1820"],
  ["interfaceVersion()", "1d8ffa4d"],
  ["preCheck(address,address,address,uint256,uint8,bytes32)", "4b5cf187"],
  ["providerHash()", "8898b13f"],
]);

/**
 * @typedef {{stateMutability: string[], outputs: string[], components?: string[]}} AbiPolicy
 */
/** @type {Map<string, AbiPolicy>} */
const approvedAbi = new Map([
  [
    "capabilities()",
    {
      stateMutability: ["pure"],
      outputs: ["tuple"],
      components: ["uint8", "uint8", "uint8", "uint256"],
    },
  ],
  ["capabilityHash()", {stateMutability: ["pure"], outputs: ["bytes32"]}],
  ["interfaceVersion()", {stateMutability: ["pure"], outputs: ["bytes32"]}],
  [
    "preCheck(address,address,address,uint256,uint8,bytes32)",
    {stateMutability: ["view"], outputs: ["uint8", "uint256", "bytes32"]},
  ],
  ["providerHash()", {stateMutability: ["pure", "view"], outputs: ["bytes32"]}],
]);

const forbiddenOpcodes = new Map([
  [0x54, "SLOAD"],
  [0x55, "SSTORE"],
  [0x5c, "TLOAD"],
  [0x5d, "TSTORE"],
  [0xa0, "LOG0"],
  [0xa1, "LOG1"],
  [0xa2, "LOG2"],
  [0xa3, "LOG3"],
  [0xa4, "LOG4"],
  [0xf0, "CREATE"],
  [0xf1, "CALL"],
  [0xf2, "CALLCODE"],
  [0xf4, "DELEGATECALL"],
  [0xf5, "CREATE2"],
  [0xff, "SELFDESTRUCT"],
]);

const forbiddenSelectors = new Map([
  ["23b872dd", "transferFrom(address,address,uint256)"],
  ["50a466c1", "calculate(bytes,uint256,uint8)"],
  ["a9059cbb", "transfer(address,uint256)"],
]);

/** @type {Record<string, string[]>} */
const providerSelectors = {
  ERC1404Adapter: ["d4ce1415"],
  OndoGmTokenAdapter: [
    "6290865d", // compliance()
    "461ad792", // tokenPauseManager()
    "03cad645", // gmIdentifier()
    "fed5f4b3", // rwaTokenToBlocklist(address)
    "efdc8834", // rwaTokenToSanctionsList(address)
    "5e76ad54", // isTokenPaused(address)
    "fbac3951", // isBlocked(address)
    "df592f7d", // isSanctioned(address)
  ],
  UnrestrictedERC20Adapter: [],
  UsdyRestrictedAdapter: [
    "5c975abb", // paused()
    "d64e5396", // blocklist()
    "2b47da52", // allowlist()
    "ec571c6a", // sanctionsList()
    "fbac3951", // isBlocked(address)
    "babcc539", // isAllowed(address)
    "df592f7d", // isSanctioned(address)
  ],
};

const approvedSourceSha256 = new Map([
  ["adapters/ERC1404Adapter.sol", "4cc8b8ffd2bd828670b5d18bb3d0e754c814f28b411326d569141c1e3da13e4c"],
  [
    "adapters/OndoGmTokenAdapter.sol",
    "c2f58c2639aa5112637dc18f92a5e82d610ba6d9e34ed5a3c0dcc40a9cdc2f70",
  ],
  [
    "adapters/UnrestrictedERC20Adapter.sol",
    "85f366c3d52ccc277f92cb3cf69bcc8976cec0c0456a02fbf2af0bc6326678cf",
  ],
  [
    "adapters/UsdyRestrictedAdapter.sol",
    "28794a8c564c3a51f38a4e5c97cc21958ab7852e6df8585bd4306ce7fa504653",
  ],
  ["interfaces/IAssetAdapter.sol", "684fbabb824215a85d650d25f5f65c7f83a8365f91705e95461dac5f768fa238"],
  [
    "libraries/AdapterInputValidation.sol",
    "fa1eb67e1d2fd40779471bacf6c512a83271a4b561a7bd64d5e1a7077ac4dd87",
  ],
  [
    "libraries/AdapterReasonCodes.sol",
    "a63c1afe6447e95d484cd08b3e0c71c90c6f8d9e15d5941532ac8050b4acc1f4",
  ],
  [
    "libraries/BoundedStaticCall.sol",
    "bd65e5b360d957211ae7d184397e5fc6c63b1be09b1d66166a67545a43c8d717",
  ],
  [
    "libraries/RestrictionProviderLib.sol",
    "b12ca4d5ecd007bca6ff6a136ed62120cb85e778dd163d93d0f246430a4b1b18",
  ],
]);

/**
 * @typedef {{
 *   type?: string,
 *   name?: string,
 *   stateMutability?: string,
 *   inputs?: Array<{type?: string}>,
 *   outputs?: Array<{type?: string, components?: Array<{type?: string}>}>
 * }} AbiEntry
 *
 * @typedef {{
 *   abi?: AbiEntry[],
 *   deployedBytecode?: {object?: string},
 *   methodIdentifiers?: Record<string, string>
 * }} FoundryArtifact
 */

/**
 * @param {string} sourceName
 * @param {string} contractName
 * @returns {FoundryArtifact}
 */
function readArtifact(sourceName, contractName) {
  const path = resolve(contractsOut, sourceName, `${contractName}.json`);
  return JSON.parse(readFileSync(path, "utf8"));
}

/**
 * @param {string} relativePath
 * @returns {string}
 */
function sourceSha256(relativePath) {
  const source = readFileSync(resolve(contractsSourceRoot, relativePath));
  return createHash("sha256").update(source).digest("hex");
}

/**
 * @param {string} object
 * @returns {Buffer}
 */
function executableRuntime(object) {
  if (!object.startsWith("0x") || object.length % 2 !== 0) {
    throw new Error("runtime bytecode is not canonical hex");
  }
  const bytecode = Buffer.from(object.slice(2), "hex");
  if (bytecode.length < 2) return bytecode;
  const metadataLength = bytecode.readUInt16BE(bytecode.length - 2);
  if (metadataLength + 2 > bytecode.length) {
    throw new Error("runtime bytecode has an invalid metadata trailer");
  }
  return bytecode.subarray(0, bytecode.length - metadataLength - 2);
}

/**
 * @param {AbiEntry} entry
 * @returns {string}
 */
function abiSignature(entry) {
  return `${entry.name ?? ""}(${(entry.inputs ?? []).map((input) => input.type ?? "").join(",")})`;
}

/**
 * @param {Array<{type?: string}> | undefined} entries
 * @returns {string[]}
 */
function abiTypes(entries) {
  return (entries ?? []).map((entry) => entry.type ?? "");
}

/**
 * @param {string} source
 * @returns {string[]}
 */
function analyzeAdapterSource(source) {
  const issues = [];
  if (/\.(?:call|callcode|delegatecall|staticcall)\s*\(/u.test(source)) {
    issues.push("source contains a forbidden direct low-level call");
  }
  if (/\b(?:transfer|transferFrom)\s*\(/u.test(source)) {
    issues.push("source contains a forbidden token transfer call");
  }
  return issues;
}

/**
 * @param {FoundryArtifact} artifact
 * @param {string[]} approvedProviderSelectors
 * @returns {string[]}
 */
function analyze(artifact, approvedProviderSelectors) {
  const issues = [];
  for (const entry of artifact.abi ?? []) {
    if (entry.type === "fallback" || entry.type === "receive") {
      issues.push(`unapproved ${entry.type} or receive entry point`);
    }
    if (entry.type !== "function") continue;

    const signature = abiSignature(entry);
    const policy = approvedAbi.get(signature);
    if (policy === undefined) continue;
    if (!policy.stateMutability.includes(entry.stateMutability ?? "")) {
      issues.push(`${signature} has unapproved state mutability ${entry.stateMutability}`);
    }
    const outputs = abiTypes(entry.outputs);
    if (JSON.stringify(outputs) !== JSON.stringify(policy.outputs)) {
      issues.push(`${signature} has unapproved outputs ${outputs.join(",")}`);
    }
    if (policy.components !== undefined) {
      const components = abiTypes(entry.outputs?.[0]?.components);
      if (JSON.stringify(components) !== JSON.stringify(policy.components)) {
        issues.push(`${signature} has unapproved tuple components ${components.join(",")}`);
      }
    }
  }

  const methods = artifact.methodIdentifiers ?? {};
  for (const [signature, selector] of Object.entries(methods)) {
    const approvedSelector = approvedMethods.get(signature);
    if (approvedSelector === undefined) {
      issues.push(`unapproved external selector ${signature} (${selector})`);
    } else if (approvedSelector !== selector) {
      issues.push(`selector drift for ${signature}: ${selector}`);
    }
  }
  for (const signature of approvedMethods.keys()) {
    if (!(signature in methods)) issues.push(`missing approved selector ${signature}`);
  }

  const runtimeObject = artifact.deployedBytecode?.object;
  if (typeof runtimeObject !== "string" || runtimeObject === "0x") {
    issues.push("missing deployed runtime bytecode");
    return issues;
  }

  const runtime = executableRuntime(runtimeObject);
  const discovered = new Set();
  let hasStaticcall = false;
  for (let offset = 0; offset < runtime.length; offset += 1) {
    const opcode = runtime[offset];
    if (opcode === 0xfa) hasStaticcall = true;
    const forbidden = forbiddenOpcodes.get(opcode);
    if (forbidden !== undefined) discovered.add(forbidden);
    if (opcode >= 0x60 && opcode <= 0x7f) offset += opcode - 0x5f;
  }
  for (const opcode of [...discovered].sort()) {
    issues.push(`forbidden opcode ${opcode}`);
  }

  const runtimeHex = runtime.toString("hex");
  for (const [selector, signature] of forbiddenSelectors) {
    if (runtimeHex.includes(selector)) issues.push(`forbidden embedded selector ${signature}`);
  }

  if (hasStaticcall) {
    const hasApprovedProviderSelector = approvedProviderSelectors.some((selector) => runtimeHex.includes(selector));
    if (!hasApprovedProviderSelector) {
      issues.push("STATICCALL without an approved provider selector");
    }
  }
  return issues;
}

/** @type {Array<[string, string]>} */
const production = [
  ["ERC1404Adapter.sol", "ERC1404Adapter"],
  ["OndoGmTokenAdapter.sol", "OndoGmTokenAdapter"],
  ["UnrestrictedERC20Adapter.sol", "UnrestrictedERC20Adapter"],
  ["UsdyRestrictedAdapter.sol", "UsdyRestrictedAdapter"],
];
/** @type {Array<[string, string, RegExp, boolean?]>} */
const malicious = [
  ["MaliciousAssetAdapters.sol", "ExtraSelectorAdapter", /unapproved external selector/],
  ["MaliciousAssetAdapters.sol", "FallbackAdapter", /fallback or receive entry point/],
  [
    "MaliciousAssetAdapters.sol",
    "StatefulAdapter",
    /has unapproved state mutability|forbidden opcode SLOAD|forbidden opcode SSTORE/,
  ],
  ["MaliciousAssetAdapters.sol", "DelegatecallAdapter", /forbidden opcode DELEGATECALL/],
  ["MaliciousAssetAdapters.sol", "TransferAdapter", /forbidden opcode CALL|forbidden embedded selector transfer/],
  ["MaliciousAssetAdapters.sol", "ArbitraryStaticcallAdapter", /STATICCALL without an approved provider selector/],
  ["MaliciousAssetAdapters.sol", "WrongReturnAbiAdapter", /has unapproved outputs/],
  ["MixedStaticcallAdapter.sol", "MixedStaticcallAdapter", /forbidden direct low-level call/, true],
];

let failed = false;
for (const [relativePath, expectedHash] of approvedSourceSha256) {
  const actualHash = sourceSha256(relativePath);
  if (actualHash !== expectedHash) {
    failed = true;
    console.error(`${relativePath}: source approval hash drifted (${actualHash})`);
  }
}

for (const [sourceName, contractName] of production) {
  const source = readFileSync(resolve(adaptersSourceRoot, sourceName), "utf8");
  const artifact = readArtifact(sourceName, contractName);
  const issues = [
    ...analyzeAdapterSource(source),
    ...analyze(artifact, providerSelectors[contractName] ?? []),
  ];
  if (contractName === "UsdyRestrictedAdapter") {
    const runtimeObject = artifact.deployedBytecode?.object;
    if (typeof runtimeObject === "string") {
      const runtime = executableRuntime(runtimeObject).toString("hex");
      if (runtime.includes("d4ce1415")) issues.push("USDY adapter embeds ERC-1404 selector");
    }
  } else if (contractName === "OndoGmTokenAdapter") {
    const runtimeObject = artifact.deployedBytecode?.object;
    if (typeof runtimeObject === "string") {
      const runtime = executableRuntime(runtimeObject).toString("hex");
      for (const selector of ["5c975abb", "2b47da52", "babcc539", "d4ce1415"]) {
        if (runtime.includes(selector)) issues.push(`Ondo GM adapter embeds unrelated selector ${selector}`);
      }
    }
  }
  if (issues.length === 0) {
    console.log(`${contractName}: approved`);
  } else {
    failed = true;
    console.error(`${contractName}: ${issues.join("; ")}`);
  }
}

for (const [sourceName, contractName, expectedIssue, checkSource] of malicious) {
  const issues = analyze(
    readArtifact(sourceName, contractName),
    providerSelectors[contractName] ?? [],
  );
  if (checkSource === true) {
    const source = readFileSync(resolve(fixturesSourceRoot, sourceName), "utf8");
    issues.push(...analyzeAdapterSource(source));
  }
  if (issues.some((issue) => expectedIssue.test(issue))) {
    console.log(`${contractName}: malicious fixture rejected`);
  } else {
    failed = true;
    console.error(`${contractName}: gate self-test failed (${issues.join("; ") || "accepted"})`);
  }
}

if (failed) process.exit(1);
console.log("Adapter bytecode gate passed");
