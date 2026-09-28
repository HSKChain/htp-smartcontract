import assert from "node:assert/strict";
import test from "node:test";
import {
  hashDeploymentVersion,
  hashEconomicAssetId,
  hashParticipantId,
  hashQuoteId,
  hashRfqId,
  hashTradeId,
  normalizeCanonicalDeploymentVersion,
  normalizeCanonicalUtf8,
} from "../src/identifiers.js";

test("RFQ ID uses strict UTF-8, NFC, byte limits, and RFQ domain", () => {
  assert.equal(
    hashRfqId("RFQ-Cafe\u0301-001", 1),
    "0x416bfb1896bbd1fc1f99ed65b182bfcb47c7e5e712f4267414fec0e7732481c3",
  );
  assert.throws(() => normalizeCanonicalUtf8(new Uint8Array([0xc3, 0x28])), /UTF-8/);
  assert.throws(() => normalizeCanonicalUtf8(""), /1..256/);
  assert.throws(() => normalizeCanonicalUtf8("a".repeat(257)), /1..256/);
  assert.throws(() => normalizeCanonicalUtf8("RFQ\n001"), /control/);
});

test("strict byte decoding preserves a leading UTF-8 BOM", () => {
  const withBom = Uint8Array.from([0xef, 0xbb, 0xbf, 0x41]);
  assert.deepEqual(normalizeCanonicalUtf8(withBom), withBom);
  assert.notEqual(hashRfqId(withBom, 1), hashRfqId("A", 1));
});

test("Quote ID preserves case and whitespace after NFC", () => {
  const canonical = hashQuoteId(" Quote-ABC ", 1);
  assert.equal(canonical, "0x150c95beefa34aa8b14086fef3a65b6ed4feac738e62f68f51cee1922e2d352f");
  assert.equal(hashQuoteId(" Quote-Café ", 1), hashQuoteId(" Quote-Cafe\u0301 ", 1));
  assert.notEqual(canonical, hashQuoteId("quote-abc", 1));
  assert.notEqual(canonical, hashQuoteId("Quote-ABC", 1));
});

test("Trade ID has an independent domain and canonical hash is reusable", () => {
  const tradeIdHash = hashTradeId("trade-abc", 1);
  assert.equal(tradeIdHash, "0x3911da5de840dfb65fe9dc2cafbc6fa5dcf4ad4d1a6ff792a6180e32cd855747");
  assert.notEqual(tradeIdHash, hashRfqId("trade-abc", 1));
  assert.notEqual(tradeIdHash, hashQuoteId("trade-abc", 1));
});

test("Economic asset ID uses NFC, schema version, and no chain address", () => {
  assert.equal(
    hashEconomicAssetId("BOND-Cafe\u0301", 1),
    "0x363b2f86d78b5489cd9ba7cd4bd72589fcc02eca5c2b371a5e15d635a33030c7",
  );
  assert.equal(hashEconomicAssetId("BOND-Café", 1), hashEconomicAssetId("BOND-Cafe\u0301", 1));
});

test("Participant ID requires at least 128 bits of opaque entropy input", () => {
  const participantRef = Uint8Array.from({ length: 16 }, (_, index) => index);
  assert.equal(
    hashParticipantId(participantRef),
    "0xe1b532320554c2de18b96f97a337c0a333c5e6153c261e4b2b321667eac5ebe8",
  );
  assert.throws(() => hashParticipantId(participantRef.subarray(0, 15)), /16 bytes/);
});

test("Deployment version matches canonical ASCII numeric SemVer", () => {
  assert.equal(
    hashDeploymentVersion("1.2.3"),
    "0x51c5fe1d20ac02d40c1a23e4c9231429cf03867d0158f3cb9ecc7277cb8cef42",
  );
  assert.doesNotThrow(() => hashDeploymentVersion("0.0.0"));
  assert.deepEqual(normalizeCanonicalDeploymentVersion("1.2.3"), new TextEncoder().encode("1.2.3"));
  for (const invalid of [
    "v1.2.3",
    "01.2.3",
    "1.02.3",
    "1.2.03",
    "1.2",
    "1.2.3-beta",
    "1.2.3+build",
    "Café",
    "",
  ]) {
    assert.throws(() => hashDeploymentVersion(invalid), /canonical ASCII SemVer/, invalid);
  }
});
