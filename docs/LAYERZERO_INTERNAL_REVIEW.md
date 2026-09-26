# LayerZero internal review — 2026-09-25

Scope: all `src/layerzero/`, `script/DeployLayerZero.s.sol`, the local ABI, proposed pair-configuration
validation, and integration with the real Endpoint/ULN implementations. This is an internal review,
not a third-party audit. No transaction was broadcast and no deployed state was changed.
See [validation](LAYERZERO_VALIDATION.md) for exact evidence and source hashes.

## Findings and disposition

### LZ-01 — Uncommitted predecessor can block a later manual completion — fixed

The first implementation assumed an unordered OApp could execute any verified nonce independently.
LayerZero's Endpoint requires all earlier nonces up to the execution checkpoint to have payload
hashes committed. With no automatic executor, both DVNs can have attested an earlier packet without
anyone calling `commitVerification` for it. A later user's `complete` then reverts with
`LZ_InvalidNonce(earlierNonce)`. The first local mock did not model this restriction.

The failure was reproduced on real Endpoint/ULN forks before fixing it. The new
`commitVerifications` and `completeWithVerifications` accept exact payload-hash commitments checked
by the same required DVNs. The latter registers prerequisites and executes only the selected packet
in one destination transaction. No attestation is skipped and no other recipient's assets are moved.
Already committed, checkpointed or consumed prerequisites are safe to include after a race with
another caller. The mock now models the Endpoint's gap checks; regression tests use both the mock
and the real deployed contracts.

### LZ-02 — Large backlogs need progress independent of asset execution — fixed

The Endpoint scans the interval from its lazy inbound nonce to the requested nonce. A sufficiently
large gap can exceed transaction gas limits. A permanently blocked recipient, an issuer freeze or
an expired metadata snapshot can also make an intermediate application execution fail. Simply
committing every hash does not advance the Endpoint's execution checkpoint.

`checkpoint` verifies the original packet through ULN, records its exact payload hash in
`checkpointedPayloads`, and calls the Endpoint's authenticated `clear` operation. The packet's
application claim is retained: it is not marked consumed and no mint, burn or unlock occurs.
`complete` routes saved claims to `executeCheckpointed`; that function rechecks chain, peer, GUID,
message hash, pause, amount, header and backing before executing. Consumption and deletion of the
saved hash roll back on failure. Anyone can checkpoint intermediate nonces in bounded steps, even
while asset lanes are paused. No skip/nilify/burn administration was added.

This is an application inbox, not a cancellation. `MessageCheckpointed` records the payload for
recovery. Completion is established using `consumedMessages` and the mint/release events as completion evidence;
protocol-level clearing alone does not mean that assets were delivered. Authentication remains
mandatory for every earlier nonce. If a required DVN never attests a predecessor, neither the batch
nor checkpoint can bypass it; verifier availability remains a protocol trust/liveness assumption.

Tests cover blocked-recipient recovery, preservation after a failed execution, tampering, missing
attestations, pause/resume, replay, concurrent completion, token callbacks, and real Endpoint
clearing. Stateful solvency tests now interleave checkpointing with ordinary delivery and governance.

### LZ-03 — Three mutation survivors exposed insufficiently isolated tests — fixed

The finite campaigns found three protections whose removal was not detected:

- Removing the exact gross-receipt check was hidden by a later fee-transfer failure for taxed tokens.
  A new sub-fee deposit test uses 199 raw units, whose entry fee rounds to zero, and proves that a
  short receipt alone cannot create backing liabilities. Another test isolates excess sender debit.
- Removing the zero-multiplier check was hidden by snapshot schedule-consistency checks. New cases
  test zero current/next together and zero pending with a future activation, independently of those
  other checks.
- Removing the deployment script's bootstrap assignment was hidden by tests that activated through
  the ordinary timelock. A new test deploys both sides through the actual script, activates immediately
  using the hardware wallet, and proves that this authority cannot resume transfers after a pause.

The final campaign reruns all targeted mutants against the corrected suite. It uses a temporary
copy; compilation errors and stale input hashes are failures, never successful detection. This is
finite test-sensitivity evidence, not proof that every possible bug is detectable.

### LZ-04 — Finality requirements resolved by explicit LayerZero trust-model selection

The owner selected the standard LayerZero ULN confirmation/DVN model, superseding the provisional
five-minute wait and subsequent additional Ethereum-finality requirement. Both routes explicitly use
15 source-chain confirmations and require LayerZero Labs plus Nethermind. Both send/receive values
match. The currently published library defaults are five confirmations; the selected 15 follows the
optimistic-L2 guidance and matches the already tested pilot/fork setting. See LAYERZERO_FINALITY.md.

This resolves the open policy choice; bespoke operator confirmation of Ethereum-finalized behavior
is no longer required. It does not prove Ethereum data finality or eliminate source-reorganization,
DVN compromise or availability risk. In particular, both DVNs can honestly attest an event that a
later source reorganization removes. These are accepted protocol trust assumptions, not defects
shown to be impossible by unit tests. No independent verification of parent-chain consensus has
been added. The pair checker still returns `productionApproved: false`; ordinary audit, deployment
preflight and live asset/product validation remain separate release requirements.

The recorded latest/finalized observations remain useful historical context, not production timers:
network-review.json sampled a 906-second Robinhood gap; the later five-minute observation window
saw larger gaps without finalized-head advancement. No fixed count is described as an Ethereum
finality guarantee. No source or destination transaction was broadcast during this configuration work.

## Other reviewed boundaries

- Exact gross debit/credit and fee payout; no treasury access to reserves; failed source publication
  rolls back custody, fee or burn. Surplus donations do not mint or authorize excess redemption.
- The two required DVNs, libraries, peers and asset remain immutable after setup. No inherited
  optional-DVN default or external Endpoint delegate exists. Permanent verifier failure can halt
  the path; no administrator can forge a substitute proof.
- Bootstrap binding/activation is single-use; ordinary partial unpause or ownership nomination
  closes it. Guardian can pause immediately. Hardware-wallet governance controls the timelock,
  including future scheduled delay/ownership changes; this remains a single-key trust assumption.
- Incoming ceilings never decrease. Config validation rejects an outgoing limit larger than the
  other chain's incoming ceiling and mismatched cross-direction confirmation requirements.
- Metadata is independent of raw balances and cannot be caller-selected on the source. Stale UI
  conversions fail closed. Raw ERC-20 transfers and correctly authenticated redemption do not
  require fresh metadata. Invalid snapshot execution cannot erase a checkpointed claim.
- The contracts have no upgrade, arbitrary call, owner mint, principal sweep or unsigned refund path.
  Underlying issuer freeze/seizure/upgrade authority remains outside bridge control.
- Native fee refunds go to the initiating caller. Accounted asset effects are guarded against
  reentrancy; checkpoint effects follow checks/effects/interactions and use the same guard.
- Batch loops iterate caller-supplied work and call pinned protocol contracts. Callers can split
  batches; oversized inputs fail only their transaction. Checkpoints permit bounded progress through
  long verified backlogs without executing blocked recipients' claims.

## Reproduction and release boundaries

```sh
bash tools/check.sh
python3 tools/layerzero_mutation_check.py
bash tools/check_live.sh
python3 tools/verify_layerzero_abi.py
python3 tools/layerzero_network_review.py
python3 tools/check_layerzero_config.py --source SOURCE.json --destination DESTINATION.json
```

The ABI and network checks are read-only; the ABI check compiles downloaded pinned definitions
for ABI comparison, not execution. `check_live.sh` uses local forks. No command above broadcasts.
Foundry must be on PATH; the ABI tool uses `.tools/solc-0.8.28`. The pair checker is offline and needs
actual proposed configuration files; placeholder files are expected to fail.

Current deployed-bytecode hashes are observations, not proof of byte-for-byte equality with the
pinned upstream source revision. Forks test the observed live implementations; ABI comparison tests
the pinned interface encoding. Both sources of evidence are retained separately.

This review predates the operational rollout. The twelve pairs and initial metadata
have since been verified; see the public registry and LAYERZERO_VALIDATION.md. Independent
audit, release evidence review and reconciliation of the real asset round trip remain separate steps.
Historical recovery information is preserved in ARCHIVE_HISTORY.md.

## Primary references

- [LayerZero MessagingChannel, pinned revision](https://github.com/LayerZero-Labs/LayerZero-v2/blob/9c741e7f9790639537b1710a203bcdfd73b0b9ac/packages/layerzero-v2/evm/protocol/contracts/MessagingChannel.sol)
- [LayerZero EndpointV2, pinned revision](https://github.com/LayerZero-Labs/LayerZero-v2/blob/9c741e7f9790639537b1710a203bcdfd73b0b9ac/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol)
- [LayerZero configuration and confirmation mismatch](https://docs.layerzero.network/v2/developers/evm/configuration/dvn-executor-config)
- [Robinhood Chain architecture](https://docs.robinhood.com/chain/)
- [Arbitrum Nitro whitepaper](https://docs.arbitrum.io/nitro-whitepaper.pdf)
