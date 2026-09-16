# Contract testing rules

Tests follow the public seams approved in `tasks.md`:

1. `DvPSettlement` public ABI.
2. The eight Registry public ABIs.
3. Principal Calculator and Asset Adapter public ABIs.
4. Pure date, canonical Hash, Config ID, EIP-712, Config Hash and strict Token
   metadata/deployment-validation foundations consumed by those production ABIs.
5. Solidity-generated manifest and golden vectors.
6. Static security gates for bytecode, storage layout, reproducible builds,
   dependency locks, and secret scanning.

The sixth seam verifies static constraints only. It never replaces observable
public-ABI behavior tests.

## Red → Green workflow

For each public behavior task:

1. Add exactly one observable failing behavior.
2. Run the smallest applicable test and retain the failure evidence.
3. Add only the minimum production code required by that test.
4. Re-run the focused test and affected suite.
5. Refactor only while all affected tests remain Green.

Examples:

```bash
# Focused unit Red/Green
forge test --root contracts \
  --match-path 'test/unit/Example.t.sol' \
  --match-test 'test_behavior' -vvv

# Affected suites
npm run contracts:unit
npm run contracts:integration
npm run contracts:fuzz
npm run contracts:invariant
```

Phase 0 documentation and Phase 1 tooling do not require a fabricated Red.
Starting with the first public contract behavior, Red and minimum Green must
remain in the same task and review unit.

## Test layout

```text
test/unit/          focused public-ABI behavior
test/unit/generated generated exhaustive ABI layout tests
test/generated/     generated SchemaFixtures consumed by Hash/integration tests
test/integration/   cross-contract and deployment behavior
test/fuzz/          bounded property exploration
test/invariant/     stateful invariants
test/fork/          optional fixed-block external integration
```

Absent directories are created when their first Red test is introduced. An
optional fork job may be skipped without RPC credentials; a skip is never
production verification evidence.

## Prohibited test patterns

- 禁止直接测试生产合约的 `private/internal` 函数；已批准的纯 library
  foundation 只能通过 test-only external harness 观察，生产合约不得为此增加
  debug/introspection getter。
- 禁止为测试向生产合约添加 debug/introspection getter。
- 禁止用同一算法重算 expected hash、TYPEHASH、selector、topic 或金额。
- Expected hashes and amounts must be independently generated or reviewed
  literals from versioned golden vectors.
- 禁止让 mock 替代最终生产 Registry、Adapter、Calculator 或 DvP 交付物。
- 禁止把 `preCheck`、缓存的 view 结果或 internal call count 当作结算授权。
- Revert paths must assert externally observable state and event absence, not
  implementation-private sequencing.

## Tooling gates

```bash
npm run toolchain:check
npm run typecheck
npm run contracts:fmt
npm run contracts:build
npm run contracts:size
npm run phase4:test
npm run calculator:bytecode
npm run adapter:bytecode
npm run phase17:test
npm run schema:check
npm run schema:python
npm run schema:secrets
npm run phase18:test
npm run reproducible:check
npm run reproducible:self-test
```

Phase 4 differential fuzz reads only the versioned Calculator bootstrap through
the narrow read-only `foundry.toml` permission. It does not enable FFI. The
bytecode gate rejects extra selectors, state access, external/delegate calls,
logs, contract creation and block-environment reads; Phase 7 Registry tests
will reuse it as an activation precondition.

Phase 17 enables the complete blocking Solidity/ABI/manifest/vector drift gate,
an independent Python JSON-only consumer, and a generated-artifact secret
scan. These gates prove consistency but do not by themselves freeze or approve
the candidate V1 artifacts; the cross-team sign-off remains a release boundary.

Phase 5 provider calls use fixed 32-byte output buffers, exact return-length
checks, and an explicit per-deployment Gas cap. The Adapter gate fixes exact
inputs, outputs, tuple components, mutability and the five-entry public ABI;
approved source SHA-256 values make every production Adapter/helper change an
explicit policy review. It rejects state writes, transfer/transferFrom,
delegatecall, mixed arbitrary static-call shapes, and fallback entry points
with malicious-fixture self-tests.

`RegistryTestBase` deploys the pinned OpenZeppelin ERC1967Proxy directly. Some
legacy unit fixtures use a TimelockController address as an ordinary role
holder to prove compatibility with an operator-selected external controller;
HTP does not inspect its ABI or delay. `MockDvP` exposes only the three
governance-view getters plus test-only state controls; it has no settle path and
must be replaced by the real DvP in integration tests.

## Fixture graphs

- `DvPTestBase` uses eight mock Registries. It is for constructor, authorization
  and signed-payload unit tests only. It is not production-isomorphic.
- Settlement and preCheck fixtures (`DvPPreCheckTestBase`, `DeployFixture`,
  USDY/cross-asset helpers) deploy through
  `script/CoreDeploymentTopology.sol`, the same CREATE sequence as `DeployHTP`.
  DvP and Registry roles come directly from `DeploymentRoles`. Addresses may
  overlap or all be identical; tests that need distinct holders configure them
  explicitly.
- `FeeRegistryTestBase` and single-Registry unit tests may use a focused
  subgraph. They inherit `script/RegistryDeploymentPrimitives.sol` (proxy +
  Adapter/Calculator/SettlementToken/AssetVersion/Fee) and must not claim
  production CREATE isomorphism. Eligibility, Participant, Factory and DvP
  CREATE stay on `CoreDeploymentTopology`. `DeploymentTopologyParity.t.sol`
  is the production-vs-topology check.
- `SettlementParamsValidationHarness` is the allowed pure-library seam for
  FirmQuote/TradeIntent/Snapshot coherence. Domain, Hash, signatures, time,
  nonce, Registry, Calculator, Eligibility and allowance stay on the Validators.
- Funds: `preCheck` keeps PASS/BLOCK/UNKNOWN; `settle` keeps structured revert.
  Permit field checks share one predicate; DvP `_readTokenWord` stays specialized.

Phase 6 adds the common Registry proxy/RBAC/default-admin seam, append-only
dependent DvP upgrade guard, and linear Config lifecycle. Linear registries
keep the latest registered chain head separate from the current active
selection; legacy proxies lazily backfill latest from the existing
subject/revision/replaces chain without scanning history. The storage gate
consumes clean compiler build-info with `storageLayout`, validates upgrade
safety through OpenZeppelin Upgrades Core, independently checks project
ERC-7201 namespaces/derived slots/no-`__gap`, compares every production
namespace—including nested struct shapes—to a reviewed append-only baseline,
and self-tests duplicate/unbaselined namespaces plus incompatible-layout
rejection.

Phase 7 adds the production `AdapterRegistry` and
`PrincipalCalculatorRegistry` proxy seams. Their tests cover reviewed
selectors, Config ID/Hash recomputation, capability/AssetClass linear
revisions, runtime code/interface/fixed-return validation, standard ERC-1967
and canonical EIP-1167 proxy rejection, lifecycle/current/history behavior,
literal event topics, and upgrade preservation. Arbitrary-bytecode semantic
restrictions remain enforced by approved codeHash plus the Calculator/Adapter
bytecode gates; Registry probes do not claim to prove the absence of custom
proxy or read-only external behavior.

Phase 8 adds strict canonical `decimals()` and Token deployment-baseline
validation plus the production `SettlementTokenRegistry` and
`AssetVersionRegistry` proxy seams. Tests cover exact 32-byte Token metadata,
DIRECT/ERC-1967 configuration matrices, linear Config history, permanent Asset
Token ownership, exact active Adapter/Calculator/Settlement Token references,
registered DvP deployment identity, implementation-change recovery denial,
literal event topics, and upgrade preservation. ERC-1967 implementation fields
remain monitored approval baselines; the on-chain checks do not claim to read
arbitrary proxy implementation slots.

Phase 9 adds the production `ParticipantRegistry` proxy seam. Tests cover
wallet-scoped first registration and optimistic versions, immutable participant
identity/type, finite validity, role-separated pause/recovery/revocation,
permanent revocation, same-entity distinct wallets, replayable non-PII events,
and UUPS preservation of records, roles, and dependent DvPs.

Phase 10 adds the production `EligibilityRegistry` proxy seam. Tests cover
Governance-owned SEND/RECEIVE Policy versions, Updater-owned wallet Records,
diagnostic-only `canConsume` error selectors, current-Policy fail-closed
behavior, role/binding/dependent-membership DvP authorization, atomic two-sided consumption,
replayable events, consumed monotonic fuzzing, stateful balance invariants, and
UUPS preservation. The unit fixture uses the real `AssetVersionRegistry` for
the authorization seam, and the fuzz/invariant suites reuse that production
Registry graph rather than replacing a Registry with a mock. DvP settlement
integration remains assigned to the later settlement phases.

Phase 11 adds the production `FeeRegistry` proxy seam. Tests cover monotonic
Fee Policy Epoch creation, immutable seal, single-ACTIVE/LEGACY_SERVING/CLOSED
transitions, scope-local linear Fee revisions, exact Settlement Token
references, fixed five-level resolution from the production Asset Version
facts, diagnostic-only executability, ACTIVE/PAUSED/DEPRECATED behavior,
full-precision capped Fee conservation, replayable events, cross-role denial,
sealed mapping invariants, and UUPS preservation. The Fee fixture deploys the
real Adapter, Calculator, Settlement Token, and Asset Version Registry graph;
the later DvP phases remain responsible for recomputing the selected Fee and
enforcing the off-chain pre-deprecation signature boundary during settlement.

Phase 12 adds the non-upgradeable `DvPSettlement` public seam for immutable
Registry/deployment identity, delayed-admin role topology, global pause/retire,
wallet and relayed Nonce cancellation, EOA/EIP-1271 signatures, complete Quote
and Snapshot Hash binding, repeated-field validation, and chain/contract replay
protection. At the Phase 12 checkpoint valid settlement inputs deliberately
stopped at the now-removed `SettlementPipelineIncomplete` development gate;
`preCheck` remained fail-closed until Phase 13. CANCELLED and USED Nonce terminal
behavior is now exercised only through public cancellation and successful
Phase 14 settlement, without private-storage seeding or debug setters.

`DvPTestBase` centralizes the code-bearing Registry dependencies and canonical
signed-input construction used across Phase 12 tests. Hash expectations remain
owned by the independently reviewed Phase 3 literal vectors; the base only
composes that already-tested module to reach the DvP public seam.

Phase 13 adds the public read-only `preCheck` decision seam. Tests use the real
eight-Registry graph, production Fund Calculator and Unrestricted Adapter for
the complete PASS path; mocks are limited to explicit Registry/EIP-1271/Token/
Adapter failure injection. `DvPPreCheckTestBase` constructs signed inputs from
the reviewed Phase 3 values and then binds them to the deployed historical
Config IDs and Hashes. BLOCK, UNKNOWN and PASS are observed only through
`IDvPSettlement.preCheck`; Nonce, Eligibility, allowance, balances, Permit call
count and logs prove that no stateful settlement action occurred.

The per-DvP current-state Validator is created through a non-upgradeable factory;
the DvP constructor separately creates its Phase 12 signature/original-image
Validator. DvP fixes both addresses and codeHashes and checks the reviewed
Factory runtime codeHash. Adapter checks remain direct DvP staticcalls because
the production Adapter caller binding is part of public behavior.

Phase 14 adds the complete atomic `settle` path: Executor/lifecycle/reentrancy
gates, replay and business-Nonce locks, one dual-sided Eligibility consumption,
fixed EIP-2612 attempts, strict allowance/balance snapshots, three direct
`transferFrom` legs, aggregate delta postconditions and success events. Tests
cover exact replay, cancellation, zero legs, no-return/false/malformed/fee-on-
transfer Tokens, Permit front-running/failure, callback reentrancy, failures at
each stage and full EVM rollback.

Phase 15 adds the real cross-module integration seam. `DeployFixture` extends
the Registry fixture, predicts and verifies the final DvP CREATE address so the
Eligibility proxy initializes directly with the real settlement consumer, and
registers that DvP with all eight append-only dependency sets. Integration tests
cover complete USDY BUY/SELL, three-list restrictions and provider drift,
ERC-1967 implementation-monitor boundaries, Stock/Bond/ERC-1404 settlement,
Maker-to-Maker and EIP-1271 wallets, all Fee resolver levels, current-versus-
historical Config behavior, current Participant/Eligibility revalidation,
eight-Registry upgrade/retirement gates, and Settlement Token incident recovery.
Mainnet fixed-block and approved-wallet evidence remains assigned to the fork
and release phases; offline fixtures are never production approval.

Phase 16 adds bounded fuzzing, stateful Registry/Fee/DvP handlers, balance and
replay invariants, and per-stage failure injection. DvP properties run through
the real eight-Registry graph; Registry/Fee lifecycle properties use their
production public ABIs. Handler-invalid transitions are caught explicitly so
`fail_on_revert=true` remains meaningful, while successful and failed
settlements are observed through balances, Hash locks, both Nonce types,
Eligibility records and terminal events.

Phase 17 generates the complete candidate machine surface from clean Solidity
build-info and production ABI artifacts. Formal vectors cover IDs, EIP-712,
Calculator, Config, Fee, Settlement, USDY candidate capabilities and the
documented off-chain boundaries. The pinned Python consumer independently
recomputes primitive EIP-712 encoding, RLP transaction preimages, selectors and
topics without reading Solidity source. Bootstrap vectors remain only as
compatibility inputs until all earlier consumers migrate.

Phase 18 adds the production deployment-script seam. Deployment directly grants
the configured ordinary AccessControl roles and contains no Timelock,
code/delay verification, pending handoff, or address-separation policy. An
operator-selected external multisig or Timelock is simply one possible role
holder. Tests invoke the public orchestrator, direct operation builders and
read-only verifiers; they observe only production public ABIs, standard
ERC-1967 slots and codeHash. CREATE nonce prediction is checked before
broadcast and after deployment. A unified JSON report records every
implementation/proxy, role, Config and readiness check while preventing
local/unapproved inputs from claiming production readiness. Upgrade and
migration tests keep DvPs paused until all checks pass; USDY fork remains an
explicit non-evidence skip until an approved block package and RPC exist.
