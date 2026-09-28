import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export function writeFormattedSolidity(
  repositoryRoot: string,
  relativeToContracts: string,
  contents: string,
): string {
  const contractsRoot = resolve(repositoryRoot, "contracts");
  const path = resolve(contractsRoot, relativeToContracts);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
  execFileSync("forge", ["fmt", relativeToContracts], {
    cwd: contractsRoot,
    stdio: "inherit",
  });
  return path;
}

export function checkFormattedSolidity(
  repositoryRoot: string,
  relativeToContracts: string,
  contents: string,
): void {
  const contractsRoot = resolve(repositoryRoot, "contracts");
  const path = resolve(contractsRoot, relativeToContracts);
  const tmpRelative = relativeToContracts.replace(/\.sol$/u, ".check.sol");
  const tmpPath = resolve(contractsRoot, tmpRelative);
  writeFileSync(tmpPath, contents);
  try {
    execFileSync("forge", ["fmt", tmpRelative], {
      cwd: contractsRoot,
      stdio: "pipe",
    });
    const formatted = readFileSync(tmpPath);
    const committed = readFileSync(path);
    if (!formatted.equals(committed)) {
      throw new Error(`generated Solidity drift: ${relativeToContracts}`);
    }
  } finally {
    rmSync(tmpPath, { force: true });
  }
}
