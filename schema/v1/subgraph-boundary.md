# Subgraph replay boundary

Status: candidate. Production network names, chain IDs, contract addresses, and
start blocks remain unapproved release materials.

The event ABI/topic authority is `schema/v1/protocol/events.json`: 35 HTP typed
events and 9 inherited OpenZeppelin events.

## Network context

Every raw log entity stores:

```text
chainId
blockNumber
blockHash
timestamp
txHash
logIndex
contractAddress
decoded event fields
```

- HTP events carry `chainId` as their first field. It must equal the deployment
  manifest network chain ID.
- OpenZeppelin standard events are not wrapped or modified. Their chain ID is
  supplied by the configured network context.
- Missing or mismatched chain context rejects indexing.
- Entity namespaces never merge across chains.

Current release state:

- LOCAL: chainId 31337, local deployment block only.
- Ethereum/BSC/HSK: chainId, addresses, and startBlock are unapproved/null.
- HSK graph-node/Cancun compatibility remains an external blocker.

## Indexed data sources

Index the immutable `DvPSettlement` and the proxy address of each Registry:

- AdapterRegistry
- AssetVersionRegistry
- EligibilityRegistry
- FeeRegistry
- MarketRuleRegistry
- ParticipantRegistry
- PrincipalCalculatorRegistry
- SettlementTokenRegistry

Do not index deployment scripts, Validator/Factory, Adapter implementations, or
Calculator implementations as protocol state sources.

## Raw and domain entity keys

Raw event id:

```text
keccak256(abi.encode(chainId, txHash, logIndex))
```

Recommended domain keys:

- Adapter Config: `{chainId}-{adapterConfigId}`
- Current Adapter: `{chainId}-{capabilityHash}`
- Calculator Config: `{chainId}-{calculatorConfigId}`
- Current Calculator: `{chainId}-{assetClass}`
- Settlement Token Config: `{chainId}-{configId}`
- Current Settlement Token: `{chainId}-{settlementToken}`
- Asset Version: `{chainId}-{assetVersionId}`
- Current Asset Version: `{chainId}-{assetToken}`
- Fee Epoch: `{chainId}-{feePolicyEpoch}`
- Fee Version: `{chainId}-{feeVersionId}`
- Market Rule: `{chainId}-{marketRuleConfigId}`
- Current Market Rule: `{chainId}-{assetVersionId}`
- Participant: `{chainId}-{wallet}`
- Eligibility Record: `{chainId}-{eligibilityKey}`
- Settlement/Fee Collection: `{chainId}-{tradeIdHash}`
- Nonce: `{chainId}-{signer}-{nonceType}-{nonce}`
- DvP lifecycle: `{chainId}-{dvpAddress}`
- Dependent DvP: `{chainId}-{registryProxy}-{dvp}`
- Upgrade/role audit: `{chainId}-{contractAddress}-{txHash}-{logIndex}`

## Config replay

Registered events provide immutable Config fields where present, plus Config
IDs and hashes. Status events apply state transitions. Current-changed events
maintain subject pointers.

- Adapter, Calculator, Settlement Token, and Asset Version use their
  `Registered`, `StatusChanged`, and `CurrentChanged` event families.
- Fee Epoch uses `Created`, `Sealed`, and `StatusChanged`.
- Fee Version uses `Registered` and `StatusChanged`.
- Market Rule uses `Registered`, `Sealed`, `StatusChanged`,
  `PauseChanged`, and `CurrentChanged`.
- Participant uses `ParticipantUpdated` and `ParticipantRevoked`.
- Every Registry uses `DependentDvpRegistered` and
  `DependentDvpRetiredExempted`.

`currentActiveEpoch` is derived from ACTIVE status transitions. Scope
latest-registered mapping is derived from Fee registration order; the serving
mapping advances only on a Fee Version `REGISTERED` to `ACTIVE` transition.
PAUSED and DEPRECATED transitions retain that serving pointer so execution can
fail closed or honor already-bound settlements. Historical Settlement Config
IDs/hashes come from `SettlementExecuted` and are not rewritten when a current
pointer changes.

`MarketRuleRegistered` carries identity, revision, replacement, and Config
hash, but not the full minimum/step/tick fields. A projection that needs those
fields must call `getMarketRule(configId)` at the event block and verify the
returned `configHash`; an events-only projection stores lifecycle metadata
only.

## Eligibility replay

Eligibility is a wallet plus exact Asset Version `CAN_TRADE` authorization. It
has no action dimension, quota, remaining amount, or settlement consumption.

- `EligibilityUpdated` supplies the full current record after set, pause,
  unpause, or revoke.
- `EligibilityRevoked` is the typed revoke audit event. A revoke transaction
  emits both `EligibilityUpdated` and `EligibilityRevoked`.

Select the highest record version. Settlement does not modify Eligibility and
does not emit `EligibilityConsumed`.

Keys:

```text
eligibilityKey = keccak256(abi.encode(chainId, wallet, assetVersionId))
```

## Settlement replay

A successful settlement transaction emits, in order:

1. `NonceConsumed` for Maker;
2. `NonceConsumed` for requester;
3. `SettlementExecuted`;
4. `FeeCollected`, including zero-fee settlements.

`FeeCollected` supplies the Collector associated with the Settlement. A
reverted settlement has no durable business events; attempted/reverted
transactions are obtained from RPC receipts, not inferred from missing logs.

## OpenZeppelin event exceptions

Attach network context chain ID to these unchanged standard events:

- `Upgraded`
- `RoleGranted`
- `RoleRevoked`
- `RoleAdminChanged`
- `Initialized`

The immutable DvP never emits `Upgraded`.

## Finality and reconciliation boundary

The Subgraph must not decide:

- pending, dropped, replacement, or cancellation transaction status;
- canonical receipt status or confirmation count;
- chain finality;
- shallow/deep reorg policy;
- financial reconciliation;
- Inventory, Quote, KMS, or exact signed raw state.

RPC canonical receipt/blockHash plus the approved per-chain threshold decides
FINAL. Snapshot, balance deltas, Position, Fee Ledger, and internal records
decide RECONCILED. Subgraph synchronization alone decides neither.

On a shallow reorg, orphaned entities are rolled back and confirmations restart.
After a reconciled deep reorg, original Settlement history is never deleted or
rewritten; external systems pause the Asset Version and add an append-only
correction/exception record. There is no Eligibility consumption history to
decrement.

Subgraph outage may block indexed queries and reconciliation, but cannot block
on-chain settlement or RPC-based finality.

## Known event limitations

- Fee Epoch sealed state is replayed from `FeePolicyEpochSealed`.
- Market Rule sealed state is replayed from `MarketRuleSealed`; its paused flag
  is replayed independently from lifecycle status.
- Settlement Collector is joined from same-transaction `FeeCollected`.
- Failed settlement attempts, `preCheck`, token implementation drift, and
  off-chain workflow states intentionally have no HTP success event.
- Production startBlock/address manifests and target-chain replay evidence
  remain external release blockers.

