import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const acceptedCanaryFindings = new Map([
  [
    "scripts/deploy/validate-config.test.mjs",
    new Set(["PEM private key", "AWS KMS key ARN"]),
  ],
  ["scripts/security/scan-schema-secrets.mjs", new Set(["PEM private key"])],
]);
const approvedBinaryDigests = new Map();
const allowedEmailDomains = new Set(["example.com", "example.org", "example.net"]);

/** @param {string} path */
function normalizedRelative(path) {
  return relative(repositoryRoot, path).split(sep).join("/");
}

/**
 * 扫描所有 tracked 和可提交的 untracked 文件；ignored 本地密钥不属于仓库内容。
 * @param {string} root
 */
function collectRepositoryFiles(root) {
  const output = execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    { cwd: root, encoding: "utf8" },
  );
  return output
    .split("\0")
    .filter(Boolean)
    .map((path) => resolve(root, path))
    .filter((path) => existsSync(path) && lstatSync(path).isFile());
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
      /\b(?:PRIVATE_KEY|privateKey|HTP_[A-Z0-9_]*_KEY)\b\s*[:=]\s*["']?(?:0x)?[0-9a-f]{64}["']?/iu,
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
  if (!contentFindings(`HTP_DEPLOYER_KEY=0x${key}`).includes("private key assignment")) {
    throw new Error("Repository scan self-test missed HTP private key assignment");
  }
  if (contentFindings("security@example.com").length !== 0) {
    throw new Error("Repository scan self-test rejected an example email");
  }

  const temporaryRoot = mkdtempSync(resolve(tmpdir(), "htp-secret-scan-self-test-"));
  try {
    mkdirSync(resolve(temporaryRoot, "visible"), { recursive: true });
    mkdirSync(resolve(temporaryRoot, "ignored"), { recursive: true });
    writeFileSync(resolve(temporaryRoot, ".gitignore"), "ignored/\n");
    writeFileSync(resolve(temporaryRoot, "visible", "checked.txt"), "checked");
    writeFileSync(resolve(temporaryRoot, "ignored", "local.env"), "ignored");
    writeFileSync(resolve(temporaryRoot, "ignored", "forced.env"), "forced");
    execFileSync("git", ["init", "--quiet"], { cwd: temporaryRoot });
    execFileSync("git", ["add", "--force", "ignored/forced.env"], { cwd: temporaryRoot });
    const collected = collectRepositoryFiles(temporaryRoot).map((path) => relative(temporaryRoot, path));
    if (
      !collected.includes("visible/checked.txt") ||
      !collected.includes("ignored/forced.env") ||
      collected.includes("ignored/local.env")
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
  for (const path of collectRepositoryFiles(repositoryRoot)) {
    const relativePath = normalizedRelative(path);
    for (const finding of pathFindings(relativePath)) findings.push(`${relativePath}: ${finding}`);
    const bytes = readFileSync(path);
    const approvedDigest = approvedBinaryDigests.get(relativePath);
    if (approvedDigest !== undefined) {
      const digest = createHash("sha256").update(bytes).digest("hex");
      if (approvedDigest !== digest) {
        findings.push(`${relativePath}: unapproved binary sha256=${digest}`);
      } else {
        seenApprovedBinaries.add(relativePath);
      }
      continue;
    }
    if (bytes.includes(0)) {
      const digest = createHash("sha256").update(bytes).digest("hex");
      findings.push(`${relativePath}: unapproved binary sha256=${digest}`);
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

