# LayerZero bridge implementation

This implementation is deployed on Robinhood and Arc for twelve stocks; the independent audit is
in progress. See [the public deployment registry](../config/layerzero.mainnet.json) for verified identities
and initial metadata transactions.

## Contracts and accounting

The new implementation is under `src/layerzero/`:

- `LayerZeroSourceVault`: one original, 18-decimal stock token per vault; exact transfer checks;
  immediate 50-bps entry fee rounded down; net raw-unit reserves; authenticated redemption.
- `LayerZeroDestinationBridge`: mint net deposits, burn the caller's wrapped balance for redemption,
  and receive source-token metadata snapshots.
- `LayerZeroWrappedAsset`: permissionless ERC-20 with `originEid` as a uint32 LayerZero endpoint ID.
  Multiplier snapshots affect display conversions only; raw ERC-20 balances do not rebase.
- `LayerZeroEndpoint`: authentication, one-time peer binding, lanes, limits, bootstrap, ownership,
  explicit messaging security, native fee payment, and permissionless manual completion.
- `LayerZeroMessage`: separate `synthra.rwa.bridge.layerzero.v1` domain. Transfer and metadata payloads
  are respectively 320 and 384 bytes. The header binds the action, both EVM chain IDs, receiving EID,
  receiving bridge and original token. EIDs are uint32 LayerZero endpoint identifiers.
- `ILayerZero.sol`: local ABI subset, checked against LayerZero-v2 commit
  `9c741e7f9790639537b1710a203bcdfd73b0b9ac`. See the upstream
  [Endpoint interface](https://github.com/LayerZero-Labs/LayerZero-v2/blob/9c741e7f9790639537b1710a203bcdfd73b0b9ac/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol)
  and [ULN configuration](https://github.com/LayerZero-Labs/LayerZero-v2/blob/9c741e7f9790639537b1710a203bcdfd73b0b9ac/packages/layerzero-v2/evm/messagelib/contracts/uln/UlnBase.sol).

There is no aggregate cap or shared throughput bucket. `maxTransfer` limits new outgoing requests;
`inboundMaxTransfer` can only increase, so a reduced outgoing limit cannot invalidate an earlier
claim. Before increasing outgoing limits, governance must prepare and verify the receive ceilings
on both chains. Under authentic peer messages, the accounting invariant is:

`locked = wrapped supply + pending net deposits + pending redemptions`.

A failed publication rolls back the token transfer, fee payment or burn. A failed completion rolls
back message consumption and all asset effects. There is no claim expiry, admin reserve withdrawal,
arbitrary mint, recipient override, or unsigned cancellation/refund. Issuer freezing, taxation or
seizure can prevent redemption; LayerZero does not remove these original-token risks.

## Security configuration

Each app explicitly selects its send and receive libraries, two distinct required DVNs, and separate
send/receive confirmation counts. Optional DVNs are explicitly disabled with ULN's `255` sentinel,
not inherited. Both selected DVNs must attest. Zero confirmations and `uint64.max` are rejected:
the former inherits defaults and the latter disables the confirmation requirement in ULN.

### Selected LayerZero verification policy — 2026-09-25

Use LayerZero Labs and Nethermind as two required DVNs, no optional DVNs, and **15 source-chain
confirmations in both directions**, pinned explicitly on send and receive. The side-specific templates
are `config/layerzero.robinhood.example.json` and `config/layerzero.arc.example.json`.

The owner selected the standard LayerZero ULN verification model. The earlier five-minute wait and
additional Ethereum-finality requirement are superseded. Complete as soon as the packet satisfies
both required DVN attestations, ULN verification and the bridge's normal application checks. There
is no additional timer or source `finalized` RPC gate imposed by this application. Prerequisite nonce
commitments may still need batch/checkpoint recovery as documented below; paused or failed claims
remain pending.

The published libraries currently expose five-confirmation defaults for these routes. We pin 15:
this is within LayerZero's documented 15–30 optimistic-L2 guidance, above both observed defaults,
and the value used in the successful two-DVN message pilot and real-contract fork fixture. This
is an explicit application choice, not a route-specific certification by LayerZero. The default
DVN set is not inherited; both reviewed operators are selected explicitly. See
[LAYERZERO_FINALITY.md](LAYERZERO_FINALITY.md) for evidence and the selected trust model.

`config/layerzero.finality-policy.example.json` records the policy; the actual deployed values come
from the side-specific deployment files. This choice does not prove Ethereum data finality, eliminate
source-chain/DVN risks, or guarantee end-to-end latency. The previously required custom finality
confirmation from operators is no longer a release prerequisite. The deployed pairs use this selected
policy. Independent audit and release evidence review remain required.

Endpoint, libraries, DVNs and confirmation counts are immutable in this version. There is no external
Endpoint delegate, library upgrade, verification downgrade, message skip/nilify/burn, or arbitrary
Endpoint-call administration. This also means governance cannot replace an unavailable DVN in the
existing pair: both workers must recover for its pending claims to complete. A different security
stack requires a separately reviewed deployment and migration plan. This is an explicit liveness
tradeoff, not guaranteed recovery from permanent verifier failure. Peer and asset are also immutable
once configured. External LayerZero/worker contracts retain their own governance and availability risks.

## User flow and fees

1. On Robinhood, approve the original token if needed, quote `quoteDepositFee(gross, recipient)`,
   then call payable `deposit(gross, recipient)`. The 0.5% asset fee is separate from the native
   LayerZero fee. `quoteDeposit` returns net and asset-fee amounts.
2. Preserve the source transaction receipt. `MessageSent(guid, nonce, message)` contains the exact
   application payload; the source EID and sender address complete `Origin`. LayerZero also emits
   its protocol packet. Retrieve this event after closing/reopening a client; do not republish a
   successful source transaction just because delivery has not finished.
3. After both DVNs attest on Arc, anyone calls `complete(origin, guid, message)` there. The wrapper
   commits ULN verification if needed and calls Endpoint delivery in the same transaction. A packet
   already committed by someone else is also supported. This is the user's second bridge transaction.
4. To return, quote `quoteRedeemFee(amount, recipient)` on Arc and call `redeem`. No ERC-20 approval
   is needed for burning the caller's wrapped balance. Complete the packet on Robinhood as above.

Application execution is unordered, but Endpoint requires all earlier nonce hashes to be committed.
When earlier verified packets have not been committed, `completeWithVerifications` can register their
`Verification(nonce, payloadHash)` prerequisites before executing the selected packet. Anyone may
also call `commitVerifications` separately. Every hash is still authenticated by the required DVNs.
A never-attested predecessor cannot be skipped.

For a long backlog, `checkpoint(origin, guid, message)` moves an authenticated packet out of the
protocol queue while preserving its claim hash in `checkpointedPayloads`. It executes no asset or
metadata effects and is allowed while paused. This permits bounded progress even if an earlier
recipient is blocked or a snapshot is expired. `complete` detects a checkpointed packet and routes
it to `executeCheckpointed`, which enforces all normal execution checks and deletes the stored claim
only on success. A failed claim remains retryable. `MessageCheckpointed` provides recovery data;
clients must not interpret protocol clearing as asset delivery. Use application consumption and
mint/release events. Very large backlogs can require additional checkpoint/batch transactions;
two user bridge transactions describe the normal path, not an unconditional upper bound. The Endpoint and app both enforce authentication/replay
protection. The app also checks the canonical GUID for the bound path and nonce. It accepts callbacks
only from its configured Endpoint, with zero native value, and guards all mint/burn/reserve effects
against reentrancy. `complete` itself is intentionally unguarded because it synchronously invokes
that guarded callback; the wrapper performs no asset accounting.

There is no paid automatic executor. The app supplies the zero-fee executor ABI and uses empty type-3
options. DVNs are still paid normally. The user needs gas on both chains. Endpoint charges the current
native fee and refunds excess directly to the initiating caller; a contract caller must accept that
refund or provide the exact fee. Quotes are not reserved prices; an insufficient payment reverts
atomically. There is no delivery-time guarantee in these contracts.

## Metadata

Anyone may quote `quoteMetadataFee` and call `publishMetadata`. The source vault reads the issuer's
current and scheduled multipliers itself; callers cannot choose them. Deliver with the same
`complete` function on Arc. Snapshots use the source path nonce for ordering. `MetadataReceived`
records whether a snapshot was applied or ignored as older, and the token emits detailed snapshot
events. Source timestamps are checked with a five-minute clock-skew allowance and a maximum
30-day lifetime. The deployment may select a shorter lifetime. Refresh early after a split or
schedule change. Stale snapshots do not block raw transfers, deposits or redemptions. A stale,
undelivered snapshot may be superseded by a fresh later snapshot without blocking other claims.

## Governance and deployment

`script/DeployLayerZero.s.sol` deploys one side with a fresh OpenZeppelin TimelockController and
paused endpoint. The designated hardware wallet is bootstrapper and timelock proposer/executor/
canceller; it may also be guardian. The deploying hot wallet gets no bridge administrative role.
Initial peer binding and activation use `bootstrapSetPeer` and `activate` without waiting.
Any activation, partial unpause or ownership nomination permanently closes bootstrap authority.
Guardian pause is immediate; subsequent resume, transfer-limit changes, fee-recipient rotation,
and guardian/ownership changes require timelock ownership. The script enforces an initial delay
of at least two days. As in the previous design, governance can later schedule changes to the delay
or ownership itself; this is a trust assumption, not an immutable minimum delay.

Use the **new** `config/layerzero.deployment.example.json` schema, starting from the side-specific
Robinhood/Arc files above, which pin the selected 15/15 confirmations. Fill remaining asset and
authority placeholders before simulation; the generic template remains intentionally unconfigured.
The sample amounts/addresses
are not a production bundle. `DEPLOY_CONFIG` selects the file; Foundry supplies signing separately.
A local simulation command, after preparing a valid configuration, is:

```sh
FOUNDRY_PROFILE=deployment forge script script/DeployLayerZero.s.sol:DeployLayerZero \
  --rpc-url "$RPC_URL" --use .tools/solc-0.8.28 --offline
```

This command does not broadcast. Use `tools/layerzero_deploy.py` and
`tools/layerzero_operate.py` for per-stock configuration, receipt reconciliation, runtime/ownership,
peer, DVN/library, confirmation and limit checks. `tools/layerzero_batch.py` processes the remaining
stocks sequentially. LayerZero packet recovery and manual completion authenticate source receipts
and destination protocol state.
See [the deployment runbook](LAYERZERO_PILOT.md) and [multi-stock rollout](LAYERZERO_STOCK_ROLLOUT.md).

## Validation and remaining release work

The local unit/fuzz suite covers both directions, payload/domain/peer/GUID tampering, replay,
unauthorized callbacks, missing attestations, paused/precommitted claims, underpayment, refunds,
refund/token reentrancy, taxed/frozen/seized assets, treasury rotation, metadata ordering/expiry,
bootstrap closure and actual timelock enforcement. Stateful fuzzing interleaves pending claims,
wrapped transfers, time, pauses and limit changes and checks reserve conservation after every action.

`integration/LayerZeroLive.t.sol` exercises the twelve selected original stock contracts against
real Endpoint/ULN bytecode on local Robinhood and Arc forks: deposit, metadata, redemption, zero/one
DVN rejection, insufficient confirmations, modified payload and replay rejection. Balances and
DVN attestations are injected **only in local fork state**. These tests do not prove off-chain
worker liveness, real share ownership, RPC reliability or adequate production finality. The earlier
message-only mainnet pilot demonstrated actual delivery in both directions but did not bridge assets.

Reproduction:

```sh
forge test --use .tools/solc-0.8.28 --offline
FOUNDRY_PROFILE=audit forge test --use .tools/solc-0.8.28 --offline
FOUNDRY_PROFILE=deployment FOUNDRY_TEST=integration forge test \
  --match-path integration/LayerZeroLive.t.sol --use .tools/solc-0.8.28 --offline -vv
```

The fork test uses public RPCs by default; override with `LZ_ROBINHOOD_RPC` and `LZ_ARC_RPC`.
Tests log their actual block heights. Run `bash tools/check.sh` for the local pipeline and
`python3 tools/layerzero_mutation_check.py` for the finite mutation campaign. The CI workflow runs
both. `tools/check_layerzero_config.py` validates a proposed pair offline without granting production
approval. See [the internal review](LAYERZERO_INTERNAL_REVIEW.md) for findings and their disposition.
Review current evidence in `audit/layerzero/` and reproduce it against the reviewed revision.
Earlier implementation and recovery materials are available through [the archive](ARCHIVE_HISTORY.md).
The external audit is in progress; successful tests and source verification do not establish audit approval.
