import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, relative, resolve } from "node:path";
import { encodeAbiParameters, keccak256, toHex } from "viem";

/**
 * @typedef {{
 *   namespace: string,
 *   source: string,
 *   struct: string,
 *   slot: string,
 *   members: Array<{label: string, type: string}>
 * }} RegistryNamespaceLayout
 * @typedef {{schemaVersion: number, layouts: RegistryNamespaceLayout[]}} RegistryLayoutBaseline
 */

const repositoryRoot = resolve(import.meta.dirname, "../..");
const registrySourceRoot = resolve(repositoryRoot, "contracts/src/registry");
const buildInfoRoot = resolve(repositoryRoot, "contracts/out/build-info");
const baselinePath = resolve(
  repositoryRoot,
  "security/registry-storage/layout-baseline.json",
);
const upgradesCli = resolve(repositoryRoot, "node_modules/.bin/openzeppelin-upgrades-core");
const selfTest = process.argv.includes("--self-test");
const printLayout = process.argv.includes("--print-layout");

/**
 * @param {string} directory
 * @returns {string[]}
 */
function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? listFiles(path) : [path];
  });
}

/**
 * @param {string} namespace
 * @returns {string}
 */
function erc7201Slot(namespace) {
  const namespaceHash = BigInt(keccak256(toHex(namespace)));
  const encoded = encodeAbiParameters([{ type: "uint256" }], [namespaceHash - 1n]);
  return toHex(BigInt(keccak256(encoded)) & ~0xffn, { size: 32 });
}

/**
 * @param {unknown} documentation
 * @returns {string}
 */
function documentationText(documentation) {
  if (typeof documentation === "string") return documentation;
  if (documentation !== null && typeof documentation === "object") {
    const candidate = /** @type {{text?: unknown}} */ (documentation);
    return typeof candidate.text === "string" ? candidate.text : "";
  }
  return "";
}

/**
 * @param {unknown} node
 * @param {(node: any) => void} visit
 */
function walk(node, visit) {
  if (node === null || typeof node !== "object") return;
  visit(node);
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) {
      for (const child of value) walk(child, visit);
    } else {
      walk(value, visit);
    }
  }
}

/**
 * @returns {{registryAsts: Map<string, any>, allAsts: Map<string, any>}}
 */
function loadRegistryAsts() {
  /** @type {Map<string, any>} */
  const registryAsts = new Map();
  /** @type {Map<string, any>} */
  const allAsts = new Map();
  for (const path of listFiles(buildInfoRoot).filter((file) => file.endsWith(".json"))) {
    /** @type {any} */
    const buildInfo = JSON.parse(readFileSync(path, "utf8"));
    for (const [sourceName, sourceOutput] of Object.entries(buildInfo.output?.sources ?? {})) {
      if (sourceOutput?.ast !== undefined) allAsts.set(sourceName, sourceOutput.ast);
      if (sourceName.startsWith("src/registry/") && sourceOutput?.ast !== undefined) {
        registryAsts.set(sourceName, sourceOutput.ast);
      }
    }
  }
  if (registryAsts.size === 0) {
    throw new Error("No compiled Registry AST found; run a clean Forge build first.");
  }
  return { registryAsts, allAsts };
}

/**
 * @param {any} typeName
 * @param {Map<number, any>} structsById
 * @param {Set<number>} [activeStructs]
 * @returns {string}
 */
function canonicalType(typeName, structsById, activeStructs = new Set()) {
  if (typeName?.nodeType === "Mapping") {
    return `mapping(${canonicalType(typeName.keyType, structsById, activeStructs)}=>${canonicalType(
      typeName.valueType,
      structsById,
      activeStructs,
    )})`;
  }
  if (typeName?.nodeType === "ArrayTypeName") {
    const length = typeName.length?.value ?? "";
    return `${canonicalType(typeName.baseType, structsById, activeStructs)}[${length}]`;
  }
  if (typeName?.nodeType === "UserDefinedTypeName") {
    const struct = structsById.get(typeName.referencedDeclaration);
    if (struct === undefined) return typeName.typeDescriptions?.typeString ?? "unknown";
    if (activeStructs.has(struct.id)) return `struct-ref ${struct.name}`;

    const nested = new Set(activeStructs);
    nested.add(struct.id);
    const members = struct.members
      .map(
        (/** @type {any} */ member) =>
          `${member.name}:${canonicalType(member.typeName, structsById, nested)}`,
      )
      .join(";");
    return `struct ${struct.name}{${members}}`;
  }
  return typeName?.typeDescriptions?.typeString ?? typeName?.name ?? "unknown";
}

/**
 * @param {Map<string, any>} asts
 * @param {Map<string, any>} typeAsts
 * @returns {RegistryLayoutBaseline}
 */
function collectRegistryLayout(asts, typeAsts) {
  /** @type {Map<number, any>} */
  const structsById = new Map();
  for (const ast of typeAsts.values()) {
    walk(ast, (node) => {
      if (node.nodeType === "StructDefinition") structsById.set(node.id, node);
    });
  }

  /** @type {RegistryNamespaceLayout[]} */
  const layouts = [];
  for (const [sourceName, ast] of asts) {
    walk(ast, (node) => {
      if (node.nodeType !== "StructDefinition") return;
      const match = documentationText(node.documentation).match(
        /@custom:storage-location\s+erc7201:([^\s]+)/u,
      );
      if (match === null || !match[1].startsWith("htp.storage.")) return;
      layouts.push({
        namespace: match[1],
        source: sourceName,
        struct: node.name,
        slot: erc7201Slot(match[1]),
        members: node.members.map((/** @type {any} */ member) => ({
          label: member.name,
          type: canonicalType(member.typeName, structsById),
        })),
      });
    });
  }
  layouts.sort((left, right) => left.namespace.localeCompare(right.namespace));
  return { schemaVersion: 1, layouts };
}

/**
 * @param {ReturnType<typeof collectRegistryLayout>} baseline
 * @param {ReturnType<typeof collectRegistryLayout>} current
 * @returns {string[]}
 */
function compareRegistryLayout(baseline, current) {
  const issues = [];
  if (baseline.schemaVersion !== 1 || current.schemaVersion !== 1) {
    issues.push("unsupported Registry storage baseline schema version");
  }
  const baselineNamespaces = new Set(
    baseline.layouts.map((layout) => layout.namespace),
  );
  const currentByNamespace = new Map(
    current.layouts.map((layout) => [layout.namespace, layout]),
  );
  for (const actual of current.layouts) {
    if (!baselineNamespaces.has(actual.namespace)) {
      issues.push(`namespace ${actual.namespace} has no reviewed storage baseline`);
    }
  }
  for (const expected of baseline.layouts) {
    const actual = currentByNamespace.get(expected.namespace);
    if (actual === undefined) {
      issues.push(`baseline namespace ${expected.namespace} was removed`);
      continue;
    }
    if (actual.slot !== expected.slot) {
      issues.push(
        `${expected.namespace}: slot changed from ${expected.slot} to ${actual.slot}`,
      );
    }
    if (actual.struct !== expected.struct) {
      issues.push(
        `${expected.namespace}: struct changed from ${expected.struct} to ${actual.struct}`,
      );
    }
    if (actual.members.length < expected.members.length) {
      issues.push(`${expected.namespace}: storage members were removed`);
      continue;
    }
    for (let index = 0; index < expected.members.length; ++index) {
      const expectedMember = expected.members[index];
      const actualMember = actual.members[index];
      if (
        actualMember.label !== expectedMember.label ||
        actualMember.type !== expectedMember.type
      ) {
        issues.push(
          `${expected.namespace}: member ${index} changed from ${expectedMember.label}:${expectedMember.type} to ${actualMember.label}:${actualMember.type}`,
        );
      }
    }
  }
  return issues;
}

/**
 * @param {Map<string, any>} asts
 * @param {Map<string, string>} sourceByName
 * @returns {string[]}
 */
function analyzeRegistryStorage(asts, sourceByName) {
  /** @type {string[]} */
  const issues = [];
  /** @type {Map<string, string>} */
  const namespaces = new Map();

  for (const [sourceName, ast] of asts) {
    walk(ast, (node) => {
      if (node.nodeType === "VariableDeclaration" && node.stateVariable === true) {
        const mutable = node.constant !== true && node.mutability !== "immutable";
        if (mutable) {
          issues.push(`${sourceName}: mutable state variable ${node.name} is outside ERC-7201 storage`);
        }
        if (node.name === "__gap") {
          issues.push(`${sourceName}: traditional __gap storage is forbidden`);
        }
      }

      if (node.nodeType !== "StructDefinition") return;
      const documentation = documentationText(node.documentation);
      const match = documentation.match(/@custom:storage-location\s+erc7201:([^\s]+)/u);
      if (match === null) return;

      const namespace = match[1];
      const previous = namespaces.get(namespace);
      if (previous !== undefined) {
        issues.push(
          `${sourceName}: duplicate ERC-7201 namespace ${namespace}; first declared in ${previous}`,
        );
      } else {
        namespaces.set(namespace, sourceName);
      }

      const source = sourceByName.get(sourceName) ?? "";
      const expectedSlot = erc7201Slot(namespace);
      const slotDeclaration = new RegExp(
        `bytes32\\s+private\\s+constant\\s+[A-Z0-9_]*STORAGE_LOCATION\\s*=\\s*${expectedSlot}`,
        "u",
      );
      if (!slotDeclaration.test(source)) {
        issues.push(`${sourceName}: missing independently derived slot ${expectedSlot} for ${namespace}`);
      }
    });
  }

  if (!namespaces.has("htp.storage.UUPSRegistryBase")) {
    issues.push("missing ERC-7201 namespace htp.storage.UUPSRegistryBase");
  }

  return issues;
}

/**
 * @param {string[]} [extraArguments]
 * @returns {string}
 */
function runOpenZeppelinValidation(extraArguments = []) {
  const candidates = listFiles(buildInfoRoot)
    .filter((path) => path.endsWith(".json"))
    .map((path) => ({ path, buildInfo: JSON.parse(readFileSync(path, "utf8")) }))
    .filter(({ buildInfo }) => {
      const contracts = buildInfo.output?.contracts ?? {};
      return (
        registrySources.every((path) => contracts[relative(resolve(repositoryRoot, "contracts"), path).replaceAll("\\", "/")])
        && contracts["test/fixtures/RegistryStorageCompatibilityFixtures.sol"]
      );
    })
    .sort((left, right) => {
      /** @param {{ buildInfo: any }} candidate */
      const count = (candidate) =>
        Object.values(candidate.buildInfo.output?.contracts ?? {})
          .reduce((total, contracts) => total + Object.keys(contracts).length, 0);
      return count(right) - count(left) || left.path.localeCompare(right.path);
    });
  if (candidates.length === 0) {
    throw new Error("No single build-info file contains all Registry and compatibility contracts.");
  }

  const uniqueBuildInfoRoot = mkdtempSync(resolve(tmpdir(), "htp-upgrades-build-info-"));
  try {
    copyFileSync(candidates[0].path, resolve(uniqueBuildInfoRoot, basename(candidates[0].path)));
    return execFileSync(upgradesCli, ["validate", uniqueBuildInfoRoot, ...extraArguments], {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } finally {
    rmSync(uniqueBuildInfoRoot, { recursive: true, force: true });
  }
}

const registrySources = listFiles(registrySourceRoot).filter((path) => path.endsWith(".sol"));
const sourceByName = new Map(
  registrySources.map((path) => [
    relative(resolve(repositoryRoot, "contracts"), path).replaceAll("\\", "/"),
    readFileSync(path, "utf8"),
  ]),
);
const { registryAsts: asts, allAsts } = loadRegistryAsts();
const issues = analyzeRegistryStorage(asts, sourceByName);
const currentLayout = collectRegistryLayout(asts, allAsts);

if (printLayout) {
  console.log(JSON.stringify(currentLayout, null, 2));
  process.exit(0);
}

/** @type {ReturnType<typeof collectRegistryLayout>} */
const baselineLayout = JSON.parse(readFileSync(baselinePath, "utf8"));
issues.push(...compareRegistryLayout(baselineLayout, currentLayout));

if (selfTest) {
  const duplicated = new Map(asts);
  const firstAst = asts.entries().next().value;
  if (firstAst === undefined) {
    throw new Error("Registry storage self-test requires at least one Registry AST.");
  }
  const [sourceName, ast] = firstAst;
  duplicated.set(`${sourceName}.duplicate`, ast);
  const duplicateSources = new Map(sourceByName);
  duplicateSources.set(`${sourceName}.duplicate`, sourceByName.get(sourceName) ?? "");
  const mutationIssues = analyzeRegistryStorage(duplicated, duplicateSources);
  if (!mutationIssues.some((issue) => issue.includes("duplicate ERC-7201 namespace"))) {
    throw new Error("Registry storage self-test failed to detect a duplicate namespace.");
  }

  const mutatedBaseline = structuredClone(baselineLayout);
  mutatedBaseline.layouts[0].members[0].type = "uint256";
  if (compareRegistryLayout(mutatedBaseline, currentLayout).length === 0) {
    throw new Error("Registry storage self-test failed to detect baseline drift.");
  }
  const incompleteBaseline = structuredClone(baselineLayout);
  incompleteBaseline.layouts.pop();
  if (
    !compareRegistryLayout(incompleteBaseline, currentLayout).some((issue) =>
      issue.includes("has no reviewed storage baseline"),
    )
  ) {
    throw new Error("Registry storage self-test failed to detect an unbaselined namespace.");
  }

  let incompatibleRejected = false;
  try {
    runOpenZeppelinValidation([
      "--contract",
      "test/fixtures/RegistryStorageCompatibilityFixtures.sol:RegistryStorageIncompatibleV2",
      "--reference",
      "test/fixtures/RegistryStorageCompatibilityFixtures.sol:RegistryStorageCompatibilityV1",
    ]);
  } catch (error) {
    const failure =
      /** @type {{stdout?: string, stderr?: string, status?: number}} */ (error);
    const output = `${failure.stdout ?? ""}${failure.stderr ?? ""}`;
    incompatibleRejected =
      failure.status === 1 &&
      output.includes("Deleted `value`") &&
      output.includes("Inserted `value`") &&
      output.includes("FAILED");
  }
  if (!incompatibleRejected) {
    throw new Error("Registry storage self-test failed to reject an incompatible upgrade.");
  }

  console.log(
    "Registry storage self-test passed (duplicate/unbaselined namespace, baseline drift, and incompatible upgrade rejected).",
  );
  process.exit(0);
}

if (issues.length > 0) {
  console.error("Registry storage safety gate failed:");
  for (const issue of issues) console.error(`- ${issue}`);
  process.exit(1);
}

const upgradesResult = runOpenZeppelinValidation();
const compatibilityResult = runOpenZeppelinValidation([
  "--contract",
  "test/fixtures/RegistryStorageCompatibilityFixtures.sol:RegistryStorageCompatibilityV2",
  "--reference",
  "test/fixtures/RegistryStorageCompatibilityFixtures.sol:RegistryStorageCompatibilityV1",
]);
console.log(upgradesResult);
console.log(compatibilityResult);
console.log(
  `Registry storage safety gate passed (${asts.size} Registry source ASTs, ${currentLayout.layouts.length} baselined namespaces).`,
);
