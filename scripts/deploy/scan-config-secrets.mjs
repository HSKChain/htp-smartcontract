import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { findForbiddenFields } from "./validate-config.mjs";

const repositoryRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const deployRoot = resolve(repositoryRoot, "deploy");

/** @param {string} directory @returns {string[]} */
function listJson(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) return listJson(path);
    return entry.name.endsWith(".json") ? [path] : [];
  });
}

const findings = listJson(deployRoot).flatMap((path) => {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return findForbiddenFields(value).map(
      (finding) => `${path.replace(`${repositoryRoot}/`, "")}: ${finding}`,
    );
  } catch (error) {
    return [
      `${path.replace(`${repositoryRoot}/`, "")}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    ];
  }
});

if (findings.length !== 0) {
  console.error(findings.join("\n"));
  process.exitCode = 1;
} else {
  console.log("Deployment configuration secret/PII scan passed");
}
