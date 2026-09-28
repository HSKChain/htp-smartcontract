import {
  encodeAbiParameters,
  keccak256,
  stringToHex,
  toHex,
  type Hex,
} from "viem";

export type CanonicalTextInput = string | Uint8Array;

const textDecoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const textEncoder = new TextEncoder();

const RFQ_ID_DOMAIN = keccak256(stringToHex("HTP_RFQ_ID"));
const QUOTE_ID_DOMAIN = keccak256(stringToHex("HTP_QUOTE_ID"));
const TRADE_ID_DOMAIN = keccak256(stringToHex("HTP_TRADE_ID"));
const ECONOMIC_ASSET_ID_DOMAIN = keccak256(stringToHex("HTP_ECONOMIC_ASSET_ID"));
const PARTICIPANT_ID_DOMAIN = keccak256(stringToHex("HTP_PARTICIPANT_ID"));
const DEPLOYMENT_VERSION_DOMAIN = keccak256(stringToHex("HTP_DEPLOYMENT_VERSION"));

function decodeStrictUtf8(input: CanonicalTextInput): string {
  if (input instanceof Uint8Array) {
    try {
      return textDecoder.decode(input);
    } catch {
      throw new TypeError("Identifier must contain valid UTF-8.");
    }
  }

  for (let index = 0; index < input.length; index += 1) {
    const codeUnit = input.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const next = input.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) {
        throw new TypeError("Identifier string contains an unpaired UTF-16 surrogate.");
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw new TypeError("Identifier string contains an unpaired UTF-16 surrogate.");
    }
  }
  return input;
}

export function normalizeCanonicalUtf8(input: CanonicalTextInput): Uint8Array {
  const canonical = decodeStrictUtf8(input).normalize("NFC");
  if (/\p{Cc}/u.test(canonical)) {
    throw new TypeError("Identifier must not contain Unicode control characters.");
  }

  const bytes = textEncoder.encode(canonical);
  if (bytes.length < 1 || bytes.length > 256) {
    throw new RangeError("Canonical identifier must contain 1..256 UTF-8 bytes.");
  }
  return bytes;
}

function requireSchemaVersion(schemaVersion: number): number {
  if (!Number.isInteger(schemaVersion) || schemaVersion < 0 || schemaVersion > 0xffff_ffff) {
    throw new RangeError("schemaVersion must be a uint32.");
  }
  return schemaVersion;
}

function hashCanonicalText(
  domain: Hex,
  input: CanonicalTextInput,
  schemaVersion: number,
): Hex {
  const canonicalBytes = normalizeCanonicalUtf8(input);
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint32" }, { type: "bytes32" }],
      [domain, requireSchemaVersion(schemaVersion), keccak256(toHex(canonicalBytes))],
    ),
  );
}

export function hashRfqId(input: CanonicalTextInput, schemaVersion: number): Hex {
  return hashCanonicalText(RFQ_ID_DOMAIN, input, schemaVersion);
}

export function hashQuoteId(input: CanonicalTextInput, schemaVersion: number): Hex {
  return hashCanonicalText(QUOTE_ID_DOMAIN, input, schemaVersion);
}

export function hashTradeId(input: CanonicalTextInput, schemaVersion: number): Hex {
  return hashCanonicalText(TRADE_ID_DOMAIN, input, schemaVersion);
}

export function hashEconomicAssetId(
  input: CanonicalTextInput,
  schemaVersion: number,
): Hex {
  return hashCanonicalText(ECONOMIC_ASSET_ID_DOMAIN, input, schemaVersion);
}

export function hashParticipantId(participantRef: Uint8Array): Hex {
  if (participantRef.length < 16) {
    throw new RangeError("participantRef must contain at least 16 bytes.");
  }
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [PARTICIPANT_ID_DOMAIN, keccak256(toHex(participantRef))],
    ),
  );
}

export function normalizeCanonicalDeploymentVersion(input: CanonicalTextInput): Uint8Array {
  const bytes = typeof input === "string" ? textEncoder.encode(input) : new Uint8Array(input);
  if (bytes.length < 5) {
    throw new TypeError("Deployment version must be canonical ASCII SemVer MAJOR.MINOR.PATCH.");
  }

  let dotCount = 0;
  let segmentStart = 0;
  const canonicalSegment = (start: number, end: number) =>
    end > start && (end - start === 1 || bytes[start] !== 0x30);
  for (let index = 0; index < bytes.length; index += 1) {
    const character = bytes[index]!;
    if (character >= 0x30 && character <= 0x39) continue;
    if (
      character !== 0x2e
      || dotCount === 2
      || !canonicalSegment(segmentStart, index)
    ) {
      throw new TypeError("Deployment version must be canonical ASCII SemVer MAJOR.MINOR.PATCH.");
    }
    dotCount += 1;
    segmentStart = index + 1;
  }
  if (dotCount !== 2 || !canonicalSegment(segmentStart, bytes.length)) {
    throw new TypeError("Deployment version must be canonical ASCII SemVer MAJOR.MINOR.PATCH.");
  }
  return bytes;
}

export function hashDeploymentVersion(input: CanonicalTextInput): Hex {
  const canonicalBytes = normalizeCanonicalDeploymentVersion(input);
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [DEPLOYMENT_VERSION_DOMAIN, keccak256(toHex(canonicalBytes))],
    ),
  );
}
