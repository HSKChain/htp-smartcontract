export interface Eip712Field {
  name: string;
  type: string;
}

export type Eip712Types = Record<string, Eip712Field[]>;

const TYPE_PATTERN = /([A-Za-z_]\w*)\(([^)]*)\)/gu;

export function parseEip712TypeString(typeString: string): Eip712Types {
  const types: Eip712Types = {};
  for (const match of typeString.matchAll(TYPE_PATTERN)) {
    const name = match[1]!;
    const body = match[2]!;
    types[name] = body.length === 0
      ? []
      : body.split(",").map((part) => {
        const trimmed = part.trim();
        const split = trimmed.lastIndexOf(" ");
        if (split <= 0) {
          throw new Error(`Malformed EIP-712 field in ${name}: ${trimmed}`);
        }
        return { type: trimmed.slice(0, split), name: trimmed.slice(split + 1) };
      });
  }
  if (Object.keys(types).length === 0) {
    throw new Error(`Unable to parse EIP-712 type string: ${typeString}`);
  }
  return types;
}

export function mergeEip712Types(typeStrings: string[]): Eip712Types {
  const merged: Eip712Types = {};
  for (const typeString of typeStrings) {
    Object.assign(merged, parseEip712TypeString(typeString));
  }
  return merged;
}

export function encodeEip712TypeString(primaryType: string, types: Eip712Types): string {
  const dependencies = new Set<string>();
  const visit = (current: string) => {
    const name = current.match(/^\w*/u)?.[0];
    if (!name || dependencies.has(name) || types[name] === undefined) return;
    dependencies.add(name);
    for (const field of types[name]!) visit(field.type);
  };
  visit(primaryType);
  dependencies.delete(primaryType);
  return [primaryType, ...Array.from(dependencies).sort()]
    .map((name) => `${name}(${(types[name] ?? []).map((field) => `${field.type} ${field.name}`).join(",")})`)
    .join("");
}
