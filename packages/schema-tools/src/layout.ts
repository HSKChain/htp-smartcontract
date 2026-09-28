export type FieldKind = "elementary" | "enum" | "struct" | "array";

export interface StructFieldModel {
  name: string;
  solidityType: string;
  abiType: string;
  kind: FieldKind;
  dynamic: boolean;
  headOffset: number;
  nestedStruct?: string;
  arrayLength?: number | null;
}

export interface StructModel {
  name: string;
  fields: StructFieldModel[];
  dynamic: boolean;
  headByteLength: number;
}

export function attachAbiLayout(structs: Record<string, Omit<StructModel, "fields" | "dynamic" | "headByteLength"> & {
  fields: Array<Omit<StructFieldModel, "headOffset" | "dynamic"> & { dynamic?: boolean }>;
}>): Record<string, StructModel> {
  const visiting = new Set<string>();
  const computed = new Map<string, StructModel>();

  const isDynamicStruct = (name: string): boolean => {
    const existing = computed.get(name);
    if (existing) return existing.dynamic;
    if (visiting.has(name)) {
      throw new Error(`Recursive struct layout is not supported: ${name}`);
    }
    visiting.add(name);
    const source = structs[name];
    if (!source) throw new Error(`Unknown struct ${name}`);
    const dynamic = source.fields.some((field) => fieldDynamic(field, isDynamicStruct));
    visiting.delete(name);
    return dynamic;
  };

  const fieldDynamic = (
    field: Omit<StructFieldModel, "headOffset" | "dynamic"> & { dynamic?: boolean },
    structDynamic: (name: string) => boolean,
  ): boolean => {
    if (field.kind === "array") {
      if (field.arrayLength === null || field.arrayLength === undefined) return true;
      if (field.nestedStruct) return structDynamic(field.nestedStruct);
      const baseAbiType = field.abiType.replace(/\[\d+\]$/u, "");
      return baseAbiType === "bytes" || baseAbiType === "string";
    }
    if (field.kind === "struct") {
      if (!field.nestedStruct) throw new Error(`Struct field ${field.name} is missing nestedStruct`);
      return structDynamic(field.nestedStruct);
    }
    return field.abiType === "bytes" || field.abiType === "string";
  };

  const headSlotsForStruct = (name: string): number => {
    const source = structs[name];
    if (!source) throw new Error(`Unknown struct ${name}`);
    let slots = 0;
    for (const field of source.fields) {
      if (fieldDynamic(field, isDynamicStruct)) {
        slots += 1;
        continue;
      }
      if (field.kind === "struct" && field.nestedStruct) {
        slots += headSlotsForStruct(field.nestedStruct);
        continue;
      }
      slots += 1;
    }
    return slots;
  };

  const finalize = (name: string): StructModel => {
    const existing = computed.get(name);
    if (existing) return existing;
    const source = structs[name];
    if (!source) throw new Error(`Unknown struct ${name}`);
    const fields: StructFieldModel[] = [];
    let offset = 0;
    for (const field of source.fields) {
      const dynamic = fieldDynamic(field, isDynamicStruct);
      fields.push({ ...field, dynamic, headOffset: offset });
      if (dynamic) {
        offset += 32;
      } else if (field.kind === "struct" && field.nestedStruct) {
        offset += headSlotsForStruct(field.nestedStruct) * 32;
      } else {
        offset += 32;
      }
    }
    const model: StructModel = {
      name,
      fields,
      dynamic: isDynamicStruct(name),
      headByteLength: offset,
    };
    computed.set(name, model);
    return model;
  };

  return Object.fromEntries(Object.keys(structs).sort().map((name) => [name, finalize(name)]));
}
