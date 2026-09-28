import {readFileSync} from "node:fs";
import {resolve} from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "../..");
const contractsOut = resolve(repositoryRoot, "contracts/out");
const approvedMethods = new Map([
  ["assetClass()", "86c9de05"],
  ["calculate(bytes,uint256,uint8)", "50a466c1"],
  ["interfaceVersion()", "1d8ffa4d"],
]);

const forbiddenOpcodes = new Map([
  [0x31, "BALANCE"],
  [0x32, "ORIGIN"],
  [0x3a, "GASPRICE"],
  [0x3b, "EXTCODESIZE"],
  [0x3c, "EXTCODECOPY"],
  [0x3f, "EXTCODEHASH"],
  [0x40, "BLOCKHASH"],
  [0x41, "COINBASE"],
  [0x42, "TIMESTAMP"],
  [0x43, "NUMBER"],
  [0x44, "PREVRANDAO"],
  [0x45, "GASLIMIT"],
  [0x46, "CHAINID"],
  [0x47, "SELFBALANCE"],
  [0x48, "BASEFEE"],
  [0x49, "BLOBHASH"],
  [0x4a, "BLOBBASEFEE"],
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
  [0xfa, "STATICCALL"],
  [0xff, "SELFDESTRUCT"],
]);

/**
 * @typedef {{
 *   abi?: Array<{type?: string}>,
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
 * Solidity appends CBOR metadata followed by its two-byte length. Metadata is
 * not executable code and must not be interpreted as opcodes.
 *
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
 * @param {FoundryArtifact} artifact
 * @returns {string[]}
 */
function analyze(artifact) {
  const issues = [];
  for (const entry of artifact.abi ?? []) {
    if (entry.type === "fallback" || entry.type === "receive") {
      issues.push(`unapproved ${entry.type} or receive entry point`);
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
  for (let offset = 0; offset < runtime.length; offset += 1) {
    const opcode = runtime[offset];
    const forbidden = forbiddenOpcodes.get(opcode);
    if (forbidden !== undefined) discovered.add(forbidden);
    if (opcode >= 0x60 && opcode <= 0x7f) {
      offset += opcode - 0x5f;
    }
  }
  for (const opcode of [...discovered].sort()) {
    issues.push(`forbidden opcode ${opcode}`);
  }
  return issues;
}

/** @type {[string, string][]} */
const production = [
  ["FundPrincipalCalculator.sol", "FundPrincipalCalculator"],
  ["StockPrincipalCalculator.sol", "StockPrincipalCalculator"],
  ["BondPrincipalCalculator.sol", "BondPrincipalCalculator"],
];
/** @type {[string, RegExp][]} */
const malicious = [
  ["ExtraSelectorCalculator", /unapproved external selector/],
  ["FallbackCalculator", /fallback or receive entry point/],
  ["StatefulCalculator", /forbidden opcode SLOAD|forbidden opcode SSTORE/],
  ["DelegatecallCalculator", /forbidden opcode DELEGATECALL/],
  ["ExternalReadCalculator", /forbidden opcode STATICCALL/],
  ["BlockEnvironmentCalculator", /forbidden opcode NUMBER|forbidden opcode TIMESTAMP/],
];

let failed = false;
for (const [sourceName, contractName] of production) {
  const issues = analyze(readArtifact(sourceName, contractName));
  if (issues.length === 0) {
    console.log(`${contractName}: approved`);
  } else {
    failed = true;
    console.error(`${contractName}: ${issues.join("; ")}`);
  }
}

for (const [contractName, expectedIssue] of malicious) {
  const issues = analyze(readArtifact("MaliciousPrincipalCalculators.sol", contractName));
  if (issues.some((issue) => expectedIssue.test(issue))) {
    console.log(`${contractName}: malicious fixture rejected`);
  } else {
    failed = true;
    console.error(`${contractName}: gate self-test failed (${issues.join("; ") || "accepted"})`);
  }
}

if (failed) process.exit(1);
console.log("Calculator bytecode gate passed");
