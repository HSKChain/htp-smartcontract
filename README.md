# HTP RFQ DvP smart contracts

HTP is a single-chain, non-custodial RFQ Delivery-versus-Payment protocol.
It includes:

- a non-upgradeable atomic settlement contract;
- eight governed UUPS registries;
- Stock, Fund, and Bond principal calculators;
- Unrestricted ERC-20, ERC-1404, USDY, and Ondo GM asset adapters;
- generated ABI, schema, hashes, and test vectors;
- resumable deployment, asset-listing, role-management, and verification tools.

## Requirements

Exact local toolchain versions are recorded in `contracts/toolchain.lock.json`:

- Foundry 1.5.1 (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`)
- solc `0.8.36+commit.8a079791`
- Node.js 22.23.4
- npm 11.11.0
- Slither 0.11.5
- EVM target `cancun`

OpenZeppelin Contracts and Contracts Upgradeable are pinned to 5.6.1.
forge-std is pinned to 1.16.2.

## Setup

```bash
git submodule sync --recursive
git submodule update --init --recursive
npm ci
npm run toolchain:check
```

No runtime command downloads dependencies. Dependency changes must update the
submodule commit, lock files, license inventory, and reproducibility evidence.

## Build and test

```bash
npm run contracts:fmt
npm run contracts:build
npm run contracts:test
npm run typecheck
npm run ops:test
npm run phase18:config
npm run calculator:bytecode
npm run adapter:bytecode
npm run security:slither
npm run security:repository-secrets
npm run schema:check
npm run reproducible:check
```

Run focused suites through the scripts in `package.json`.

## Deployment

Secrets belong only in ignored `tmp/.env`:

```bash
mkdir -p tmp/out
cp .env.example tmp/.env
chmod 600 tmp/.env
```

Copy and complete one platform profile:

```bash
# HSK: USDY only
cp deploy/ops-platform.example.json tmp/platform.hsk.json

# Ethereum: USDY and Ondo Stocks
cp deploy/ops-platform.ethereum.example.json tmp/platform.ethereum.json
```

Replace every placeholder, then deploy:

```bash
node scripts/ops/deploy-platform.mjs \
  --config tmp/platform.ethereum.json \
  --state tmp/out/ethereum/platform-state.json \
  --out tmp/out/ethereum/platform-deployment.json
```

The state file makes deployment resumable. Re-run the same command after a
failure. Verify a completed deployment with the same arguments plus `--verify`.

For USDY, the deployed DvP address must be added to the token allowlist before
settlement.

### Asset listing

```bash
# Ethereum
cp deploy/ops-asset.usdy.ethereum.example.json tmp/asset.usdy.ethereum.json
cp deploy/ops-asset.ondo-stock.ethereum.example.json tmp/asset.stock.ethereum.json
node scripts/ops/list-asset.mjs \
  --config tmp/asset.usdy.ethereum.json
node scripts/ops/list-asset.mjs \
  --config tmp/asset.stock.ethereum.json

# HSK
cp deploy/ops-asset.usdy.hsk.example.json tmp/asset.usdy.hsk.json
node scripts/ops/list-asset.mjs \
  --config tmp/asset.usdy.hsk.json
```

Replace every asset-profile placeholder before use.

One Ondo GM adapter serves every token with the same runtime code hash and
provider graph. Listing another token in that family creates only its
AssetVersion and MarketRule; it does not deploy or register another adapter.
A different runtime or provider graph requires another approved adapter.

Ethereum Ondo operations remain blocked until the tracked fixed-block evidence
is `PRODUCTION_APPROVED`. ERC-1967 token configurations are rejected when their
declared implementation does not match the standard implementation slot.

### Role handoff

```bash
node scripts/ops/grant-gov-cfg.mjs --account <GOVERNANCE_ADDRESS> --dry-run
node scripts/ops/grant-executor.mjs --account <EXECUTOR_ADDRESS> --dry-run
node scripts/ops/grant-admin.mjs --account <ADMIN_ADDRESS> --dry-run
```

Remove `--dry-run` only after reviewing every target. Use
`grant-admin.mjs --renounce-self` only for an intentional, verified admin
handoff.

## Directory map

```text
contracts/
  src/                  production contracts
  test/                 contract tests and fixtures
  script/               Foundry deployment scripts
deploy/                 deployment profiles and configuration schema
packages/               schema, identifier, and reference-calculation tools
schema/                  generated ABI, manifests, types, and vectors
scripts/                 validation, security, and deployment tooling
scripts/ops/             resumable operational workflows
security/                security baselines
```

## Security and scope boundaries

- `DvPSettlement` is non-upgradeable; the eight Registries use governed UUPS.
- Adapters and Principal Calculators are non-upgradeable and read-only.
- Private keys, KMS credentials, customer signatures, raw transactions, PII,
  production addresses, and `.env` files must never be committed.
- Quote, Inventory, KMS/Executor, Finality/Reconciliation, and Subgraph service
  implementations are outside this repository.
- Example values and locally passing checks are not production approval.
- Public-chain settlement exposes addresses, amounts, fees, and activity; the
  protocol does not claim transaction confidentiality.

## License

Project source is licensed under Apache License 2.0.
