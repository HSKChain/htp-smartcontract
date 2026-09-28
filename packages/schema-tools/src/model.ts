import { keccak256, stringToHex } from "viem";

import {
  bytes32Zero,
  definitionNodes,
  keccakPreimage,
  numericLiteral,
  stringLiteral,
} from "./ast.js";
import { selectProductionBuildInfo, sourceAst } from "./build-info.js";
import { attachAbiLayout, type StructFieldModel, type StructModel } from "./layout.js";

export interface EnumMemberModel {
  name: string;
  value: number;
}

export interface RoleModel {
  name: string;
  value: `0x${string}`;
  preimage: string | null;
}

export interface Bytes32ConstantModel {
  name: string;
  value: `0x${string}`;
  preimage: string;
}

export interface TypehashModel {
  constant: string;
  typeString: string;
  typeHash: `0x${string}`;
}

export interface SchemaModel {
  schemaVersion: number;
  solcLongVersion: string;
  domain: {
    name: string;
    nameHash: `0x${string}`;
  };
  enums: Record<string, EnumMemberModel[]>;
  structs: Record<string, StructModel>;
  typehashes: Record<string, TypehashModel>;
  roles: RoleModel[];
  interfaceVersions: Record<string, Bytes32ConstantModel>;
  configIdNamespaces: Record<string, Bytes32ConstantModel>;
  feeScope: TypehashModel;
  deploymentVersionDomain: Bytes32ConstantModel;
  interfaces: Record<string, { sourceName: string; abi: unknown[] }>;
}

const ZERO_HASH = `0x${"00".repeat(32)}` as const;

function hashUtf8(preimage: string): `0x${string}` {
  return keccak256(stringToHex(preimage));
}

function typeNameNode(field: any): any {
  return field.typeName ?? field;
}

function elementaryName(typeName: any): string | undefined {
  if (typeName?.nodeType === "ElementaryTypeName" && typeof typeName.name === "string") {
    return typeName.name;
  }
  return undefined;
}

function referencedName(typeName: any): string | undefined {
  return typeName?.pathNode?.name ?? typeName?.name;
}

function parseField(
  member: any,
  enums: Record<string, EnumMemberModel[]>,
): Omit<StructFieldModel, "headOffset" | "dynamic"> {
  const typeName = typeNameNode(member);
  if (typeName.nodeType === "ArrayTypeName") {
    const base = parseField({ name: member.name, typeName: typeName.baseType }, enums);
    const lengthNode = typeName.length;
    const arrayLength = lengthNode ? numericLiteral(lengthNode) ?? Number(lengthNode.value) : null;
    const suffix = arrayLength === null || Number.isNaN(arrayLength) ? "[]" : `[${arrayLength}]`;
    return {
      name: member.name,
      solidityType: `${base.solidityType}${suffix}`,
      abiType: `${base.abiType}${suffix}`,
      kind: "array",
      nestedStruct: base.kind === "struct" ? base.nestedStruct : undefined,
      arrayLength: arrayLength === null || Number.isNaN(arrayLength) ? null : arrayLength,
    };
  }
  const elementary = elementaryName(typeName);
  if (elementary) {
    return {
      name: member.name,
      solidityType: elementary,
      abiType: elementary,
      kind: "elementary",
    };
  }
  const userType = referencedName(typeName);
  if (!userType) {
    throw new Error(`Unable to resolve type for struct field ${member.name}`);
  }
  if (enums[userType]) {
    return {
      name: member.name,
      solidityType: userType,
      abiType: "uint8",
      kind: "enum",
    };
  }
  return {
    name: member.name,
    solidityType: userType,
    abiType: userType,
    kind: "struct",
    nestedStruct: userType,
  };
}

function constantValue(node: any): { preimage: string | null; value: `0x${string}` } | undefined {
  if (!node?.value) return undefined;
  if (bytes32Zero(node.value)) {
    return { preimage: null, value: ZERO_HASH };
  }
  const preimage = keccakPreimage(node.value);
  if (preimage !== undefined) {
    return { preimage, value: hashUtf8(preimage) };
  }
  const literal = stringLiteral(node.value);
  if (literal !== undefined) {
    return { preimage: literal, value: hashUtf8(literal) };
  }
  return undefined;
}

function namedConstants(ast: any, predicate: (name: string) => boolean): any[] {
  return definitionNodes(ast).filter(
    (node) => node.nodeType === "VariableDeclaration" && typeof node.name === "string" && predicate(node.name),
  );
}

export function buildSchemaModel(repositoryRoot: string): SchemaModel {
  const selected = selectProductionBuildInfo(repositoryRoot);
  const typesAst = sourceAst(selected.buildInfo, "src/types/HTPTypes.sol");
  const hashingAst = sourceAst(selected.buildInfo, "src/libraries/HTPHashing.sol");
  const rolesAst = sourceAst(selected.buildInfo, "src/libraries/Roles.sol");
  const configIdAst = sourceAst(selected.buildInfo, "src/libraries/ConfigId.sol");
  const feeScopeAst = sourceAst(selected.buildInfo, "src/libraries/FeeScope.sol");
  const interfaceVersionAst = sourceAst(selected.buildInfo, "src/interfaces/InterfaceVersions.sol");
  const deploymentAst = sourceAst(selected.buildInfo, "src/libraries/DeploymentVersion.sol");

  const typeDefinitions = definitionNodes(typesAst);
  const schemaDeclaration = typeDefinitions.find(
    (node) => node.nodeType === "VariableDeclaration" && node.name === "SCHEMA_VERSION",
  );
  const schemaVersion = numericLiteral(schemaDeclaration?.value);
  if (schemaVersion === undefined) {
    throw new Error("Unable to extract HTPTypes.SCHEMA_VERSION from AST.");
  }

  const enums = Object.fromEntries(
    typeDefinitions
      .filter((node) => node.nodeType === "EnumDefinition")
      .map((node) => [
        node.name as string,
        (node.members as any[]).map((member: any, value: number) => ({ name: member.name as string, value })),
      ]),
  ) as Record<string, EnumMemberModel[]>;

  const rawStructs = Object.fromEntries(
    typeDefinitions
      .filter((node) => node.nodeType === "StructDefinition")
      .map((node) => [
        node.name as string,
        {
          name: node.name as string,
          fields: (node.members as any[]).map((member) => parseField(member, enums)),
        },
      ]),
  );
  const structs = attachAbiLayout(rawStructs);

  const typehashes = Object.fromEntries(
    namedConstants(hashingAst, (name) => name.endsWith("_TYPEHASH") || name === "EIP712_DOMAIN_TYPEHASH").map(
      (node) => {
        const preimage = keccakPreimage(node.value);
        if (preimage === undefined) {
          throw new Error(`Unable to extract keccak preimage for ${node.name}`);
        }
        return [
          node.name as string,
          { constant: node.name as string, typeString: preimage, typeHash: hashUtf8(preimage) },
        ];
      },
    ),
  ) as Record<string, TypehashModel>;

  const eip712Name = namedConstants(hashingAst, (name) => name === "EIP712_NAME")[0];
  const domainName = stringLiteral(eip712Name?.value);
  if (domainName === undefined) {
    throw new Error("Unable to extract EIP712_NAME from AST.");
  }

  const roles = namedConstants(rolesAst, (name) => name.endsWith("_ROLE") || name === "DEFAULT_ADMIN_ROLE").map(
    (node) => {
      const extracted = constantValue(node);
      if (!extracted) throw new Error(`Unable to extract role constant ${node.name}`);
      return { name: node.name as string, value: extracted.value, preimage: extracted.preimage };
    },
  );

  const interfaceVersions = Object.fromEntries(
    namedConstants(interfaceVersionAst, () => true)
      .filter((node) => node.mutability === "constant")
      .map((node) => {
        const extracted = constantValue(node);
        if (!extracted?.preimage) throw new Error(`Unable to extract InterfaceVersions.${node.name}`);
        return [
          node.name as string,
          { name: node.name as string, value: extracted.value, preimage: extracted.preimage },
        ];
      }),
  ) as Record<string, Bytes32ConstantModel>;

  const configIdNamespaces = Object.fromEntries(
    namedConstants(configIdAst, (name) => name.endsWith("_NAMESPACE")).map((node) => {
      const extracted = constantValue(node);
      if (!extracted?.preimage) throw new Error(`Unable to extract ConfigId.${node.name}`);
      return [node.name as string, { name: node.name as string, value: extracted.value, preimage: extracted.preimage }];
    }),
  ) as Record<string, Bytes32ConstantModel>;

  const feeScopeConstant = namedConstants(feeScopeAst, (name) => name === "TYPEHASH")[0];
  const feeScopePreimage = keccakPreimage(feeScopeConstant?.value);
  if (feeScopePreimage === undefined) {
    throw new Error("Unable to extract FeeScope.TYPEHASH from AST.");
  }

  const deploymentDomain = namedConstants(deploymentAst, (name) => name === "DOMAIN")[0];
  const deploymentPreimage = keccakPreimage(deploymentDomain?.value);
  if (deploymentPreimage === undefined) {
    throw new Error("Unable to extract DeploymentVersion.DOMAIN from AST.");
  }

  const interfaces: Record<string, { sourceName: string; abi: unknown[] }> = {};
  for (const [sourceName, contracts] of Object.entries(selected.buildInfo.output?.contracts ?? {}) as Array<
    [string, Record<string, { abi?: unknown[] }>]
  >) {
    if (!sourceName.startsWith("src/interfaces/")) continue;
    for (const [contractName, artifact] of Object.entries(contracts)) {
      if (!Array.isArray(artifact.abi) || !artifact.abi.some((entry: any) => entry.type === "function")) continue;
      interfaces[contractName] = { sourceName, abi: artifact.abi };
    }
  }

  return {
    schemaVersion,
    solcLongVersion: selected.solcLongVersion,
    domain: { name: domainName, nameHash: hashUtf8(domainName) },
    enums,
    structs,
    typehashes,
    roles,
    interfaceVersions,
    configIdNamespaces,
    feeScope: {
      constant: "TYPEHASH",
      typeString: feeScopePreimage,
      typeHash: hashUtf8(feeScopePreimage),
    },
    deploymentVersionDomain: {
      name: "DOMAIN",
      value: hashUtf8(deploymentPreimage),
      preimage: deploymentPreimage,
    },
    interfaces,
  };
}
