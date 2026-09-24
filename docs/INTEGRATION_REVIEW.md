# Real-network integration review — 23 September 2026

Historical evidence: these live-fork results predate the treasury-rotation change of 24 September.
The expanded rerun on the current revision is documented in `TWELVE_ASSET_VALIDATION.md`: all
twelve selected stocks passed on 24 September. The remainder of this report records the earlier run.

Status: local suite and ten live-fork tests pass. **Not production approval.** All network interaction
was read-only; no deployment, signature, transaction, auditor contact or payment was made. Mutations
of fork state never reached a public chain. Production `src/` was not changed.

The operational RPC client now sends an explicit User-Agent, which resolved the observed public
provider HTTP 403 response in our collection client, and checks JSON-RPC response identity. Four
transport regressions supplement nine collector tests; the full Python suite has 47 passing tests.
This does not resolve missing historical state or certify production pair preflight.

## What changed in the evidence

| Check | Result | Limit |
| --- | --- | --- |
| Core identity, runtime and proxy implementation | Robinhood EVM 4663 / Wormhole 72; Arc EVM 5042 / Wormhole 71; both Guardian set 7 | One public RPC per network; external governance not audited |
| Finalized state reads | Arc passed | Robinhood returned `historical state ... is not available`; no silent fallback to latest |
| Robinhood recent pinned state | Required reads passed for AAPL, NVDA, TSLA, SPY; block hash rechecked | Explicit `latest` diagnostic; not proof of finalized state availability |
| Real token compatibility | All four support 18 decimals, current/pending multiplier, effective timestamp and expected registry UID | Research sample, not launch asset selection or issuer approval |
| Local fork deposit | All four: 100 raw tokens → 99.5 escrow + immediate 0.5 treasury; real Core publication and metadata call succeed | `deal` injects test balances; arbitrary test treasury/recipient addresses |
| Local fork return | All four return exactly 99.5 original tokens, with no additional protocol fee | Mock attestations; not a live cross-chain round trip |
| Issuer interference | Blocked treasury rolls back deposit; blocked recipient and paused token preserve retry; reserve burn blocks release/new deposits | Issuer role/block responses mocked locally; actual role holders not audited |
| Real signed VAA | Existing Robinhood publication matched to receipt, body and timestamp; valid on both live Core implementations in forks | Third-party emitter, consistency **202**, not Synthra's intended **0** |
| Authentication boundary | Foreign signed VAA rejected by Synthra; changed payload invalidates real signatures; truncated VAA cannot mint | Finite positive/negative cases |
| Arc-origin message | No Core logs in queried 10,000 finalized blocks; Wormholescan chain-71 list empty | Does not establish absence of historical messages or lack of support; reverse-route liveness remains unproven |
| Stateful model | Distinct EVM domains 111/222 now exercised throughout randomized actions | Same local EVM storage with chain-ID switching, mock attestations |

The historical log is preserved in `audit/baseline-pre-treasury-20260923.tar.gz`;
`audit/live-fork-tests.log` now contains the expanded 24 September run. The ten-test run used Robinhood block
**70,805,974**, Arc block **22,405,344**, and Arc block **22,405,357** for the signed-VAA test.
The separate RPC observation snapshots are pinned in their JSON reports, with raw requests/responses.
Historical fork replay requires an archive-capable provider; public pruning can prevent later replay.

## Verified issuer powers: a material launch dependency

The four observed token proxies use beacon `0xe10b6f6b275de231345c20d14ab812db62151b00`, resolving to
implementation `0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2`.
Observed implementation runtime Keccak-256:
`0xdc07e86ee482f99641bdafb9a0d772846b167401e094d90a666b94dbdcd1eec7`.

[Sourcify's verified implementation record](https://sourcify.dev/server/v2/contract/4663/0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2?fields=all)
reports an exact runtime/creation match. Its reported onchain bytecode hash matches the independently
queried RPC runtime. The downloaded record, its SHA-256 and comparison are packaged under
`audit/network/`. This is source-registry attestation plus bytecode comparison, not our own compiler
reproduction or a full audit of the token and registry.

The implementation's `Stock.sol`, `AccessControlled.sol` and role definitions establish:

- Transfers/approvals check blocked accounts and a token/global pause. For `transferFrom`, the
  owner, recipient and caller are checked. Blocking the vault or treasury can therefore stop deposits;
  blocking the vault or recipient can stop releases.
- Authorized callers can execute `adminBurn(from, amount)` against a balance, without the ordinary
  pause/block checks. This includes escrow balances; lack of a Synthra administrator withdrawal
  function does not prevent issuer-induced loss of backing.
- The external registry assigns issuer powers; the beacon introduces an upgrade dependency.
  Current role membership, thresholds, controller code and upgrade process remain unreviewed.
- UI multipliers do not rebase raw ERC20 balances; raw-unit escrow accounting is compatible with
  the reviewed implementation. Cash entitlements and other offchain corporate actions are not bridged.

In the fork intervention tests, only the registry responses granting the test caller a role or
marking a test account blocked were overridden. Token implementation code stayed real. A simulated
one-token administrative burn left 98.5 tokens against 99.5 liabilities: both deposit and release
reverted with `InsufficientBacking`. The same claim succeeded after a **test-funded voluntary
donation** restored reserves. There is no automatic recapitalization, insurance or recovery guarantee.
A block/pause-induced failure preserves the claim but cannot guarantee eventual issuer unblocking.

Synthra has no user allowlist, and anyone can submit valid messages. That permissionless access
remains conditional on issuer-controlled original tokens and Wormhole attestations. An additional
Synthra whitelist would not remove these external powers. No whitelist was added in this review.

## Actual Guardian evidence and its boundary

Verified VAA:
`72/00000000000000000000000031ad87c6815a18a43eb42cd3172121d1f5d9e584/246`.
Source transaction:
`0x61a7ffbee458dadd35e6123061dcf27a8d66fbd072c54d233cd4d62ed591c582`.
Guardian set 7; consistency 202. Evidence includes the original receipt, signed bytes, exact nonce,
payload, emitter, sequence and source timestamp comparison, and the opposite Core's verification.
`config/research-vaa.example.json` is a historical test fixture, not a deployment configuration.

This shows real signature/ABI interoperability and an observed Robinhood-origin message. It does
not show a Guardian quorum signing our endpoint's level-0 messages, prove Arc-origin observation,
measure Synthra's completion time, or demonstrate recovery after Guardian rotation. Signatures may
expire after future Guardian changes; pin the historical fork or obtain a newly corroborated fixture.
The [Wormhole finality table](https://wormhole.com/docs/reference/consistency-levels/) documents level
0 for these chains. The observed level-202 message does not establish that policy in practice.

## Remaining gates before launch and final audit freeze

1. Choose the actual initial asset and accept/document issuer block, burn, pause and upgrade risk;
   inspect live registry/beacon control, and obtain the required issuer/distribution assessment.
2. Obtain reliable finalized/archive reads on Robinhood. Independently confirm Core deployments,
   implementations and finality policy. A public endpoint returning headers without historical state
   is insufficient for the production preflight.
3. Select actual multisig/guardian/treasury addresses, signer thresholds/modules, timelock policy and
   paired immutable caps/rate limits. Research addresses do not fill `deployment.example.json`.
4. Deploy a rehearsal pair when separately authorized, then exercise deposit, mint, burn and release
   with real Guardian attestations in both directions at the selected consistency level. Include
   pauses, failed relays, delayed delivery, exact fee accounting and reconciliation.
5. Rehearse Guardian expiry/re-signing, hosted keeper/relay restart and durable message retention;
   establish monitoring and response to original-token balance deficits or issuer changes.
6. Freeze source plus configuration, obtain independent external review, resolve findings and retest.
   The quote can be requested now with the unresolved integration/governance items made explicit.

No local test can establish issuer solvency, future governance behavior, legal permission or 100%
security. These specific unresolved dependencies are not counted as passed tests.

## Reproduction

```sh
bash tools/check.sh
python3 tools/mutation_check.py
bash tools/check_live.sh
python3 tools/network_probe.py
python3 tools/network_probe.py --network robinhood --block-tag latest
python3 tools/verify_live_vaa.py
```

The last three commands are read-only evidence collectors. `network_probe.py` exits nonzero for
incomplete required reads (currently Robinhood finalized state). `verify_live_vaa.py` exits nonzero
unless both source directions are observed and verified; its current reverse-direction failure is
expected, recorded and unresolved. Never interpret an exit code from a separate successful command
as converting those failures into passes.

`check_live.sh` uses public RPC defaults and accepts `ROBINHOOD_REVIEW_RPC`, `ARC_REVIEW_RPC` and
optional `ROBINHOOD_REVIEW_BLOCK` / `ARC_REVIEW_BLOCK` pins. It runs only `forge test`, not broadcasts.
The local suite does not quietly skip these tests: network tests are in a separate explicit profile.
Do not share logs containing private RPC credentials. Packaged observations use only public URLs.

Public references: [Robinhood connection details](https://docs.robinhood.com/chain/connecting/),
[official asset registry API](https://docs.robinhood.com/chain/stock-token-apis/),
[Arc connection details](https://docs.arc.io/arc/references/connect-to-arc),
[Wormhole Core addresses](https://wormhole.com/docs/reference/contract-addresses/).
