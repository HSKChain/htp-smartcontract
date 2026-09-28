import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { keccak256, stringToHex } from "viem";

import { hashSourceTree, selectProductionBuildInfo } from "./build-info.js";
import { canonicalJson, sha256Hex, type JsonObject } from "./json.js";
import { buildSchemaModel, type SchemaModel } from "./model.js";
import {
  PROTOCOL_OPTIONAL_FILES,
  SCHEMA_DOCUMENT_PATHS,
  SCHEMA_V1_OPTIONAL_ROOT_ENTRIES,
  SCHEMA_V1_ROOT_ENTRIES,
  STALE_SCHEMA_V1_ROOT_ENTRIES,
} from "./paths.js";

export interface SchemaBundle {
  manifest: JsonObject;
  abis: Record<string, unknown[]>;
  documents: Record<string, JsonObject>;
}

export { canonicalJson };

function canonicalAbiType(input: any): string {
  if (typeof input?.type !== "string") throw new Error("Malformed ABI input.");
  if (!input.type.startsWith("tuple")) return input.type;
  const suffix = input.type.slice("tuple".length);
  return `(${(input.components ?? []).map(canonicalAbiType).join(",")})${suffix}`;
}

function signature(entry: any): string {
  return `${entry.name}(${(entry.inputs ?? []).map(canonicalAbiType).join(",")})`;
}

function extractErrorsAndEvents(buildInfo: any): { errors: JsonObject; events: JsonObject } {
  const errors = new Map<string, any>();
  const events = new Map<string, any>();
  for (const [sourceName, contracts] of Object.entries(buildInfo.output?.contracts ?? {}) as Array<
    [string, Record<string, { abi?: any[] }>]
  >) {
    if (!sourceName.startsWith("src/")) continue;
    for (const artifact of Object.values(contracts)) {
      if (!Array.isArray(artifact.abi)) continue;
      for (const entry of artifact.abi) {
        if (entry.type !== "error" && entry.type !== "event") continue;
        const canonicalSignature = signature(entry);
        const target = entry.type === "error" ? errors : events;
        if (!target.has(canonicalSignature)) {
          const hash = keccak256(stringToHex(canonicalSignature));
          target.set(canonicalSignature, {
            name: entry.name,
            signature: canonicalSignature,
            ...(entry.type === "error" ? { selector: hash.slice(0, 10) } : { topic0: hash }),
            inputs: entry.inputs ?? [],
            ...(entry.type === "event" ? { anonymous: entry.anonymous === true } : {}),
            sources: [sourceName],
          });
        } else {
          const existing = target.get(canonicalSignature);
          if (!existing.sources.includes(sourceName)) {
            existing.sources.push(sourceName);
            existing.sources.sort();
          }
        }
      }
    }
  }
  const ordered = (values: Map<string, any>) =>
    Array.from(values.values()).sort((left, right) => left.signature.localeCompare(right.signature));
  return {
    errors: {
      schemaVersion: 1,
      generatedFrom:
        "compiled production ABI (contracts/src targets only; inherited dependency ABI retained)",
      errors: ordered(errors),
    },
    events: {
      schemaVersion: 1,
      generatedFrom:
        "compiled production ABI (contracts/src targets only; inherited dependency ABI retained)",
      events: ordered(events),
    },
  };
}

function enumDocument(model: SchemaModel): JsonObject {
  return {
    schemaVersion: 1,
    generatedFrom: "contracts/src/types/HTPTypes.sol AST",
    enums: Object.entries(model.enums).map(([name, members]) => ({
      name,
      ownership: {
        canonicalDefinition: "onchain",
        consumers: ["onchain", "offchain"],
      },
      members,
      deprecatedAliases: [],
    })),
  };
}

const EIP712_CONSTANTS = [
  "EIP712_DOMAIN_TYPEHASH",
  "FIRM_QUOTE_TYPEHASH",
  "TRADE_INTENT_TYPEHASH",
  "NONCE_CANCELLATION_TYPEHASH",
  "TRADE_TERMS_SNAPSHOT_TYPEHASH",
] as const;

const CONFIG_CONSTANTS = [
  "STOCK_PRICE_TERMS_TYPEHASH",
  "FUND_PRICE_TERMS_TYPEHASH",
  "BOND_PRICE_TERMS_TYPEHASH",
  "ASSET_VERSION_CONFIG_TYPEHASH",
  "SETTLEMENT_TOKEN_CONFIG_TYPEHASH",
  "ADAPTER_CAPABILITIES_TYPEHASH",
  "RESTRICTION_PROVIDER_TYPEHASH",
  "RESTRICTION_PROVIDER_SET_TYPEHASH",
  "ADAPTER_CONFIG_TYPEHASH",
  "PRINCIPAL_CALCULATOR_CONFIG_TYPEHASH",
  "MARKET_RULE_CONFIG_TYPEHASH",
  "FEE_CONSTRAINT_TYPEHASH",
  "FEE_POLICY_EPOCH_CONFIG_TYPEHASH",
  "FEE_CONFIG_TYPEHASH",
] as const;

const REQUIRED_CONFIG_NAMESPACES = [
  "FEE_NAMESPACE",
  "SETTLEMENT_TOKEN_NAMESPACE",
  "ADAPTER_NAMESPACE",
  "PRINCIPAL_CALCULATOR_NAMESPACE",
  "MARKET_RULE_NAMESPACE",
] as const;

function assertTypehashInventory(model: SchemaModel): void {
  const actual = Object.keys(model.typehashes).sort();
  const expected = [...EIP712_CONSTANTS, ...CONFIG_CONSTANTS].sort();
  if (canonicalJson(actual) !== canonicalJson(expected)) {
    throw new Error(
      `HTPHashing TYPEHASH set drifted: expected ${expected.join(",")} got ${actual.join(",")}.`,
    );
  }
}

function feeScopePriority(model: SchemaModel): string[] {
  return [...(model.enums.ScopeType ?? [])]
    .filter((member) => member.name !== "NONE")
    .sort((left, right) => right.value - left.value)
    .map((member) => member.name);
}

function selectTypehashes(model: SchemaModel, names: readonly string[]): JsonObject[] {
  return names.map((constant) => {
    const value = model.typehashes[constant];
    if (!value) throw new Error(`Unable to extract Solidity typehash constant ${constant}.`);
    return { constant, typeString: value.typeString, typeHash: value.typeHash };
  });
}

export interface ConfigSourceMetadata {
  configIdNamespaces: Record<string, {
    preimage: string;
    namespaceHash: string;
  }>;
  feeScope: {
    constant: "TYPEHASH";
    typeString: string;
    typeHash: string;
  };
}

export function configSourceMetadataFromModel(model: SchemaModel): ConfigSourceMetadata {
  const configIdNamespaces = Object.fromEntries(
    REQUIRED_CONFIG_NAMESPACES.map((constant) => {
      const value = model.configIdNamespaces[constant];
      if (!value) {
        throw new Error(`ConfigId namespace constants missing or renamed: expected ${REQUIRED_CONFIG_NAMESPACES.join(",")}.`);
      }
      return [constant, { preimage: value.preimage, namespaceHash: value.value }];
    }),
  );
  const actualConstants = Object.keys(model.configIdNamespaces).sort();
  const expectedConstants = [...REQUIRED_CONFIG_NAMESPACES].sort();
  if (canonicalJson(actualConstants) !== canonicalJson(expectedConstants)) {
    throw new Error(
      `ConfigId namespace constants missing or renamed: expected ${expectedConstants.join(",")}.`,
    );
  }
  return {
    configIdNamespaces,
    feeScope: {
      constant: "TYPEHASH",
      typeString: model.feeScope.typeString,
      typeHash: model.feeScope.typeHash,
    },
  };
}

/** @deprecated Use configSourceMetadataFromModel. Kept name for existing tests during migration. */
export function extractConfigSourceMetadata(model: SchemaModel): ConfigSourceMetadata {
  return configSourceMetadataFromModel(model);
}

function configDocument(model: SchemaModel, sourceMetadata: ConfigSourceMetadata): JsonObject {
  const namespace = (constant: typeof REQUIRED_CONFIG_NAMESPACES[number]) => {
    if (!sourceMetadata.configIdNamespaces[constant]) {
      throw new Error(`Extracted ConfigId namespace ${constant} is unavailable.`);
    }
    return constant;
  };
  return {
    schemaVersion: 1,
    generatedFrom: [
      "contracts/src/libraries/HTPHashing.sol",
      "contracts/src/libraries/ConfigId.sol",
      "contracts/src/libraries/FeeScope.sol",
    ],
    types: selectTypehashes(model, CONFIG_CONSTANTS),
    sourceConstants: sourceMetadata,
    idFormulas: [
      {
        name: "AssetVersion",
        namespaceConstant: null,
        subject: "economicAssetIdHash + assetToken + versionNo",
        formula: "keccak256(abi.encode(schemaVersion,economicAssetIdHash,chainId,assetToken,versionNo))",
      },
      {
        name: "SettlementTokenConfig",
        namespaceConstant: namespace("SETTLEMENT_TOKEN_NAMESPACE"),
        subject: "bytes32(uint256(uint160(settlementToken)))",
        formula: "keccak256(abi.encode(namespaceHash,schemaVersion,chainId,subjectKey,revision))",
      },
      {
        name: "AdapterConfig",
        namespaceConstant: namespace("ADAPTER_NAMESPACE"),
        subject: "capabilityHash",
        formula: "keccak256(abi.encode(namespaceHash,schemaVersion,chainId,subjectKey,revision))",
      },
      {
        name: "PrincipalCalculatorConfig",
        namespaceConstant: namespace("PRINCIPAL_CALCULATOR_NAMESPACE"),
        subject: "bytes32(uint256(assetClass))",
        formula: "keccak256(abi.encode(namespaceHash,schemaVersion,chainId,subjectKey,revision))",
      },
      {
        name: "MarketRuleConfig",
        namespaceConstant: namespace("MARKET_RULE_NAMESPACE"),
        subject: "assetVersionId",
        formula: "keccak256(abi.encode(namespaceHash,schemaVersion,chainId,subjectKey,revision))",
      },
      {
        name: "FeeConfig",
        namespaceConstant: namespace("FEE_NAMESPACE"),
        subject: "matchedScopeHash",
        formula: "keccak256(abi.encode(namespaceHash,schemaVersion,chainId,subjectKey,revision))",
      },
    ],
    hashFormula: "keccak256(abi.encode(TYPEHASH, canonical fields excluding stored configHash))",
    feeScope: {
      sourceConstant: sourceMetadata.feeScope.constant,
      priority: feeScopePriority(model),
    },
  };
}

function layoutDocument(model: SchemaModel): JsonObject {
  return {
    schemaVersion: 1,
    generatedFrom: "contracts/src/types/HTPTypes.sol AST",
    structs: Object.values(model.structs).map((struct) => ({
      name: struct.name,
      dynamic: struct.dynamic,
      headByteLength: struct.headByteLength,
      fields: struct.fields.map((field) => ({
        name: field.name,
        solidityType: field.solidityType,
        abiType: field.abiType,
        kind: field.kind,
        dynamic: field.dynamic,
        headOffset: field.headOffset,
      })),
    })),
  };
}

function structCatalogDocument(model: SchemaModel): JsonObject {
  return {
    schemaVersion: 1,
    generatedFrom: "contracts/src/types/HTPTypes.sol AST",
    structs: Object.values(model.structs).map((struct) => ({
      name: struct.name,
      fields: struct.fields.map((field) => ({
        name: field.name,
        solidityType: field.solidityType,
        abiType: field.abiType,
        kind: field.kind,
        ...(field.nestedStruct !== undefined ? { nestedStruct: field.nestedStruct } : {}),
        ...(field.arrayLength !== undefined ? { arrayLength: field.arrayLength } : {}),
      })),
    })),
  };
}

function interfaceVersionDocument(model: SchemaModel): JsonObject {
  return {
    schemaVersion: 1,
    generatedFrom: "contracts/src/interfaces/InterfaceVersions.sol",
    versions: Object.entries(model.interfaceVersions)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, value]) => ({
        name,
        preimage: value.preimage,
        value: value.value,
      })),
  };
}

function roleDocument(model: SchemaModel): JsonObject {
  return {
    schemaVersion: 1,
    generatedFrom: "contracts/src/libraries/Roles.sol",
    roles: model.roles.map((role) => ({
      name: role.name,
      value: role.value,
      preimage: role.preimage,
      ownership: "onchain",
    })),
  };
}

export function buildSchemaBundle(repositoryRoot: string): SchemaBundle {
  const selected = selectProductionBuildInfo(repositoryRoot);
  const model = buildSchemaModel(repositoryRoot);
  assertTypehashInventory(model);
  const sourceMetadata = configSourceMetadataFromModel(model);
  const abiDocuments = extractErrorsAndEvents(selected.buildInfo);
  const typeSource = selected.buildInfo.input.sources["src/types/HTPTypes.sol"].content;
  const documents: Record<string, JsonObject> = {
    [SCHEMA_DOCUMENT_PATHS.enums]: enumDocument(model),
    [SCHEMA_DOCUMENT_PATHS.structs]: structCatalogDocument(model),
    [SCHEMA_DOCUMENT_PATHS.layouts]: layoutDocument(model),
    [SCHEMA_DOCUMENT_PATHS.eip712]: {
      schemaVersion: model.schemaVersion,
      generatedFrom: "contracts/src/libraries/HTPHashing.sol",
      domain: { name: model.domain.name, version: "deployment major version" },
      types: selectTypehashes(model, EIP712_CONSTANTS),
    },
    [SCHEMA_DOCUMENT_PATHS.configs]: configDocument(model, sourceMetadata),
    [SCHEMA_DOCUMENT_PATHS.roles]: roleDocument(model),
    [SCHEMA_DOCUMENT_PATHS.errors]: abiDocuments.errors,
    [SCHEMA_DOCUMENT_PATHS.events]: abiDocuments.events,
    [SCHEMA_DOCUMENT_PATHS.interfaceVersions]: interfaceVersionDocument(model),
  };
  const interfaces = Object.fromEntries(
    Object.entries(model.interfaces).map(([name, value]) => [name, { sourceName: value.sourceName, abi: value.abi }]),
  );
  const abis = Object.fromEntries(Object.entries(model.interfaces).map(([name, value]) => [name, value.abi]));
  return {
    manifest: {
      schemaVersion: model.schemaVersion,
      candidate: true,
      generatedFrom: {
        solcLongVersion: selected.buildInfo.solcLongVersion,
        soliditySourcesSha256: hashSourceTree(repositoryRoot),
        typesSourceSha256: sha256Hex(typeSource),
      },
      enums: model.enums,
      interfaces,
      documents: Object.keys(documents).sort(),
    },
    abis,
    documents,
  };
}

export function artifactIndex(bundle: SchemaBundle): JsonObject {
  const files = [
    {
      path: "manifest.json",
      kind: "manifest",
      sha256: sha256Hex(canonicalJson(bundle.manifest)),
    },
    ...Object.entries(bundle.documents).map(([path, document]) => ({
      path,
      kind: "document",
      sha256: sha256Hex(canonicalJson(document)),
    })),
    ...Object.entries(bundle.abis).map(([name, abi]) => ({
      path: `abi/${name}.json`,
      kind: "abi",
      sha256: sha256Hex(canonicalJson(abi)),
    })),
  ].sort((left, right) => left.path.localeCompare(right.path));
  return {
    schemaVersion: bundle.manifest.schemaVersion,
    generatedFrom: "packages/schema-tools SchemaModel",
    files,
  };
}

export function writeSchemaDirectory(bundle: SchemaBundle, schemaDirectory: string): void {
  mkdirSync(schemaDirectory, { recursive: true });
  for (const stale of STALE_SCHEMA_V1_ROOT_ENTRIES) {
    rmSync(resolve(schemaDirectory, stale), { recursive: true, force: true });
  }
  for (const directory of ["types", "protocol", "vectors", "abi"]) {
    rmSync(resolve(schemaDirectory, directory), { recursive: true, force: true });
    mkdirSync(resolve(schemaDirectory, directory), { recursive: true });
  }
  writeFileSync(resolve(schemaDirectory, "manifest.json"), canonicalJson(bundle.manifest));
  for (const [name, document] of Object.entries(bundle.documents)) {
    const path = resolve(schemaDirectory, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, canonicalJson(document));
  }
  const abiDirectory = resolve(schemaDirectory, "abi");
  for (const [name, abi] of Object.entries(bundle.abis).sort(([left], [right]) =>
    left.localeCompare(right)
  )) {
    writeFileSync(resolve(abiDirectory, `${name}.json`), canonicalJson(abi));
  }
  writeFileSync(resolve(schemaDirectory, "index.json"), canonicalJson(artifactIndex(bundle)));
}

function assertOwnedDirectoryFileSet(
  schemaDirectory: string,
  directoryName: string,
  documents: Record<string, JsonObject>,
  allowedExtras: readonly string[],
): void {
  const prefix = `${directoryName}/`;
  const expected = Object.keys(documents)
    .filter((path) => path.startsWith(prefix) && !path.slice(prefix.length).includes("/"))
    .map((path) => path.slice(prefix.length))
    .sort();
  const directory = resolve(schemaDirectory, directoryName);
  const actual = existsSync(directory) ? readdirSync(directory).sort() : [];
  const missing = expected.filter((name) => !actual.includes(name));
  const unexpected = actual.filter((name) => !expected.includes(name) && !allowedExtras.includes(name));
  if (missing.length > 0 || unexpected.length > 0) {
    throw new Error(`manifest drift detected: ${directoryName} file set differs`);
  }
}

export function checkSchemaDirectory(bundle: SchemaBundle, schemaDirectory: string): void {
  const manifestPath = resolve(schemaDirectory, "manifest.json");
  if (!existsSync(manifestPath) || readFileSync(manifestPath, "utf8") !== canonicalJson(bundle.manifest)) {
    throw new Error("manifest drift detected");
  }
  const expectedRootEntries: string[] = [...SCHEMA_V1_ROOT_ENTRIES].sort();
  const actualRootEntries = readdirSync(schemaDirectory).sort();
  const missingRootEntries = expectedRootEntries.filter((name) => !actualRootEntries.includes(name));
  const unexpectedRootEntries = actualRootEntries.filter(
    (name) =>
      !expectedRootEntries.includes(name) && !SCHEMA_V1_OPTIONAL_ROOT_ENTRIES.some((entry) => entry === name),
  );
  if (missingRootEntries.length > 0 || unexpectedRootEntries.length > 0) {
    throw new Error("manifest drift detected: root file set differs");
  }
  assertOwnedDirectoryFileSet(schemaDirectory, "types", bundle.documents, []);
  assertOwnedDirectoryFileSet(schemaDirectory, "protocol", bundle.documents, [...PROTOCOL_OPTIONAL_FILES]);
  for (const [name, document] of Object.entries(bundle.documents)) {
    const path = resolve(schemaDirectory, name);
    if (!existsSync(path) || readFileSync(path, "utf8") !== canonicalJson(document)) {
      throw new Error(`manifest drift detected: ${name}`);
    }
  }
  const abiDirectory = resolve(schemaDirectory, "abi");
  const expectedFiles = Object.keys(bundle.abis).sort().map((name) => `${name}.json`);
  const actualFiles = existsSync(abiDirectory) ? readdirSync(abiDirectory).sort() : [];
  if (canonicalJson(actualFiles) !== canonicalJson(expectedFiles)) {
    throw new Error("ABI drift detected: file set differs");
  }
  for (const [name, abi] of Object.entries(bundle.abis)) {
    const path = resolve(abiDirectory, `${name}.json`);
    if (!existsSync(path) || readFileSync(path, "utf8") !== canonicalJson(abi)) {
      throw new Error(`ABI drift detected: ${name}`);
    }
  }
  const indexPath = resolve(schemaDirectory, "index.json");
  if (!existsSync(indexPath) || readFileSync(indexPath, "utf8") !== canonicalJson(artifactIndex(bundle))) {
    throw new Error("manifest drift detected: index.json");
  }
}

export function schemaV1Directory(repositoryRoot: string): string {
  return resolve(repositoryRoot, "schema/v1");
}
