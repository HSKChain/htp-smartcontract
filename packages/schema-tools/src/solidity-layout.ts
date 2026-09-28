import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

import { type StructFieldModel, type StructModel } from "./layout.js";
import { checkFormattedSolidity, writeFormattedSolidity } from "./generated-solidity.js";
import { buildSchemaModel, type SchemaModel } from "./model.js";

const LAYOUT_RELATIVE = "test/unit/generated/SchemaLayout.t.sol";

class Counter {
  private value = 1;

  next(): number {
    return this.value++;
  }
}

export function emptyTailSize(field: StructFieldModel, structs: Record<string, StructModel>): number {
  if (field.abiType === "bytes" || field.abiType === "string") return 32;
  if (field.kind === "array") return 32;
  if (field.kind === "struct" && field.nestedStruct) {
    return emptyEncodingSize(structs[field.nestedStruct]!, structs);
  }
  throw new Error(`Unable to size empty tail for ${field.name} (${field.abiType})`);
}

export function emptyEncodingSize(struct: StructModel, structs: Record<string, StructModel>): number {
  let size = struct.headByteLength;
  for (const field of struct.fields) {
    if (field.dynamic) size += emptyTailSize(field, structs);
  }
  return size;
}

function dynamicHeadValues(struct: StructModel, structs: Record<string, StructModel>): Map<string, number> {
  let tail = struct.headByteLength;
  const values = new Map<string, number>();
  for (const field of struct.fields) {
    if (!field.dynamic) continue;
    values.set(field.name, tail);
    tail += emptyTailSize(field, structs);
  }
  return values;
}

function enumMember(model: SchemaModel, enumType: string, unique: number): { name: string; value: number } {
  const members = model.enums[enumType];
  if (!members?.length) throw new Error(`Unknown enum ${enumType}`);
  if (members.length === 1) return members[0]!;
  return members[(unique % (members.length - 1)) + 1]!;
}

function uintMax(abiType: string): number | undefined {
  const match = /^uint(\d+)$/u.exec(abiType);
  if (!match) return undefined;
  const bits = Number(match[1]);
  if (bits >= 32) return undefined;
  return 2 ** bits - 1;
}

function clampUnique(unique: number, abiType: string): number {
  const max = uintMax(abiType);
  if (max === undefined) return unique;
  return ((unique - 1) % max) + 1;
}

interface GeneratedLines {
  assign: string[];
  assert: string[];
}

function generateStaticField(
  field: StructFieldModel,
  model: SchemaModel,
  prefix: string,
  headExpr: string,
  offsetBase: number,
  counter: Counter,
): GeneratedLines {
  const target = `${prefix}.${field.name}`;
  const wordOffset = `${headExpr} + ${offsetBase + field.headOffset}`;
  if (field.kind === "enum") {
    const unique = counter.next();
    const member = enumMember(model, field.solidityType, unique);
    return {
      assign: [`        ${target} = ${field.solidityType}.${member.name};`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), ${member.value});`],
    };
  }
  if (field.kind === "struct") {
    if (!field.nestedStruct) throw new Error(`Missing nested struct for ${field.name}`);
    const nested = model.structs[field.nestedStruct];
    if (!nested) throw new Error(`Unknown nested struct ${field.nestedStruct}`);
    const combined: GeneratedLines = { assign: [], assert: [] };
    for (const nestedField of nested.fields) {
      const generated = generateField(
        nestedField,
        model,
        target,
        headExpr,
        offsetBase + field.headOffset,
        counter,
        dynamicHeadValues(nested, model.structs),
      );
      combined.assign.push(...generated.assign);
      combined.assert.push(...generated.assert);
    }
    return combined;
  }
  if (field.kind === "array") {
    throw new Error(`Static arrays are not generated yet: ${prefix}.${field.name}`);
  }
  const unique = clampUnique(counter.next(), field.abiType);
  if (field.abiType === "address") {
    return {
      assign: [`        ${target} = address(uint160(${unique}));`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), ${unique});`],
    };
  }
  if (field.abiType === "bool") {
    return {
      assign: [`        ${target} = true;`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), 1);`],
    };
  }
  if (field.abiType === "bytes32") {
    return {
      assign: [`        ${target} = bytes32(uint256(${unique}));`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), ${unique});`],
    };
  }
  if (field.abiType === "bytes4") {
    return {
      assign: [`        ${target} = bytes4(uint32(${unique}));`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), uint256(bytes32(bytes4(uint32(${unique})))));`],
    };
  }
  if (field.abiType.startsWith("uint")) {
    return {
      assign: [`        ${target} = ${unique};`],
      assert: [`        assertEq(_word(encoded, ${wordOffset}), ${unique});`],
    };
  }
  throw new Error(`No layout assignment for ${prefix}.${field.name} (${field.abiType})`);
}

function generateField(
  field: StructFieldModel,
  model: SchemaModel,
  prefix: string,
  headExpr: string,
  offsetBase: number,
  counter: Counter,
  dynamicOffsets: Map<string, number>,
): GeneratedLines {
  if (field.dynamic) {
    const relative = dynamicOffsets.get(field.name);
    if (relative === undefined) {
      throw new Error(`Missing dynamic head offset for ${prefix}.${field.name}`);
    }
    return {
      assign: [],
      assert: [`        assertEq(_word(encoded, ${headExpr} + ${offsetBase + field.headOffset}), ${relative});`],
    };
  }
  return generateStaticField(field, model, prefix, headExpr, offsetBase, counter);
}

function generateStructTest(struct: StructModel, model: SchemaModel): string {
  const counter = new Counter();
  const headExpr = struct.dynamic ? "head" : "0";
  const dynamicOffsets = dynamicHeadValues(struct, model.structs);
  const assign: string[] = [];
  const assertLines: string[] = [];
  for (const field of struct.fields) {
    const generated = generateField(field, model, "value", headExpr, 0, counter, dynamicOffsets);
    assign.push(...generated.assign);
    assertLines.push(...generated.assert);
  }
  const prelude = struct.dynamic
    ? [
        "        bytes memory encoded = abi.encode(value);",
        "        uint256 head = 32;",
        "        assertEq(_word(encoded, 0), 32);",
        `        assertEq(encoded.length, ${32 + emptyEncodingSize(struct, model.structs)});`,
      ]
    : [
        "        bytes memory encoded = abi.encode(value);",
        `        assertEq(encoded.length, ${struct.headByteLength});`,
      ];
  return `    function testLayout_${struct.name}() public pure {
        ${struct.name} memory value;
${assign.join("\n")}
${prelude.join("\n")}
${assertLines.join("\n")}
    }`;
}

function collectUsedEnums(struct: StructModel, model: SchemaModel, used: Set<string>): void {
  for (const field of struct.fields) {
    if (field.kind === "enum") used.add(field.solidityType);
    if (field.kind === "struct" && field.nestedStruct && !field.dynamic) {
      collectUsedEnums(model.structs[field.nestedStruct]!, model, used);
    }
  }
}

export function renderSchemaLayoutTests(repositoryRoot: string): string {
  const model = buildSchemaModel(repositoryRoot);
  const structs = Object.values(model.structs);
  const structNames = structs.map((struct) => struct.name).sort();
  const usedEnums = new Set<string>();
  for (const struct of structs) collectUsedEnums(struct, model, usedEnums);
  const enumNames = [...usedEnums].sort();
  return `// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

// GENERATED FILE — DO NOT EDIT.
// generatedFrom schema-tools SchemaModel ABI layout
// typesSource derived from contracts/src/types/HTPTypes.sol AST
// solc ${model.solcLongVersion}

import {${[...enumNames, ...structNames].join(",\n    ")}} from "src/types/HTPTypes.sol";
import {AbiAssertions} from "test/helpers/AbiAssertions.sol";

contract SchemaLayoutTest is AbiAssertions {
${structs.map((struct) => generateStructTest(struct, model)).join("\n\n")}
}
`;
}

export function writeSchemaLayoutTests(repositoryRoot: string): string {
  return writeFormattedSolidity(repositoryRoot, LAYOUT_RELATIVE, renderSchemaLayoutTests(repositoryRoot));
}

export function checkSchemaLayoutTests(repositoryRoot: string): void {
  checkFormattedSolidity(repositoryRoot, LAYOUT_RELATIVE, renderSchemaLayoutTests(repositoryRoot));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const repositoryRoot = resolve(import.meta.dirname, "../../..");
  const path = writeSchemaLayoutTests(repositoryRoot);
  console.log(`Wrote ${path}`);
}
