import { spawnSync } from "node:child_process";

const requiredVersion = "Python 3.12.11";
const consumerDirectory = "packages/schema-tools/golden-consumers/python";
const consumerPath = `${consumerDirectory}/consumer.py`;

/** @param {string} command */
function commandVersion(command) {
  const result = spawnSync(command, ["--version"], { encoding: "utf8" });
  if (result.error || result.status !== 0) return null;
  return `${result.stdout}${result.stderr}`.trim();
}

/** @param {string} command @param {string[]} args */
function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

for (const command of ["python3.12", "python"]) {
  if (commandVersion(command) === requiredVersion) {
    run(command, [consumerPath]);
    run(command, ["-m", "unittest", "discover", "-s", consumerDirectory, "-p", "test_*.py"]);
    process.exit(0);
  }
}

if (commandVersion("uv") !== null) {
  const uvPython = ["run", "--python", "3.12.11", "--project", consumerDirectory, "python"];
  run("uv", [...uvPython, consumerPath]);
  run("uv", [
    ...uvPython,
    "-m",
    "unittest",
    "discover",
    "-s",
    consumerDirectory,
    "-p",
    "test_*.py",
  ]);
  process.exit(0);
}

console.error(`${requiredVersion} or uv is required to run the portable schema consumer.`);
process.exit(1);
