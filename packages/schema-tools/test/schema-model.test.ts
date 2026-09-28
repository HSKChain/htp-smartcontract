import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";

import { buildSchemaModel } from "../src/model.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");

test("SchemaModel reads FirmQuote fields and ABI layout from the HTPTypes AST", () => {
  const model = buildSchemaModel(repositoryRoot);
  const firmQuote = model.structs.FirmQuote;
  assert.ok(firmQuote);
  assert.deepEqual(
    firmQuote.fields.map((field) => field.name),
    [
      "schemaVersion",
      "rfqIdHash",
      "quoteIdHash",
      "quoteVersion",
      "quotingMaker",
      "requester",
      "requesterType",
      "assetVersionId",
      "requesterSide",
      "assetToken",
      "settlementToken",
      "assetClass",
      "priceTermsHash",
      "priceData",
      "principalCalculatorConfigId",
      "principalCalculatorConfigHash",
      "adapterConfigId",
      "adapterConfigHash",
      "settlementTokenConfigId",
      "settlementTokenConfigHash",
      "marketRuleConfigId",
      "marketRuleConfigHash",
      "minExecutableQuantity",
      "maxExecutableQuantity",
      "stepQuantity",
      "feePolicyEpoch",
      "feeVersionId",
      "matchedScopeHash",
      "feeConstraintHash",
      "quoteNonce",
      "expiresAt",
    ],
  );
  assert.equal(firmQuote.fields[6]?.abiType, "uint8");
  assert.equal(firmQuote.fields[6]?.solidityType, "ParticipantType");
  assert.equal(firmQuote.fields[6]?.kind, "enum");
  assert.equal(firmQuote.fields[13]?.abiType, "bytes");
  assert.equal(firmQuote.fields[13]?.dynamic, true);
  assert.equal(firmQuote.fields[13]?.headOffset, 13 * 32);
  assert.equal(firmQuote.dynamic, true);
  assert.equal(firmQuote.headByteLength, 31 * 32);
  assert.equal(model.schemaVersion, 1);
});

test("SchemaModel extracts EIP-712 type strings from HTPHashing AST constants", () => {
  const model = buildSchemaModel(repositoryRoot);
  const firmQuote = model.typehashes.FIRM_QUOTE_TYPEHASH;
  assert.equal(
    firmQuote?.typeString,
    "FirmQuote(uint32 schemaVersion,bytes32 rfqIdHash,bytes32 quoteIdHash,uint32 quoteVersion,address quotingMaker,address requester,uint8 requesterType,bytes32 assetVersionId,uint8 requesterSide,address assetToken,address settlementToken,uint8 assetClass,bytes32 priceTermsHash,bytes priceData,bytes32 principalCalculatorConfigId,bytes32 principalCalculatorConfigHash,bytes32 adapterConfigId,bytes32 adapterConfigHash,bytes32 settlementTokenConfigId,bytes32 settlementTokenConfigHash,bytes32 marketRuleConfigId,bytes32 marketRuleConfigHash,uint256 minExecutableQuantity,uint256 maxExecutableQuantity,uint256 stepQuantity,uint64 feePolicyEpoch,bytes32 feeVersionId,bytes32 matchedScopeHash,bytes32 feeConstraintHash,uint256 quoteNonce,uint64 expiresAt)",
  );
  assert.equal(
    firmQuote?.typeHash,
    "0x79db216dea763a9d67ad7df5570a388d4055c6ac896752086982d5db82bb597b",
  );
  assert.equal(model.domain.name, "HTP DvP Settlement");
});

test("SchemaModel extracts Roles and InterfaceVersions from AST keccak preimages", () => {
  const model = buildSchemaModel(repositoryRoot);
  const admin = model.roles.find((role) => role.name === "DEFAULT_ADMIN_ROLE");
  const governance = model.roles.find((role) => role.name === "GOVERNANCE_ROLE");
  assert.equal(admin?.preimage, null);
  assert.equal(admin?.value, `0x${"00".repeat(32)}`);
  assert.equal(governance?.preimage, "GOVERNANCE_ROLE");
  assert.equal(
    governance?.value,
    "0x71840dc4906352362b0cdaf79870196c8e42acafade72d5d5a6d59291253ceb1",
  );
  assert.equal(
    model.interfaceVersions.ASSET_ADAPTER_V1?.preimage,
    "HTP_IASSET_ADAPTER_V1",
  );
  assert.equal(
    model.interfaceVersions.PRINCIPAL_CALCULATOR_V1?.preimage,
    "HTP_IPRINCIPAL_CALCULATOR_V1",
  );
  assert.equal(model.interfaceVersions.PRINCIPAL_CALCULATOR_V2, undefined);
  assert.equal(
    model.configIdNamespaces.FEE_NAMESPACE?.preimage,
    "HTP_FEE_CONFIG",
  );
  assert.equal(
    model.feeScope.typeString,
    "FeeScope(uint64 feePolicyEpoch,uint8 scopeType,bytes32 scopeKeyHash)",
  );
});
