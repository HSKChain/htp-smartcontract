import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { Ajv2020 } from "ajv/dist/2020.js";

const repositoryRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const schemaPath = resolve(repositoryRoot, "deploy/config.schema.json");
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const securityLimitsSourcePath = resolve(
  repositoryRoot,
  "contracts/src/libraries/ProtocolSecurityLimits.sol",
);
const securityLimitsSource = readFileSync(securityLimitsSourcePath, "utf8");
const providerGasMatch = securityLimitsSource.match(
  /ADAPTER_PROVIDER_CALL_GAS_MAX\s*=\s*([0-9][0-9_]*)\s*;/u,
);
const calculatorGasMatch = securityLimitsSource.match(
  /PRINCIPAL_CALCULATOR_CALL_GAS\s*=\s*([0-9][0-9_]*)\s*;/u,
);
if (!providerGasMatch?.[1]) {
  throw new Error("Unable to extract ADAPTER_PROVIDER_CALL_GAS_MAX from Solidity");
}
if (!calculatorGasMatch?.[1]) {
  throw new Error("Unable to extract PRINCIPAL_CALCULATOR_CALL_GAS from Solidity");
}
export const soliditySecurityLimits = Object.freeze({
  adapterProviderCallGasMax: Number(providerGasMatch[1].replaceAll("_", "")),
  calculatorStaticcallGas: Number(calculatorGasMatch[1].replaceAll("_", "")),
});
if (
  schema.properties?.securityLimits?.properties?.adapterProviderCallGasMax?.const !==
  soliditySecurityLimits.adapterProviderCallGasMax
) {
  throw new Error("deploy/config.schema.json provider Gas maximum differs from Solidity authority");
}
if (
  schema.properties?.securityLimits?.properties?.calculatorStaticcallGas?.const !==
  soliditySecurityLimits.calculatorStaticcallGas
) {
  throw new Error("deploy/config.schema.json calculator Gas budget differs from Solidity authority");
}
const ajv = new Ajv2020({ allErrors: true, strict: true });
const validateSchema = ajv.compile(schema);

export const defaultConfigPaths = [
  "deploy/config.example.json",
  "deploy/chains/ethereum.placeholder.json",
  "deploy/chains/bsc.placeholder.json",
  "deploy/chains/hsk.placeholder.json",
];

const forbiddenExactKeys = new Set([
  "env",
  "dotenv",
  "envfile",
  "email",
  "customeremail",
  "phone",
  "customerphone",
  "mobile",
  "ssn",
  "passport",
  "passportnumber",
  "pii",
  "personallyidentifiableinformation",
  "fullname",
  "legalname",
  "mnemonic",
  "seedphrase",
]);

/** @param {string} key */
function isForbiddenField(key) {
  const normalized = key.toLowerCase().replaceAll(/[^a-z0-9]/gu, "");
  return (
    forbiddenExactKeys.has(normalized) ||
    normalized.includes("privatekey") ||
    normalized.includes("mnemonic") ||
    normalized.includes("seedphrase") ||
    normalized.includes("signature") ||
    normalized.includes("kms") ||
    normalized.includes("pii") ||
    normalized.includes("raw")
  );
}

/**
 * @param {unknown} value
 * @param {string} [path]
 * @returns {string[]}
 */
export function findForbiddenFields(value, path = "$") {
  if (Array.isArray(value)) {
    return value.flatMap((nested, index) => findForbiddenFields(nested, `${path}[${index}]`));
  }
  if (typeof value === "string") {
    const forbiddenValuePatterns = [
      /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/iu,
      /\barn:aws:kms:[a-z0-9-]+:\d{12}:key\/[0-9a-f-]{36}\b/iu,
      /\bprojects\/[^/\s]+\/locations\/[^/\s]+\/keyRings\/[^/\s]+\/cryptoKeys\/[^/\s]+/iu,
      /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/iu,
      /(?:^|[/\\])\.env(?:\.|$)/iu,
    ];
    return forbiddenValuePatterns.some((pattern) => pattern.test(value))
      ? [`${path}: forbidden value`]
      : [];
  }
  if (value === null || typeof value !== "object") return [];

  return Object.entries(value).flatMap(([key, nested]) => {
    const nestedPath = `${path}.${key}`;
    const ownFinding = isForbiddenField(key) ? [`${nestedPath}: forbidden field`] : [];
    return [...ownFinding, ...findForbiddenFields(nested, nestedPath)];
  });
}

/** @param {import("ajv").ErrorObject} error @returns {string} */
function schemaError(error) {
  const path = error.instancePath === "" ? "$" : error.instancePath;
  const property =
    error.keyword === "additionalProperties" && typeof error.params.additionalProperty === "string"
      ? ` '${error.params.additionalProperty}'`
      : "";
  return `${path}${property} ${error.message ?? "is invalid"}`;
}

/** @param {unknown} value @returns {string[]} */
function semanticErrors(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [];

  /** @type {string[]} */
  const errors = [];
  const config = /** @type {Record<string, unknown>} */ (value);
  const externalPolicy = config.externalPolicy;
  const network = config.network;
  if (
    externalPolicy !== null &&
    typeof externalPolicy === "object" &&
    !Array.isArray(externalPolicy) &&
    /** @type {Record<string, unknown>} */ (externalPolicy).approvalStatus === "UNAPPROVED" &&
    network !== null &&
    typeof network === "object" &&
    !Array.isArray(network) &&
    /** @type {Record<string, unknown>} */ (network).chainId !== null
  ) {
    errors.push("$.network.chainId must remain null while externalPolicy is UNAPPROVED");
  }

  if (config.mode === "LOCAL_TEST") {
    const deploymentInputs = config.deploymentInputs;
    if (
      deploymentInputs !== null &&
      typeof deploymentInputs === "object" &&
      !Array.isArray(deploymentInputs)
    ) {
      const inputs = /** @type {Record<string, unknown>} */ (deploymentInputs);
      const participants = inputs.participants;
      if (
        participants !== null &&
        typeof participants === "object" &&
        !Array.isArray(participants)
      ) {
        const localParticipants = /** @type {Record<string, unknown>} */ (participants);
        if (
          typeof localParticipants.maker === "string" &&
          typeof localParticipants.requester === "string" &&
          localParticipants.maker.toLowerCase() === localParticipants.requester.toLowerCase()
        ) {
          errors.push("$.deploymentInputs.participants: maker and requester must be distinct");
        }
      }

      const schedule = inputs.schedule;
      if (schedule !== null && typeof schedule === "object" && !Array.isArray(schedule)) {
        const localSchedule = /** @type {Record<string, unknown>} */ (schedule);
        const from = localSchedule.quoteValidFrom;
        const quoteUntil = localSchedule.quoteValidUntil;
        const settlementUntil = localSchedule.settlementValidUntil;
        if (
          typeof from === "number" &&
          typeof quoteUntil === "number" &&
          typeof settlementUntil === "number" &&
          !(from <= quoteUntil && quoteUntil <= settlementUntil)
        ) {
          errors.push(
            "$.deploymentInputs.schedule must satisfy quoteValidFrom <= quoteValidUntil <= settlementValidUntil",
          );
        }
      }

      const fee = inputs.fee;
      if (fee !== null && typeof fee === "object" && !Array.isArray(fee)) {
        const localFee = /** @type {Record<string, unknown>} */ (fee);
        for (const participant of ["investor", "maker"]) {
          const hasCap = localFee[`${participant}HasCap`];
          const capAmount = localFee[`${participant}CapAmount`];
          if (hasCap === false && capAmount !== 0) {
            errors.push(`$.deploymentInputs.fee.${participant}CapAmount must be zero when cap is disabled`);
          }
          if (hasCap === true && capAmount === 0) {
            errors.push(`$.deploymentInputs.fee.${participant}CapAmount must be positive when cap is enabled`);
          }
        }
      }

      const marketRule = inputs.marketRule;
      const tokens = inputs.tokens;
      if (
        marketRule !== null &&
        typeof marketRule === "object" &&
        !Array.isArray(marketRule) &&
        tokens !== null &&
        typeof tokens === "object" &&
        !Array.isArray(tokens)
      ) {
        const localRule = /** @type {Record<string, unknown>} */ (marketRule);
        const localTokens = /** @type {Record<string, unknown>} */ (tokens);
        if (localRule.priceDecimals !== localTokens.settlementTokenDecimals) {
          errors.push("$.deploymentInputs.marketRule.priceDecimals must match settlementTokenDecimals");
        }
        if (localRule.quantityDecimals !== localTokens.assetDecimals) {
          errors.push("$.deploymentInputs.marketRule.quantityDecimals must match assetDecimals");
        }
      }
    }
  }

  return errors;
}

/**
 * @param {unknown} value
 * @returns {{ valid: boolean, errors: string[] }}
 */
export function validateDeploymentConfig(value) {
  const errors = findForbiddenFields(value);
  if (!validateSchema(value)) {
    errors.push(...(validateSchema.errors ?? []).map(schemaError));
  }
  errors.push(...semanticErrors(value));
  return { valid: errors.length === 0, errors };
}

/**
 * Public orchestration seam. CHAIN_PLACEHOLDER can be structurally valid but is never deployable.
 * @param {unknown} value
 * @param {{ currentCreateNonce?: number }} [runtime]
 * @returns {{
 *   valid: boolean,
 *   mode: "LOCAL_TEST" | "CHAIN_PLACEHOLDER" | null,
 *   deployable: boolean,
 *   governanceReady: boolean,
 *   expectedFirstCreateNonce: number | null,
 *   errors: string[]
 * }}
 */
export function preflightDeploymentConfig(value, runtime = {}) {
  const validation = validateDeploymentConfig(value);
  /** @type {"LOCAL_TEST" | "CHAIN_PLACEHOLDER" | null} */
  let mode = null;
  /** @type {number | null} */
  let expectedFirstCreateNonce = null;
  let governanceReady = false;
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const config = /** @type {Record<string, unknown>} */ (value);
    const requestedMode = config.mode;
    if (requestedMode === "LOCAL_TEST" || requestedMode === "CHAIN_PLACEHOLDER") {
      mode = requestedMode;
    }
    if (
      mode === "LOCAL_TEST" &&
      typeof config.expectedFirstCreateNonce === "number" &&
      Number.isSafeInteger(config.expectedFirstCreateNonce) &&
      config.expectedFirstCreateNonce >= 0
    ) {
      expectedFirstCreateNonce = config.expectedFirstCreateNonce;
    }
    governanceReady = validation.valid && mode === "LOCAL_TEST";
  }

  const preflightErrors = [...validation.errors];
  if (mode === "LOCAL_TEST") {
    const currentCreateNonce = runtime.currentCreateNonce;
    if (currentCreateNonce === undefined) {
      preflightErrors.push(
        "$.expectedFirstCreateNonce: currentCreateNonce is required for deployment preflight",
      );
    } else if (!Number.isSafeInteger(currentCreateNonce) || currentCreateNonce < 0) {
      preflightErrors.push("$.currentCreateNonce must be a non-negative JSON-safe uint64 integer");
    } else if (
      expectedFirstCreateNonce !== null &&
      expectedFirstCreateNonce !== currentCreateNonce
    ) {
      preflightErrors.push(
        `$.expectedFirstCreateNonce is stale: configured ${expectedFirstCreateNonce}, currentCreateNonce ${currentCreateNonce}`,
      );
    }
  }

  const valid = validation.valid && preflightErrors.length === 0;
  return {
    valid,
    mode,
    deployable: valid && mode === "LOCAL_TEST",
    governanceReady,
    expectedFirstCreateNonce,
    errors: preflightErrors,
  };
}

/** @param {string} path @returns {string[]} */
function validateFile(path) {
  const absolutePath = resolve(repositoryRoot, path);
  try {
    const value = JSON.parse(readFileSync(absolutePath, "utf8"));
    return validateDeploymentConfig(value).errors.map((error) => `${path}: ${error}`);
  } catch (error) {
    return [`${path}: ${error instanceof Error ? error.message : String(error)}`];
  }
}

/** @param {string[]} paths */
function main(paths) {
  const requestedPaths = paths.length === 0 ? defaultConfigPaths : paths;
  const errors = requestedPaths.flatMap(validateFile);
  if (errors.length !== 0) {
    console.error(errors.join("\n"));
    process.exitCode = 1;
    return;
  }
  console.log(`Validated ${requestedPaths.length} deployment configuration files`);
}

const invokedPath = process.argv[1] === undefined ? undefined : pathToFileURL(resolve(process.argv[1])).href;
if (invokedPath === import.meta.url) main(process.argv.slice(2));
