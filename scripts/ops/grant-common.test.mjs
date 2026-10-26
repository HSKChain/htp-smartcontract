// @ts-nocheck
// ponytail: Legacy JavaScript is covered by syntax checks and local-chain self-tests; migrate if expanded.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { grantAll, loadDeployment } from "./lib/grant-common.mjs";
import { safeErrorMessage } from "./lib/env.mjs";

const NEW_ADMIN = "0x0000000000000000000000000000000000001001";
const OLD_ADMIN = "0x0000000000000000000000000000000000001002";

test("admin handoff resumes after the old admin already renounced some targets", async () => {
  const tasks = [
    { role: "DEFAULT_ADMIN", name: "AlreadyTransferred", address: "0x0000000000000000000000000000000000002001" },
    { role: "DEFAULT_ADMIN", name: "PendingTransfer", address: "0x0000000000000000000000000000000000002002" },
  ];
  const newAdminTargets = new Set([tasks[0].address]);
  const oldAdminTargets = new Set([tasks[1].address]);
  const sent = [];
  const chain = {
    admin: { address: OLD_ADMIN },
    async hasRole(address, role, account) {
      if (role !== "DEFAULT_ADMIN") return false;
      return account === NEW_ADMIN ? newAdminTargets.has(address) : oldAdminTargets.has(address);
    },
    async send(address) {
      sent.push(address);
      newAdminTargets.add(address);
      return "0x01";
    },
  };

  assert.equal(await grantAll(chain, tasks, NEW_ADMIN, false), 1);
  assert.deepEqual(sent, [tasks[1].address]);
});

test("deployment reports must carry chain finality", () => {
  const directory = mkdtempSync(join(tmpdir(), "htp-grant-report-"));
  const reportPath = join(directory, "report.json");
  try {
    writeFileSync(reportPath, JSON.stringify({ metadata: { chainId: 133 } }));
    assert.throws(() => loadDeployment({ report: reportPath }), /finalityConfirmations 非法/u);
    writeFileSync(reportPath, JSON.stringify({ metadata: { chainId: 133, finalityConfirmations: 5 } }));
    assert.equal(loadDeployment({ report: reportPath }).finalityConfirmations, 5);
    assert.throws(
      () => loadDeployment({ report: reportPath, "finality-confirmations": "6" }),
      /不允许覆盖 finalityConfirmations/u,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("direct DvP grants require explicit finality", () => {
  const dvp = "0x0000000000000000000000000000000000002001";
  assert.throws(() => loadDeployment({ dvp }, []), /finalityConfirmations 非法/u);
  assert.equal(loadDeployment({ dvp, "finality-confirmations": "5" }, []).finalityConfirmations, 5);
});

test("RPC URLs are redacted from operational errors", () => {
  assert.equal(
    safeErrorMessage(new Error("request failed at https://rpc.example/v1/secret-token")),
    "request failed at [RPC URL redacted]",
  );
});
