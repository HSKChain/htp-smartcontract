import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const excludedDirectories = new Set([
  ".git",
  "node_modules",
  "contracts/lib",
  "contracts/out",
  "contracts/cache",
  "contracts/broadcast",
  "contracts/coverage",
  "coverage",
  "deploy/out",
]);
const acceptedCanaryFindings = new Map([
  [
    "scripts/deploy/validate-config.test.mjs",
    new Set(["PEM private key", "AWS KMS key ARN"]),
  ],
  ["scripts/security/scan-schema-secrets.mjs", new Set(["PEM private key"])],
]);
const approvedBinaryDigests = new Map([
  [
    "03-HTP链上DvP合约_PRD_V3.2.pdf",
    "cc6bdc2107b98c2f65b4afd8265a7abf9881c71f53462483495e9abda289179a",
  ],
]);
const allowedEmailDomains = new Set(["example.com", "example.org", "example.net"]);

/** @param {string} path */
function normalizedRelative(path) {
  return relative(repositoryRoot, path).split(sep).join("/");
}

/** @param {string} relativePath */
function isExcludedDirectory(relativePath) {
  const segments = relativePath.split("/");
  return (
    segments.includes(".git") ||
    segments.includes("node_modules") ||
    segments.includes(".venv") ||
    segments.includes("__pycache__") ||
    [...excludedDirectories].some(
      (excluded) => relativePath === excluded || relativePath.startsWith(`${excluded}/`),
    )
  );
}

/** @param {string} directory @param {string[]} [files] */
function collectFiles(directory, files = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    const relativePath = normalizedRelative(path);
    if (entry.isDirectory()) {
      if (!isExcludedDirectory(relativePath)) collectFiles(path, files);
      continue;
    }
    if (entry.isFile()) files.push(path);
  }
  return files;
}

/** @param {string} relativePath */
function pathFindings(relativePath) {
  const basename = relativePath.split("/").at(-1)?.toLowerCase() ?? "";
  const segments = relativePath.toLowerCase().split("/");
  const findings = [];
  if (basename.startsWith(".env") && basename !== ".env.example") findings.push("forbidden .env file");
  if ([".pem", ".key", ".p12", ".pfx"].includes(extname(basename))) findings.push("private-key container");
  if (["credentials.json", "service-account.json"].includes(basename)) findings.push("credential file");
  if (segments.includes("secrets")) findings.push("secrets directory");
  return findings;
}

/** @param {string} content */
export function contentFindings(content) {
  const findings = [];
  /** @type {Array<[string, RegExp]>} */
  const patterns = [
    ["PEM private key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/u],
    ["AWS access key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/u],
    ["AWS KMS key ARN", /\barn:aws:kms:[a-z0-9-]+:\d{12}:key\/[0-9a-f-]{36}\b/iu],
    [
      "GCP KMS key",
      /\bprojects\/[^/\s]+\/locations\/[^/\s]+\/keyRings\/[^/\s]+\/cryptoKeys\/[^/\s]+\b/iu,
    ],
    [
      "private key assignment",
      /\b(?:PRIVATE_KEY|privateKey)\b\s*[:=]\s*["']?(?:0x)?[0-9a-f]{64}["']?/iu,
    ],
    [
      "plaintext raw transaction",
      /"(?:rawTransaction|signedRawTransaction|rawTx|rawSignature|quotingMakerSignature|requesterSignature)"\s*:\s*"0x[0-9a-f]{64,}"/iu,
    ],
    [
      "credential-bearing URI",
      /\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis):\/\/[^:\s/@]+:[^@\s/]+@/iu,
    ],
  ];
  for (const [label, pattern] of patterns) {
    if (pattern.test(content)) findings.push(label);
  }

  const emailPattern = /\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b/giu;
  for (const match of content.matchAll(emailPattern)) {
    const domain = match[1]?.toLowerCase();
    if (domain && !allowedEmailDomains.has(domain) && !domain.endsWith(".invalid")) {
      findings.push(`email address (${domain})`);
    }
  }
  return [...new Set(findings)];
}

function runSelfTest() {
  const key = "11".repeat(32);
  const kmsArn = ["arn", "aws", "kms"].join(":") + ":ap-southeast-1:123456789012:key/" +
    "12345678-1234-1234-1234-123456789012";
  const findings = contentFindings(
    [`PRIVATE_KEY=0x${key}`, kmsArn, '"rawTransaction":"0x' + "ab".repeat(64) + '"'].join("\n"),
  );
  for (const expected of ["private key assignment", "AWS KMS key ARN", "plaintext raw transaction"]) {
    if (!findings.includes(expected)) throw new Error(`Repository scan self-test missed ${expected}`);
  }
  if (contentFindings("security@example.com").length !== 0) {
    throw new Error("Repository scan self-test rejected an example email");
  }

  const temporaryRoot = mkdtempSync(resolve(tmpdir(), "htp-secret-scan-self-test-"));
  try {
    mkdirSync(resolve(temporaryRoot, "visible"), { recursive: true });
    mkdirSync(resolve(temporaryRoot, "node_modules", "hidden"), { recursive: true });
    writeFileSync(resolve(temporaryRoot, "visible", "checked.txt"), "checked");
    writeFileSync(resolve(temporaryRoot, "node_modules", "hidden", "ignored.txt"), "ignored");
    const collected = collectFiles(temporaryRoot).map((path) => relative(temporaryRoot, path));
    if (
      !collected.includes("visible/checked.txt") ||
      collected.some((path) => path.includes("node_modules"))
    ) {
      throw new Error("Repository traversal self-test failed");
    }
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
  console.log("Repository secret/PII scan self-test passed.");
}

function main() {
  if (process.argv.includes("--self-test")) {
    runSelfTest();
    return;
  }

  const findings = [];
  const seenCanaries = new Map(
    [...acceptedCanaryFindings].map(([path]) => [path, new Set()]),
  );
  const seenApprovedBinaries = new Set();
  for (const path of collectFiles(repositoryRoot)) {
    const relativePath = normalizedRelative(path);
    for (const finding of pathFindings(relativePath)) findings.push(`${relativePath}: ${finding}`);
    const bytes = readFileSync(path);
    if (bytes.includes(0)) {
      const digest = createHash("sha256").update(bytes).digest("hex");
      const approvedDigest = approvedBinaryDigests.get(relativePath);
      if (approvedDigest !== digest) {
        findings.push(`${relativePath}: unapproved binary sha256=${digest}`);
      } else {
        seenApprovedBinaries.add(relativePath);
      }
      continue;
    }
    const content = bytes.toString("utf8");
    for (const finding of contentFindings(content)) {
      const accepted = acceptedCanaryFindings.get(relativePath);
      if (accepted?.has(finding)) {
        seenCanaries.get(relativePath)?.add(finding);
      } else {
        findings.push(`${relativePath}: ${finding}`);
      }
    }
  }
  for (const [path, expected] of acceptedCanaryFindings) {
    const seen = seenCanaries.get(path) ?? new Set();
    for (const finding of expected) {
      if (!seen.has(finding)) findings.push(`${path}: stale accepted canary ${finding}`);
    }
  }
  for (const path of approvedBinaryDigests.keys()) {
    if (!seenApprovedBinaries.has(path)) findings.push(`${path}: approved binary baseline missing`);
  }

  if (findings.length > 0) {
    throw new Error(`Repository secret/PII scan failed:\n${findings.sort().join("\n")}`);
  }
  console.log("Repository secret/PII scan passed.");
}

main();

