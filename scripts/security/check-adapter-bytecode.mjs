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
  ["adapters/ERC1404Adapter.sol", "3819fb43fc5903067c39b26b39d4b464b0c7b55298bb71121b67927db1cb1688"],
  [
    "adapters/UnrestrictedERC20Adapter.sol",
    "fa15e0e06c8b3a8b7ec45589ad6f88e9c44e85f7dbb66577ca23eb40850a5353",
  ],
  [
    "adapters/UsdyRestrictedAdapter.sol",
    "9b489f5e74f09b9e7589145acf0daae878d69c8a6ee3f7ec818a368dc01ef8e9",
  ],
  ["interfaces/IAssetAdapter.sol", "7244183db3d8a806a44e317fb3c8edd496e6a8b313786383b99068ca7d1e4b0a"],
  [
    "libraries/AdapterInputValidation.sol",
    "60c61c48a34d6a52304c58895d5d9e0788c0c2313312a8e6fb404d17a664d4fd",
  ],
  [
    "libraries/AdapterReasonCodes.sol",
    "62eb0ff6ad3a5993ddf3836ade8c18b4955bea38466aec94cb1304851448bc86",
  ],
  [
    "libraries/BoundedStaticCall.sol",
    "6825db924e19d162b22b9f10cc334b695209d84c742d88e596d66a5b5698e42f",
  ],
  [
    "libraries/RestrictionProviderLib.sol",
    "6e36ca845045ab6b62851acf0f24ea17db17ddc493388b632a04ce2869d49153",
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
