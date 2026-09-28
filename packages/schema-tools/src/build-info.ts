import { existsSync, readFileSync } from "node:fs";
import { relative, resolve } from "node:path";

import { listFiles, readJson, sha256Hex } from "./json.js";

export const REQUIRED_AST_SOURCES = [
  "src/types/HTPTypes.sol",
  "src/libraries/HTPHashing.sol",
  "src/libraries/Roles.sol",
  "src/libraries/ConfigId.sol",
  "src/libraries/FeeScope.sol",
  "src/libraries/DeploymentVersion.sol",
  "src/interfaces/InterfaceVersions.sol",
] as const;

export const REQUIRED_INTERFACE_ABI = {
  sourceName: "src/interfaces/IDvPSettlement.sol",
  contractName: "IDvPSettlement",
} as const;

export interface ProductionBuildInfo {
  path: string;
  solcLongVersion: string;
  buildInfo: any;
}

function hasAstNodes(buildInfo: any, sourceName: string): boolean {
  return Array.isArray(buildInfo.output?.sources?.[sourceName]?.ast?.nodes);
}

function hasInterfaceAbi(buildInfo: any): boolean {
  const abi = buildInfo.output?.contracts?.[REQUIRED_INTERFACE_ABI.sourceName]?.[
    REQUIRED_INTERFACE_ABI.contractName
  ]?.abi;
  return Array.isArray(abi) && abi.some((entry: any) => entry.type === "function");
}

function solcMatchesPin(solcLongVersion: string, pin: { configVersion: string; longVersion: string }): boolean {
  return (
    solcLongVersion === pin.longVersion
    || solcLongVersion === pin.configVersion
    || solcLongVersion.startsWith(`${pin.configVersion}+`)
    || solcLongVersion.startsWith(`${pin.configVersion}.`)
  );
}

function productionSurfaceFingerprint(candidate: ProductionBuildInfo): string {
  const sourceContents = Object.fromEntries(
    Object.entries(candidate.buildInfo.input?.sources ?? {})
      .filter(([sourceName]) => sourceName.startsWith("src/"))
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([sourceName, source]: [string, any]) => [sourceName, source?.content]),
  );
  const interfaces = Object.fromEntries(
    Object.entries(candidate.buildInfo.output?.contracts ?? {})
      .filter(([sourceName]) => sourceName.startsWith("src/interfaces/"))
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([sourceName, contracts]: [string, any]) => [
        sourceName,
        Object.fromEntries(
          Object.entries(contracts)
            .sort(([left], [right]) => left.localeCompare(right))
            .map(([contractName, artifact]: [string, any]) => [contractName, artifact?.abi]),
        ),
      ]),
  );
  return sha256Hex(JSON.stringify({ solcLongVersion: candidate.solcLongVersion, sourceContents, interfaces }));
}

export function readSolcPin(repositoryRoot: string): { configVersion: string; longVersion: string } {
  const lock = readJson(resolve(repositoryRoot, "contracts/toolchain.lock.json"));
  const configVersion = lock?.tools?.solc?.configVersion;
  const longVersion = lock?.tools?.solc?.longVersion;
  if (typeof configVersion !== "string" || typeof longVersion !== "string") {
    throw new Error("contracts/toolchain.lock.json is missing pinned solc versions.");
  }
  return { configVersion, longVersion };
}

export function selectProductionBuildInfo(repositoryRoot: string): ProductionBuildInfo {
  const pin = readSolcPin(repositoryRoot);
  const buildInfoDirectory = resolve(repositoryRoot, "contracts/out/build-info");
  if (!existsSync(buildInfoDirectory)) {
    throw new Error("No contracts/out/build-info directory; run a clean forge build.");
  }
  const candidates = listFiles(buildInfoDirectory)
    .filter((path) => path.endsWith(".json"))
    .map((path) => ({ path, buildInfo: readJson(path), solcLongVersion: "" }))
    .map((candidate) => ({
      ...candidate,
      solcLongVersion: String(candidate.buildInfo.solcLongVersion ?? candidate.buildInfo.solcVersion ?? ""),
    }))
    .filter((candidate) =>
      solcMatchesPin(candidate.solcLongVersion, pin)
      && REQUIRED_AST_SOURCES.every((sourceName) => hasAstNodes(candidate.buildInfo, sourceName))
      && hasInterfaceAbi(candidate.buildInfo)
    );
  if (candidates.length === 0) {
    throw new Error(
      "No production build-info contains complete HTP AST and IDvPSettlement ABI; run a clean forge build.",
    );
  }
  if (candidates.length > 1) {
    const fingerprints = new Set(candidates.map(productionSurfaceFingerprint));
    if (fingerprints.size !== 1) {
      const paths = candidates.map((candidate) => candidate.path).sort().join(", ");
      throw new Error(`Multiple conflicting production build-info candidates: ${paths}`);
    }
    candidates.sort((left, right) => left.path.localeCompare(right.path));
  }
  return candidates[0]!;
}

export function sourceContent(buildInfo: any, sourceName: string): string {
  const content = buildInfo.input?.sources?.[sourceName]?.content;
  if (typeof content !== "string") {
    throw new Error(`Build-info is missing source content for ${sourceName}.`);
  }
  return content;
}

export function sourceAst(buildInfo: any, sourceName: string): any {
  const ast = buildInfo.output?.sources?.[sourceName]?.ast;
  if (!Array.isArray(ast?.nodes)) {
    throw new Error(`Build-info is missing AST nodes for ${sourceName}.`);
  }
  return ast;
}

export function hashSourceTree(repositoryRoot: string): string {
  const solidityRoot = resolve(repositoryRoot, "contracts/src");
  const chunks: Buffer[] = [];
  for (const path of listFiles(solidityRoot).filter((value) => value.endsWith(".sol")).sort()) {
    const sourceName = relative(resolve(repositoryRoot, "contracts"), path);
    chunks.push(Buffer.from(sourceName), Buffer.from("\0"), readFileSync(path), Buffer.from("\0"));
  }
  return sha256Hex(Buffer.concat(chunks));
}
