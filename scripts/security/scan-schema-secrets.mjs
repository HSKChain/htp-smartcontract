import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

const repositoryRoot = resolve(new URL("../..", import.meta.url).pathname);
const scanRoots = [
  resolve(repositoryRoot, "schema/v1"),
  resolve(repositoryRoot, "schema/off-chain"),
];

const forbiddenKey =
  /^(privateKey|secretKey|mnemonic|seedPhrase|kmsKeyId|rawTransaction|rawSignature|quotingMakerSignature|requesterSignature|customerEmail|customerPhone|email|phone|mobile|ssn|passportNumber)$/iu;
const forbiddenValue = [
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/u,
  /\barn:aws:kms:[a-z0-9-]+:\d{12}:key\/[0-9a-f-]{36}\b/iu,
  /\bprojects\/[^/\s]+\/locations\/[^/\s]+\/keyRings\/[^/\s]+\/cryptoKeys\/[^/\s]+/iu,
  /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/iu,
];

/** @param {unknown} value @param {string} [path] @returns {string[]} */
function inspect(value, path = "$") {
  /** @type {string[]} */
  const findings = [];
  if (Array.isArray(value)) {
    value.forEach((nested, index) => findings.push(...inspect(nested, `${path}[${index}]`)));
    return findings;
  }
  if (value !== null && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      if (forbiddenKey.test(key) && nested !== null && nested !== "" && nested !== "intentionally omitted") {
        findings.push(`${path}.${key}: forbidden sensitive field`);
      }
      findings.push(...inspect(nested, `${path}.${key}`));
    }
    return findings;
  }
  if (typeof value === "string") {
    for (const pattern of forbiddenValue) {
      if (pattern.test(value)) findings.push(`${path}: sensitive value pattern`);
    }
  }
  return findings;
}

/** @param {string} directory @returns {string[]} */
function listJson(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? listJson(path) : entry.name.endsWith(".json") ? [path] : [];
  });
}

function selfTest() {
  const legal = {
    typeHash: `0x${"ab".repeat(32)}`,
    topic0: `0x${"cd".repeat(32)}`,
    address: "0x1234567890abcdef1234567890abcdef12345678",
    selector: "0x12345678",
  };
  if (inspect(legal).length !== 0) throw new Error("self-test rejected legal bytes32/address/selector values");
  const forbidden = [
    { privateKey: `0x${"11".repeat(32)}` },
    { value: "-----BEGIN PRIVATE KEY-----" },
    { kmsKeyId: "production-key" },
    { customerEmail: "person@example.com" },
  ];
  for (const fixture of forbidden) {
    if (inspect(fixture).length === 0) throw new Error(`self-test missed ${JSON.stringify(fixture)}`);
  }
  console.log("Schema secret scan self-test passed");
}

if (process.argv.includes("--self-test")) {
  selfTest();
} else {
  const findings = scanRoots.filter((scanRoot) => existsSync(scanRoot)).flatMap((scanRoot) =>
    listJson(scanRoot).flatMap((path) => {
      const value = JSON.parse(readFileSync(path, "utf8"));
      return inspect(value).map((finding) => `${path.replace(`${repositoryRoot}/`, "")}: ${finding}`);
    }),
  );
  if (findings.length !== 0) {
    console.error(findings.join("\n"));
    process.exit(1);
  }
  console.log("Schema/ABI/vector secret scan passed");
}
