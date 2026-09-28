import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { hashStruct, keccak256, serializeTransaction, toFunctionSelector } from "viem";
import {
  hashDeploymentVersion,
  hashEconomicAssetId,
  hashParticipantId,
  hashQuoteId,
  hashRfqId,
  hashTradeId,
} from "../../id-tools/src/identifiers.js";
import { VECTOR_PATHS, listRelativeFiles } from "./paths.js";
import { canonicalJson } from "./schema.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const zeroHash = `0x${"00".repeat(32)}`;
const address = (suffix: string): `0x${string}` => `0x${suffix.padStart(40, "0")}`;
const word = (suffix: string): `0x${string}` => `0x${suffix.padStart(64, "0")}`;

function identifierVectors() {
  const composed = "Café-基金-001";
  const decomposed = "Cafe\u0301-基金-001";
  const participantRef = Uint8Array.from({ length: 16 }, (_, index) => index + 1);
  const hashes = (value: string) => ({
    rfq: hashRfqId(value, 1),
    quote: hashQuoteId(value, 1),
    trade: hashTradeId(value, 1),
    economicAsset: hashEconomicAssetId(value, 1),
  });
  return {
    schemaVersion: 1,
    status: "candidate",
    formula:
      "keccak256(abi.encode(domainHash,schemaVersion,keccak256(canonicalNfcUtf8)))",
    positive: {
      nfcEquivalent: {
        inputs: [composed, decomposed],
        canonicalUtf8Hex: `0x${Buffer.from(composed.normalize("NFC")).toString("hex")}`,
        hashes: hashes(composed),
        equivalentHashes: hashes(decomposed),
      },
      oneByte: { input: "A", hashes: hashes("A") },
      max256Bytes: { input: "a".repeat(256), hashes: hashes("a".repeat(256)) },
      participant: {
        participantRefHex: `0x${Buffer.from(participantRef).toString("hex")}`,
        participantIdHash: hashParticipantId(participantRef),
      },
    },
    deploymentVersion: {
      format: "canonical ASCII numeric SemVer MAJOR.MINOR.PATCH",
      formula: "keccak256(abi.encode(keccak256(\"HTP_DEPLOYMENT_VERSION\"),keccak256(asciiVersion)))",
      positive: ["0.0.0", "1.2.3"].map((input) => ({
        input,
        deploymentVersionHash: hashDeploymentVersion(input),
      })),
      negative: [
        "v1.2.3",
        "01.2.3",
        "1.02.3",
        "1.2.03",
        "1.2",
        "1.2.3-beta",
        "1.2.3+build",
        "Café",
        "",
      ].map((input) => ({ input, expectedError: "INVALID_DEPLOYMENT_VERSION" })),
    },
    distinct: {
      case: { inputs: ["RFQ-001", "rfq-001"], hashes: [hashes("RFQ-001"), hashes("rfq-001")] },
      whitespace: { inputs: ["RFQ-001", " RFQ-001 "], hashes: [hashes("RFQ-001"), hashes(" RFQ-001 ")] },
    },
    negative: [
      { name: "invalidUtf8", inputHex: "0xc328", expectedError: "INVALID_UTF8" },
      { name: "controlCharacterCc", inputEscaped: "RFQ\\u0000", expectedError: "CONTROL_CHARACTER" },
      { name: "zeroBytes", input: "", expectedError: "LENGTH_OUT_OF_RANGE" },
      { name: "257Bytes", byteLength: 257, expectedError: "LENGTH_OUT_OF_RANGE" },
      { name: "shortParticipantRef", byteLength: 15, expectedError: "PARTICIPANT_REF_TOO_SHORT" },
    ],
  };
}

function revisionRules() {
  return {
    schemaVersion: 1,
    status: "candidate",
    linearRevisionRules: {
      firstRevision: 1,
      nextRevision: "latestRevision + 1",
      replaces: "previous config ID; zero only for revision 1",
      negative: ["revision gap", "duplicate revision", "wrong replaces ID", "non-latest transition"],
    },
    tokenDeploymentKind: {
      direct: { value: 1, implementation: address("0"), implementationCodeHash: zeroHash },
      erc1967Proxy: {
        value: 2,
        implementation: address("c002"),
        tokenCodeHash: word("a01"),
        implementationCodeHash: word("a02"),
      },
    },
  };
}

function feeVectors() {
  const scopes = ["ASSET_VERSION", "INSTRUMENT", "ASSET_CLASS", "CHAIN", "GLOBAL"];
  return {
    schemaVersion: 1,
    status: "candidate",
    resolverPriority: scopes,
    resolution: [
      ...scopes.map((scope, index) => ({
        name: `${scope.toLowerCase()}Hit`,
        configuredScopes: [scope],
        expectedScope: scope,
        fallbacksSkipped: index,
        expected: "success",
      })),
      {
        name: "noMatch",
        configuredScopes: [],
        expected: "error",
        expectedError: "FeeResolverNoMatch",
      },
    ],
    // 金额向量已迁往 amounts-v1.json：那份由 packages/calc-reference/src/fees.ts
    // 现算生成，并被 TS 与 Solidity 双端消费。这里原先硬编码过一份同参数的期望值，
    // 但没有任何东西核对它——FeeMath 一改，那份会静默失真却照样发布给下游。
    // 同一个事实只保留一个来源。
    amountVectors: "vectors/fees/amounts-v1.json",
    epochBoundaries: [
      { status: "ACTIVE", quote: true, settlement: true },
      { status: "LEGACY_SERVING", quote: false, settlement: true },
      { status: "CLOSED", quote: false, settlement: false },
      { status: "DEPRECATED_FEE_VERSION", quote: false, settlement: "only already-snapshotted TCB" },
    ],
    rolloverInvariant: "exactly one ACTIVE epoch after rollover",
  };
}

function settlementVectors() {
  const base = {
    cashPrincipal: "1000000",
    buyerFee: "2000",
    sellerFee: "1500",
    buyerDebit: "1002000",
    sellerCredit: "998500",
    collectorCredit: "3500",
  };
  return {
    schemaVersion: 1,
    status: "candidate",
    cases: [
      {
        name: "buy",
        requesterSide: "BUY",
        requester: address("b002"),
        buyer: address("b002"),
        seller: address("b001"),
        amounts: base,
      },
      {
        name: "sell",
        requesterSide: "SELL",
        requester: address("b001"),
        buyer: address("b002"),
        seller: address("b001"),
        amounts: base,
      },
      {
        name: "zeroSellerCreditLeg",
        requesterSide: "BUY",
        amounts: {
          cashPrincipal: "1000",
          buyerFee: "20",
          sellerFee: "1000",
          buyerDebit: "1020",
          sellerCredit: "0",
          collectorCredit: "1020",
        },
        expectedTransferLegs: ["ASSET", "SETTLEMENT_BUYER_DEBIT", "SETTLEMENT_TO_COLLECTOR"],
        skippedAdapterLegs: ["SETTLEMENT_TO_SELLER"],
        expected: "success",
      },
      {
        name: "zeroCollectorCreditLeg",
        requesterSide: "SELL",
        amounts: {
          cashPrincipal: "1000000",
          buyerFee: "0",
          sellerFee: "0",
          buyerDebit: "1000000",
          sellerCredit: "1000000",
          collectorCredit: "0",
        },
        expectedTransferLegs: ["ASSET", "SETTLEMENT_BUYER_DEBIT", "SETTLEMENT_TO_SELLER"],
        skippedAdapterLegs: ["SETTLEMENT_TO_COLLECTOR"],
        expected: "success",
      },
    ],
    permits: [
      {
        name: "disabledCanonical",
        input: {
          usePermit: false,
          owner: address("0"),
          token: address("0"),
          value: "0",
          deadline: "0",
          v: 0,
          r: zeroHash,
          s: zeroHash,
        },
        expected: "skip",
      },
      {
        name: "ownerMismatch",
        input: { usePermit: true, owner: address("dead"), token: address("c001"), value: "1002000" },
        expected: "error",
        expectedError: "PermitFieldMismatch",
        signatureMaterial: "intentionally omitted",
      },
      {
        name: "enabledExactFields",
        input: {
          usePermit: true,
          owner: address("b002"),
          token: address("c001"),
          value: "1002000",
          deadline: "1784900000",
          capability: "EIP2612",
        },
        expected: "field-validation-success",
        signatureMaterial: "intentionally omitted",
      },
      {
        name: "unsupportedCapability",
        input: { usePermit: true, owner: address("b002"), token: address("c001"), value: "1002000" },
        expected: "error",
        expectedError: "PermitUnsupported",
        signatureMaterial: "intentionally omitted",
      },
    ],
  };
}

function usdyVector() {
  const candidateAddresses = {
    token: address("1001"),
    blocklist: address("1002"),
    allowlist: address("1003"),
    sanctionsList: address("1004"),
  };
  const deploymentByTarget = {
    token: {
      deploymentKind: "ERC1967_PROXY",
      implementation: address("1005"),
      implementationCodeHash: word("1105"),
    },
    blocklist: {
      deploymentKind: "DIRECT",
    },
    allowlist: {
      deploymentKind: "ERC1967_PROXY",
      implementation: address("1006"),
      implementationCodeHash: word("1106"),
    },
    sanctionsList: {
      deploymentKind: "DIRECT",
    },
  } as const;
  const capabilities = {
    tokenStandard: 1,
    restrictionMode: 4,
    precheckMethod: 3,
    transferLegMask: 2n,
  };
  const providerInputs = [
    { target: "token", selectorSignature: "paused()", codeHash: word("1101") },
    { target: "token", selectorSignature: "blocklist()", codeHash: word("1101") },
    { target: "token", selectorSignature: "allowlist()", codeHash: word("1101") },
    { target: "token", selectorSignature: "sanctionsList()", codeHash: word("1101") },
    { target: "blocklist", selectorSignature: "isBlocked(address)", codeHash: word("1102") },
    { target: "allowlist", selectorSignature: "isAllowed(address)", codeHash: word("1103") },
    { target: "sanctionsList", selectorSignature: "isSanctioned(address)", codeHash: word("1104") },
  ] as const;
  const providerEntries = providerInputs.map((entry) => ({
    ...entry,
    ...deploymentByTarget[entry.target],
    provider: candidateAddresses[entry.target],
    selector: toFunctionSelector(entry.selectorSignature),
    codeHash: entry.codeHash,
  })).sort((left, right) =>
    `${left.provider}${left.selector.slice(2)}${left.codeHash.slice(2)}`.localeCompare(
      `${right.provider}${right.selector.slice(2)}${right.codeHash.slice(2)}`,
    )
  );
  const providers = providerEntries.map(({ provider, selector, codeHash }) => ({
    provider,
    selector,
    codeHash,
  }));
  const types = {
    AdapterCapabilities: [
      { name: "tokenStandard", type: "uint8" },
      { name: "restrictionMode", type: "uint8" },
      { name: "precheckMethod", type: "uint8" },
      { name: "transferLegMask", type: "uint256" },
    ],
    RestrictionProvider: [
      { name: "provider", type: "address" },
      { name: "selector", type: "bytes4" },
      { name: "codeHash", type: "bytes32" },
    ],
    RestrictionProviderSet: [{ name: "providers", type: "RestrictionProvider[]" }],
  };
  return {
    schemaVersion: 1,
    status: "candidate",
    approval: "NOT_PRODUCTION_APPROVED",
    evidenceBlock: null,
    network: "ethereum-candidate",
    warning: "Addresses, code hashes, provider set and transferLegMask require a fixed-block approval package.",
    capabilities: {
      tokenStandard: { name: "ERC20", value: capabilities.tokenStandard },
      restrictionMode: { name: "TOKEN_ENFORCED", value: capabilities.restrictionMode },
      precheckMethod: { name: "TOKEN_SPECIFIC_CHECK", value: capabilities.precheckMethod },
      transferLegMask: "2",
      coveredLegs: ["ASSET"],
      capabilityHash: hashStruct({
        data: capabilities,
        primaryType: "AdapterCapabilities",
        types,
      }),
    },
    candidateAddresses,
    tokenBaseline: {
      deploymentKind: "ERC1967_PROXY",
      decimals: 18,
      tokenCodeHash: word("1101"),
      implementation: address("1005"),
      implementationCodeHash: word("1105"),
    },
    providerEntries,
    providerHash: hashStruct({
      data: { providers },
      primaryType: "RestrictionProviderSet",
      types,
    }),
    negative: [
      "provider address drift",
      "provider code hash drift",
      "provider call failure",
      "token paused",
      "blocked account",
      "not allowlisted",
      "sanctioned account",
      "unapproved DvP caller",
    ],
  };
}

const boundaryHeader = { schemaVersion: 1, status: "candidate", boundaryOnly: true };

function quoteBoundary() {
  const quoteHash = word("a01");
  const snapshotHash = word("a02");
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "activeFirmReservedConsumed",
        initialState: "ACTIVE_FIRM",
        proposedHashes: [quoteHash],
        canonicalSnapshotHash: snapshotHash,
        canonicalSnapshotSignatureVerified: true,
        actions: ["RESERVE", "CONSUME"],
        expectedState: "CONSUMED",
      },
      {
        name: "activeFirmReservedExpired",
        initialState: "ACTIVE_FIRM",
        proposedHashes: [quoteHash],
        canonicalSnapshotHash: null,
        canonicalSnapshotSignatureVerified: false,
        actions: ["RESERVE", "EXPIRE"],
        expectedState: "EXPIRED",
      },
    ],
    negative: [
      {
        name: "secondProposedHash",
        initialState: "ACTIVE_FIRM",
        proposedHashes: [quoteHash, word("a03")],
        canonicalSnapshotHash: null,
        canonicalSnapshotSignatureVerified: false,
        actions: ["RESERVE"],
        expectedError: "SECOND_PROPOSED_HASH_FORBIDDEN",
      },
      {
        name: "reservedCancellation",
        initialState: "RESERVED",
        proposedHashes: [quoteHash],
        canonicalSnapshotHash: null,
        canonicalSnapshotSignatureVerified: false,
        actions: ["CANCEL"],
        expectedError: "RESERVED_CANNOT_CANCEL",
      },
      {
        name: "reservedRollback",
        initialState: "RESERVED",
        proposedHashes: [quoteHash],
        canonicalSnapshotHash: null,
        canonicalSnapshotSignatureVerified: false,
        actions: ["ROLLBACK_ACTIVE_FIRM"],
        expectedError: "RESERVED_CANNOT_ROLLBACK",
      },
      {
        name: "unverifiedCanonicalSnapshot",
        initialState: "RESERVED",
        proposedHashes: [quoteHash],
        canonicalSnapshotHash: snapshotHash,
        canonicalSnapshotSignatureVerified: false,
        actions: ["CONSUME"],
        expectedError: "CANONICAL_SNAPSHOT_SIGNATURE_REQUIRED",
      },
    ],
  };
}

function inventoryBoundary() {
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "heldCommittedReleased",
        initialState: "HELD",
        actions: ["COMMIT", "RELEASE_FINALIZED"],
        tradeStatus: "FINALIZED",
        maxQuantity: "100",
        finalQuantity: "80",
        expectedReleaseQuantity: "20",
        availableQuantity: "200",
        concurrentHolds: ["60", "40"],
        expectedState: "RELEASED",
      },
      {
        name: "maxFinalDifference",
        initialState: "COMMITTED",
        actions: ["RELEASE_FINALIZED"],
        tradeStatus: "FINALIZED",
        maxQuantity: "1000",
        finalQuantity: "875",
        expectedReleaseQuantity: "125",
        availableQuantity: "1000",
        concurrentHolds: [],
        expectedState: "RELEASED",
      },
      {
        name: "heldCapacityBoundary",
        initialState: "HELD",
        actions: [],
        tradeStatus: "UNSIGNED",
        maxQuantity: "100",
        finalQuantity: "100",
        expectedReleaseQuantity: "0",
        availableQuantity: "100",
        concurrentHolds: ["70", "30"],
        expectedState: "HELD",
      },
    ],
    negative: [
      {
        name: "concurrentOverReservation",
        initialState: "HELD",
        actions: [],
        tradeStatus: "UNSIGNED",
        maxQuantity: "110",
        finalQuantity: "110",
        expectedReleaseQuantity: "0",
        availableQuantity: "100",
        concurrentHolds: ["70", "40"],
        expectedError: "CONCURRENT_HOLD_EXCEEDS_AVAILABLE",
      },
      {
        name: "signedEarlyRelease",
        initialState: "HELD",
        actions: ["RELEASE"],
        tradeStatus: "SIGNED",
        maxQuantity: "100",
        finalQuantity: "80",
        expectedReleaseQuantity: "20",
        availableQuantity: "100",
        concurrentHolds: ["100"],
        expectedError: "SIGNED_INVENTORY_EARLY_RELEASE",
      },
    ],
  };
}

function feeBoundary() {
  const evidence = {
    feePolicyEpoch: "7",
    feeVersionId: word("b01"),
    feeConstraintHash: word("b02"),
    resolverScope: "ASSET_VERSION",
    signedAt: "1779999999",
    deprecatedAt: "1780000000",
  };
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "signedBeforeDeprecationEvidence",
        status: "DEPRECATED",
        operation: "SETTLE",
        evidence,
        callerSelectedScope: null,
        expected: "success",
      },
    ],
    negative: [
      ...["GENERATE", "SIGN", "BROADCAST"].map((operation) => ({
        name: `deprecatedNew${operation[0]}${operation.slice(1).toLowerCase()}`,
        status: "DEPRECATED",
        operation,
        attemptedAt: "1780000001",
        evidence,
        callerSelectedScope: null,
        expectedError: `DEPRECATED_${operation}_FORBIDDEN`,
      })),
      {
        name: "callerSelectedResolverScope",
        status: "ACTIVE",
        operation: "GENERATE",
        attemptedAt: "1779999000",
        evidence,
        callerSelectedScope: "GLOBAL",
        expectedError: "CALLER_SCOPE_SELECTION_FORBIDDEN",
      },
    ],
  };
}

function kmsExecutorBoundary() {
  const legacyUnsignedPreimage = serializeTransaction({
    chainId: 31_337,
    nonce: 7,
    gas: 21_000n,
    gasPrice: 1_000_000_000n,
    to: address("d001"),
    value: 0n,
    data: "0x",
  });
  const type2UnsignedPreimage = serializeTransaction({
    type: "eip1559",
    chainId: 31_337,
    nonce: 8,
    gas: 300_000n,
    maxFeePerGas: 2_000_000_000n,
    maxPriorityFeePerGas: 100_000_000n,
    to: address("d001"),
    value: 0n,
    data: "0x12345678",
    accessList: [],
  });
  const legacyHash = keccak256(legacyUnsignedPreimage);
  const type2Hash = keccak256(type2UnsignedPreimage);
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "legacyUnsignedPreimage",
        kind: "UNSIGNED_PREIMAGE",
        transactionType: "LEGACY",
        envelope: {
          chainId: "31337",
          nonce: "7",
          gasPrice: "1000000000",
          gasLimit: "21000",
          to: address("d001"),
          value: "0",
          data: "0x",
        },
        unsignedPreimage: legacyUnsignedPreimage,
        accessList: null,
        expectedHash: legacyHash,
      },
      {
        name: "type2EmptyAccessListPreimage",
        kind: "UNSIGNED_PREIMAGE",
        transactionType: "TYPE2",
        envelope: {
          chainId: "31337",
          nonce: "8",
          maxPriorityFeePerGas: "100000000",
          maxFeePerGas: "2000000000",
          gasLimit: "300000",
          to: address("d001"),
          value: "0",
          data: "0x12345678",
          accessList: [],
        },
        unsignedPreimage: type2UnsignedPreimage,
        accessList: [],
        expectedHash: type2Hash,
      },
      {
        name: "singleKeccakDigestSigningIntent",
        kind: "SIGNING_INTENT",
        intent: {
          transactionType: "TYPE2",
          digest: type2Hash,
          digestSource: "LOCAL_UNSIGNED_PREIMAGE",
          hashPasses: 1,
          messageType: "DIGEST",
          prehashed: true,
          opaqueRawReference: "opaque-ref:executor/type2/001",
          expectedRawTransactionHash: word("c01"),
          rawMaterialStored: false,
        },
      },
      {
        name: "exactRawHashOpaqueReference",
        kind: "RAW_REFERENCE",
        expectedRawTransactionHash: word("c02"),
        opaqueRawReference: "opaque-ref:executor/raw/002",
        rawMaterialStored: false,
      },
      {
        name: "replacementSameGenerationNonce",
        kind: "REPLACEMENT",
        previous: { generation: "4", nonce: "9", maxFeePerGas: "2000000000" },
        replacement: { generation: "4", nonce: "9", maxFeePerGas: "2500000000" },
      },
      {
        name: "canonicalRevertNewGenerationNonce",
        kind: "CANONICAL_REVERT_RETRY",
        previous: { generation: "4", nonce: "9" },
        retry: { generation: "5", nonce: "10" },
      },
      {
        name: "sameNonceCancellation",
        kind: "CANCELLATION",
        active: { generation: "5", nonce: "10" },
        cancellation: { generation: "5", nonce: "10", toSelf: true, value: "0" },
      },
    ],
    negative: [
      {
        name: "type2NonEmptyAccessList",
        kind: "UNSIGNED_PREIMAGE",
        transactionType: "TYPE2",
        envelope: {
          chainId: "31337",
          nonce: "8",
          maxPriorityFeePerGas: "100000000",
          maxFeePerGas: "2000000000",
          gasLimit: "300000",
          to: address("d001"),
          value: "0",
          data: "0x12345678",
          accessList: [{ address: address("d002"), storageKeys: [] }],
        },
        unsignedPreimage: type2UnsignedPreimage,
        accessList: [{ address: address("d002"), storageKeys: [] }],
        expectedHash: type2Hash,
        expectedError: "TYPE2_ACCESS_LIST_MUST_BE_EMPTY",
      },
      {
        name: "doubleKeccak",
        kind: "SIGNING_INTENT",
        intent: {
          transactionType: "TYPE2",
          digest: type2Hash,
          digestSource: "LOCAL_UNSIGNED_PREIMAGE",
          hashPasses: 2,
          messageType: "DIGEST",
          prehashed: true,
          opaqueRawReference: "opaque-ref:executor/type2/003",
          expectedRawTransactionHash: word("c03"),
          rawMaterialStored: false,
        },
        expectedError: "DIGEST_MUST_BE_SINGLE_KECCAK",
      },
      {
        name: "untrustedExternalDigest",
        kind: "SIGNING_INTENT",
        intent: {
          transactionType: "LEGACY",
          digest: legacyHash,
          digestSource: "EXTERNAL_CALLER",
          hashPasses: 1,
          messageType: "DIGEST",
          prehashed: true,
          opaqueRawReference: "opaque-ref:executor/legacy/004",
          expectedRawTransactionHash: word("c04"),
          rawMaterialStored: false,
        },
        expectedError: "UNTRUSTED_EXTERNAL_DIGEST",
      },
      {
        name: "replacementChangedGeneration",
        kind: "REPLACEMENT",
        previous: { generation: "4", nonce: "9", maxFeePerGas: "2000000000" },
        replacement: { generation: "5", nonce: "9", maxFeePerGas: "2500000000" },
        expectedError: "REPLACEMENT_GENERATION_MISMATCH",
      },
      {
        name: "replacementChangedNonce",
        kind: "REPLACEMENT",
        previous: { generation: "4", nonce: "9", maxFeePerGas: "2000000000" },
        replacement: { generation: "4", nonce: "10", maxFeePerGas: "2500000000" },
        expectedError: "REPLACEMENT_NONCE_MISMATCH",
      },
      {
        name: "canonicalRevertReusesGenerationNonce",
        kind: "CANONICAL_REVERT_RETRY",
        previous: { generation: "4", nonce: "9" },
        retry: { generation: "4", nonce: "9" },
        expectedError: "REVERT_RETRY_REQUIRES_NEW_GENERATION_NONCE",
      },
      {
        name: "cancellationWrongNonce",
        kind: "CANCELLATION",
        active: { generation: "5", nonce: "10" },
        cancellation: { generation: "5", nonce: "11", toSelf: true, value: "0" },
        expectedError: "CANCELLATION_NONCE_MISMATCH",
      },
      {
        name: "forbiddenRawOrKeyMaterial",
        kind: "RAW_REFERENCE",
        expectedRawTransactionHash: word("c05"),
        opaqueRawReference: "opaque-ref:executor/raw/005",
        rawMaterialStored: false,
        mutation: { addField: "privateKey", valueKind: "non-empty-sensitive-placeholder" },
        expectedError: "FORBIDDEN_SIGNING_MATERIAL",
      },
    ],
  };
}

function finalityBoundary() {
  return {
    ...boundaryHeader,
    confirmationThreshold: "64",
    positive: [
      {
        name: "canonicalReceipt",
        receiptCanonical: true,
        confirmations: "1",
        requestedState: "CONFIRMING",
        subgraphState: "DELAYED",
        expectedState: "CONFIRMING",
      },
      {
        name: "confirmationThresholdReached",
        receiptCanonical: true,
        confirmations: "64",
        requestedState: "FINAL",
        subgraphState: "SYNCED",
        expectedState: "FINAL",
      },
      {
        name: "subgraphDelayDoesNotChangeFinality",
        receiptCanonical: true,
        confirmations: "80",
        requestedState: "FINAL",
        subgraphState: "DELAYED",
        expectedState: "FINAL",
      },
      {
        name: "shallowReorgRollback",
        receiptCanonical: false,
        confirmations: "12",
        requestedState: "ROLLBACK_CONFIRMING",
        subgraphState: "SYNCED",
        expectedState: "CONFIRMING",
      },
    ],
    negative: [
      {
        name: "nonCanonicalReceiptAccepted",
        receiptCanonical: false,
        confirmations: "1",
        requestedState: "CONFIRMING",
        subgraphState: "SYNCED",
        expectedError: "CANONICAL_RECEIPT_REQUIRED",
      },
      {
        name: "belowThresholdFinal",
        receiptCanonical: true,
        confirmations: "63",
        requestedState: "FINAL",
        subgraphState: "SYNCED",
        expectedError: "CONFIRMATION_THRESHOLD_NOT_MET",
      },
      {
        name: "subgraphOnlyFinality",
        receiptCanonical: false,
        confirmations: "0",
        requestedState: "FINAL_FROM_SUBGRAPH",
        subgraphState: "SYNCED",
        expectedError: "SUBGRAPH_NOT_FINALITY_AUTHORITY",
      },
      {
        name: "shallowReorgWithoutRollback",
        receiptCanonical: false,
        confirmations: "12",
        requestedState: "KEEP_FINAL",
        subgraphState: "SYNCED",
        expectedError: "SHALLOW_REORG_REQUIRES_ROLLBACK",
      },
    ],
  };
}

function deepReorgBoundary() {
  const history = [word("d01"), word("d02")];
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "appendCorrectionPreservesHistory",
        before: { history },
        operation: {
          appendCorrectionRecord: word("d03"),
          deleteHistoryIds: [],
        },
        expected: { history: [...history, word("d03")] },
      },
    ],
    negative: [
      {
        name: "deleteHistoricalSettlement",
        before: { history },
        operation: {
          appendCorrectionRecord: word("d03"),
          deleteHistoryIds: [word("d01")],
        },
        expectedError: "HISTORY_DELETE_FORBIDDEN",
      },
      {
        name: "missingCorrectionAppend",
        before: { history },
        operation: {
          appendCorrectionRecord: null,
          deleteHistoryIds: [],
        },
        expectedError: "CORRECTION_RECORD_REQUIRED",
      },
    ],
  };
}

function subgraphBoundary() {
  return {
    ...boundaryHeader,
    positive: [
      {
        name: "projectEventExplicitChainId",
        eventKind: "PROJECT",
        networkContextChainId: "31337",
        inputs: [
          { name: "chainId", type: "uint256", value: "31337" },
          { name: "tradeIdHash", type: "bytes32", value: word("e01") },
        ],
        expectedChainId: "31337",
      },
      {
        name: "ozEventUsesNetworkContext",
        eventKind: "OZ_STANDARD",
        networkContextChainId: "31337",
        inputs: [{ name: "implementation", type: "address", value: address("e001") }],
        expectedChainId: "31337",
      },
    ],
    negative: [
      {
        name: "projectEventMissingChainId",
        eventKind: "PROJECT",
        networkContextChainId: "31337",
        inputs: [{ name: "tradeIdHash", type: "bytes32", value: word("e01") }],
        expectedError: "PROJECT_EVENT_CHAIN_ID_REQUIRED",
      },
      {
        name: "projectEventChainIdNotFirst",
        eventKind: "PROJECT",
        networkContextChainId: "31337",
        inputs: [
          { name: "tradeIdHash", type: "bytes32", value: word("e01") },
          { name: "chainId", type: "uint256", value: "31337" },
        ],
        expectedError: "PROJECT_EVENT_CHAIN_ID_MUST_BE_FIRST",
      },
      {
        name: "projectEventChainIdMismatch",
        eventKind: "PROJECT",
        networkContextChainId: "31337",
        inputs: [{ name: "chainId", type: "uint256", value: "1" }],
        expectedError: "PROJECT_EVENT_CHAIN_ID_MISMATCH",
      },
      {
        name: "ozEventMissingNetworkContext",
        eventKind: "OZ_STANDARD",
        networkContextChainId: null,
        inputs: [{ name: "implementation", type: "address", value: address("e001") }],
        expectedError: "OZ_EVENT_NETWORK_CHAIN_ID_REQUIRED",
      },
    ],
  };
}

function writeOrCheckDocuments(
  repositoryRoot: string,
  root: string,
  documents: Record<string, unknown>,
  label: string,
  write: boolean,
): boolean {
  let drift = false;
  for (const [relativePath, value] of Object.entries(documents)) {
    const path = resolve(root, relativePath);
    const expected = canonicalJson(value);
    if (write) {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, expected);
    } else if (!existsSync(path) || readFileSync(path, "utf8") !== expected) {
      console.error(`${label} drift detected: ${relative(repositoryRoot, path)}`);
      drift = true;
    }
  }
  return drift;
}

export function writeOrCheckPhase17(targetRoot: string, write: boolean): void {
  const schemaRoot = resolve(targetRoot, "schema/v1");
  const offchainRoot = resolve(targetRoot, "schema/off-chain/v1");
  const outputs: Record<string, unknown> = {
    [VECTOR_PATHS.identifiers]: identifierVectors(),
    [VECTOR_PATHS.revisionRules]: revisionRules(),
    [VECTOR_PATHS.fees]: feeVectors(),
    [VECTOR_PATHS.settlement]: settlementVectors(),
    [VECTOR_PATHS.adapters]: usdyVector(),
  };
  const offchainOutputs: Record<string, unknown> = {
    "quote.json": quoteBoundary(),
    "inventory.json": inventoryBoundary(),
    "fee-tcb.json": feeBoundary(),
    "kms-executor.json": kmsExecutorBoundary(),
    "finality.json": finalityBoundary(),
    "deep-reorg.json": deepReorgBoundary(),
    "subgraph.json": subgraphBoundary(),
  };

  let drift = false;
  if (write) {
    rmSync(offchainRoot, { recursive: true, force: true });
  }
  drift = writeOrCheckDocuments(targetRoot, schemaRoot, outputs, "phase17 vector", write) || drift;
  drift = writeOrCheckDocuments(targetRoot, offchainRoot, offchainOutputs, "off-chain fixture", write) || drift;

  const expectedOffchainFiles = Object.keys(offchainOutputs).sort();
  const actualOffchainFiles = listRelativeFiles(offchainRoot);
  if (canonicalJson(actualOffchainFiles) !== canonicalJson(expectedOffchainFiles)) {
    console.error("off-chain fixture drift detected: file set differs");
    console.error(`expected=${JSON.stringify(expectedOffchainFiles)}`);
    console.error(`actual=${JSON.stringify(actualOffchainFiles)}`);
    drift = true;
  }
  if (drift) throw new Error("phase17 vector or off-chain fixture drift detected");
  console.log(
    write ? "Generated Phase 17 vectors and off-chain fixtures" : "Phase 17 vectors and off-chain fixtures are current",
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  writeOrCheckPhase17(repositoryRoot, process.argv.includes("--write"));
}
