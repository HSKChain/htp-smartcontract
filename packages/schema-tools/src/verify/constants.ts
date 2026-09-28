import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { keccak256, stringToHex } from "viem";

import { buildSchemaModel, type SchemaModel } from "../model.js";
import { PROTOCOL_CONSTANTS_PATH, schemaRepoPath } from "../paths.js";

function hashViem(preimage: string): `0x${string}` {
  return keccak256(stringToHex(preimage));
}

function hashCast(preimage: string): `0x${string}` {
  const value = execFileSync("cast", ["keccak", preimage], { encoding: "utf8" }).trim();
  if (!/^0x[0-9a-f]{64}$/u.test(value)) {
    throw new Error(`cast keccak returned a malformed digest for ${preimage}`);
  }
  return value as `0x${string}`;
}

function agree(preimage: string): `0x${string}` {
  const viemHash = hashViem(preimage);
  const castHash = hashCast(preimage);
  if (viemHash !== castHash) {
    throw new Error(`viem and cast disagree for ${preimage}: ${viemHash} vs ${castHash}`);
  }
  return viemHash;
}

export function buildConstantsDocument(model: SchemaModel) {
  const namedRoles = model.roles.filter((role) => role.name !== "DEFAULT_ADMIN_ROLE");
  const admin = model.roles.find((role) => role.name === "DEFAULT_ADMIN_ROLE");
  const roles = Object.fromEntries(
    [...namedRoles, ...(admin ? [admin] : [])].map((role) => [
      role.name,
      role.preimage === null ? role.value : agree(role.preimage),
    ]),
  );
  return {
    schemaVersion: 1,
    roles,
    interfaceVersion: {
      assetAdapterV1: agree(model.interfaceVersions.ASSET_ADAPTER_V1!.preimage),
      principalCalculatorV1: agree(model.interfaceVersions.PRINCIPAL_CALCULATOR_V1!.preimage),
    },
    domain: {
      eip712Name: model.domain.name,
      eip712NameHash: agree(model.domain.name),
      eip712DomainTypeHash: agree(model.typehashes.EIP712_DOMAIN_TYPEHASH!.typeString),
      deploymentVersionDomain: agree(model.deploymentVersionDomain.preimage),
    },
  };
}

function serializeConstants(document: ReturnType<typeof buildConstantsDocument>): string {
  return `${JSON.stringify(document, null, 2)}\n`;
}

export function writeOrCheckConstants(repositoryRoot: string, write: boolean): void {
  const model = buildSchemaModel(repositoryRoot);
  const document = buildConstantsDocument(model);
  const target = resolve(repositoryRoot, schemaRepoPath(PROTOCOL_CONSTANTS_PATH));
  const serialized = serializeConstants(document);
  if (write) {
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, serialized);
    console.log(`Wrote ${target}`);
    return;
  }
  if (!existsSync(target) || readFileSync(target, "utf8") !== serialized) {
    throw new Error("committed constants.json differs from AST preimages hashed by viem and cast");
  }
  console.log("cast, viem, and committed constants.json agree");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const repositoryRoot = resolve(import.meta.dirname, "../../../..");
  writeOrCheckConstants(repositoryRoot, process.argv.includes("--write"));
}
