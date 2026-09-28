export type AstNode = any;

export function definitionNodes(ast: AstNode): AstNode[] {
  const nodes: AstNode[] = [...(ast.nodes ?? [])];
  const nested: AstNode[] = [];
  for (const node of nodes) {
    if (node?.nodeType === "ContractDefinition") {
      nested.push(...(node.nodes ?? []));
    }
  }
  return [...nodes, ...nested];
}

export function identifierName(node: AstNode): string | undefined {
  if (typeof node?.name === "string") return node.name;
  if (typeof node?.expression?.name === "string") return node.expression.name;
  return undefined;
}

function decodeHexUtf8(hexValue: string): string {
  return Buffer.from(hexValue, "hex").toString("utf8");
}

export function stringLiteral(node: AstNode): string | undefined {
  if (node?.nodeType !== "Literal" || node.kind !== "string") {
    return undefined;
  }
  if (typeof node.value === "string") {
    return node.value;
  }
  if (typeof node.hexValue === "string") {
    return decodeHexUtf8(node.hexValue);
  }
  return undefined;
}

function concatenatedStringLiterals(nodes: AstNode[] | undefined): string | undefined {
  if (!Array.isArray(nodes) || nodes.length === 0) return undefined;
  const parts = nodes.map(stringLiteral);
  if (parts.some((part) => part === undefined)) return undefined;
  return parts.join("");
}

export function keccakPreimage(node: AstNode): string | undefined {
  if (node?.nodeType !== "FunctionCall" || identifierName(node) !== "keccak256") {
    return undefined;
  }
  const [argument] = node.arguments ?? [];
  const direct = stringLiteral(argument) ?? concatenatedStringLiterals(node.arguments);
  if (direct !== undefined) return direct;
  if (argument?.nodeType === "FunctionCall") {
    const innerName = identifierName(argument);
    const typeName = argument.expression?.typeName?.name ?? argument.expression?.name;
    if (innerName === "bytes" || typeName === "bytes" || argument.kind === "typeConversion") {
      return stringLiteral(argument.arguments?.[0]) ?? concatenatedStringLiterals(argument.arguments);
    }
  }
  return undefined;
}

export function bytes32Zero(node: AstNode): boolean {
  if (node?.nodeType !== "FunctionCall") return false;
  const typeName = node.expression?.typeName?.name ?? node.expression?.name;
  if (typeName !== "bytes32") return false;
  const argument = node.arguments?.[0];
  return argument?.nodeType === "Literal" && argument.kind === "number" && String(argument.value) === "0";
}

export function numericLiteral(node: AstNode): number | undefined {
  if (node?.nodeType !== "Literal" || node.kind !== "number") return undefined;
  const value = Number(node.value);
  return Number.isSafeInteger(value) ? value : undefined;
}
