import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

import { writeOrCheckCalculator } from "../../calc-reference/src/generate.js";
import { writeOrCheckFeeCalculator } from "../../calc-reference/src/generate-fees.js";
import { writeOrCheckPhase17 } from "./phase17.js";
import { assertVectorFileSet } from "./paths.js";
import {
  buildSchemaBundle,
  checkSchemaDirectory,
  schemaV1Directory,
  writeSchemaDirectory,
} from "./schema.js";
import { checkSchemaLayoutTests, writeSchemaLayoutTests } from "./solidity-layout.js";
import { checkSchemaFixtures, writeSchemaFixtures } from "./solidity-fixtures.js";
import { writeOrCheckConstants } from "./verify/constants.js";
import { writeOrCheckVectors } from "./vectors.js";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const command = process.argv[2];

if (command !== "generate" && command !== "check") {
  console.error("Usage: cli.ts <generate|check>");
  process.exit(2);
}

execFileSync("forge", ["clean", "--root", "contracts"], {
  cwd: repositoryRoot,
  stdio: "inherit",
});
execFileSync("forge", ["build", "--root", "contracts", "--skip", "test"], {
  cwd: repositoryRoot,
  stdio: "inherit",
});

const write = command === "generate";
const bundle = buildSchemaBundle(repositoryRoot);
const target = schemaV1Directory(repositoryRoot);

if (write) {
  writeSchemaDirectory(bundle, target);
} else {
  checkSchemaDirectory(bundle, target);
}
writeOrCheckVectors(repositoryRoot, write);
writeOrCheckConstants(repositoryRoot, write);
if (write) {
  const fixtures = writeSchemaFixtures(repositoryRoot);
  const layoutTests = writeSchemaLayoutTests(repositoryRoot);
  console.log(`Generated candidate schema at ${target}`);
  console.log(`Generated Foundry fixtures at ${fixtures}`);
  console.log(`Generated Foundry layout tests at ${layoutTests}`);
} else {
  checkSchemaFixtures(repositoryRoot);
  checkSchemaLayoutTests(repositoryRoot);
}
writeOrCheckCalculator(repositoryRoot, write);
writeOrCheckFeeCalculator(repositoryRoot, write);
writeOrCheckPhase17(repositoryRoot, write);
assertVectorFileSet(repositoryRoot);
if (!write) {
  console.log(`Candidate schema is current at ${target}`);
}
