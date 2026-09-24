# Network and asset integration evidence

Evidence collected September 23–24, 2026. The latest fork run against the current production source
uses a 30-day metadata lifetime and passed **19 tests, with none failed or skipped**, including all twelve selected stocks. All network
interactions were read-only; fork state changes were local. No public Synthra deployment or
transaction was performed. These checks are internal compatibility evidence, not launch approval.

The subsequent shared hardware-wallet governance change affects deployment/preflight only. This
fork run was not repeated for that policy change: production contracts and integration inputs are
unchanged. Shared-role timing and authority are validated separately by local deployment tests.

## Selected stocks and scenarios

The fixture `config/stock-assets.example.json` contains NVDA, META, PLTR, GOOGL, AAPL, MSFT, INTC,
AMZN, AMD, TSLA, COIN, and AVGO. It contains public asset addresses, not production operator settings.
Selection research and registry snapshots are retained under `audit/readiness-review/`.
The selection is not a comprehensive ranking by token trading volume: DEX observations are provider
pool snapshots, while Robinhood's `dailyTradingVolume` describes underlying equities.

The suite contains twelve individual stock tests, four issuer-interference tests that each loop
over all twelve stocks, one SPY regression, and two Core/VAA tests: 19 test functions total.
Every selected stock passes the nominal path and all four issuer scenarios.

Nominal checks cover ticker/UID, 18 decimals, current/pending UI metadata, deposit fees, treasury
rotation, and return. A 100-token deposit locks 99.5 and immediately pays 0.5 in fees. The real source
Core publishes the expected payload locally. A later deposit pays its fee to the new treasury while
preserving previous fees and backing. A separate mock-attested route mints, burns, and returns
99.5 originals, ending with zero supply/backing for that route. Current tests also complete claims
initiated before outgoing maxima are lowered, without requiring a pause or time advance.

Issuer scenarios cover blocked treasury with atomic rollback and treasury replacement, blocked
recipient with retry after unblocking, issuer pause with retry after resumption, and reserve
destruction that blocks unsafe operations until externally supplied collateral restores backing.
The latter is test-funded recapitalization, not insurance or automatic recovery.

Two additional Core tests cover Arc identity/unsigned-message rejection and an existing signed
Guardian VAA accepted by both Core implementations but rejected as a foreign Synthra emitter;
tampering invalidates its signatures.

## Latest fork pins and simulation boundaries

| Network | EVM / Wormhole chain IDs | Block | Hash |
| --- | --- | --- | --- |
| Robinhood | 4663 / 72 | 71270443 | `0x5d6e745cc2672e8f545a227c808c5a562b0f74b7401c71ffd0b6ea3aa84aa2c6` |
| Arc | 5042 / 71 | 22497821 | `0x09347dbc5436f29c459f6b2ceefa768c17a9006350926f9ea36e117627434605` |

Both block hashes were rechecked after execution. These are recent/latest pins, not finalized-state
evidence. See `audit/readiness-review/current-fork-pins.json`, `audit/live-fork-tests.log`, and
`audit/current-review-snapshot.json` for observations, output, and source/evidence hashes.

Balances are injected locally with Foundry `deal`. Issuer role/block responses are mocked while
real token bytecode executes transfers, pauses, and burns. Bridge instances, treasury addresses,
and return attestations are test fixtures. The destination route uses chain-ID switching within
shared local storage. This is not a live Synthra round trip, proof of future Guardian availability,
or verification of real operator-address eligibility.

## Dated identity and RPC observations

At the earlier Robinhood block 71216322, all twelve token proxies resolved to implementation
`0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2`, runtime Keccak-256
`0xdc07e86ee482f99641bdafb9a0d772846b167401e094d90a666b94dbdcd1eec7`.
Identities were not recollected at the latest fork pins and do not constrain future issuer upgrades.
The earlier registry, pins, and identities remain in `fork-assets-registry-20260924.json`,
`fork-pins-20260924.json`, and `twelve-asset-code-identities.json` under `audit/readiness-review/`.

The September 23 network collectors observed Guardian set 7 on both Core contracts and inspected
runtime/proxy identities. Arc finalized-state reads succeeded; the Robinhood public provider returned
`historical state ... is not available`. A separately labelled latest-state diagnostic succeeded
for AAPL, NVDA, TSLA, and SPY. Latest-state results do not satisfy the finalized-state preflight gate.
Raw observations are under `audit/network/`; these are dated observations, not current provider-status
claims. Old test runs are available through [ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).

## Verified issuer powers: a material launch dependency

The September 23 four-token observation recorded beacon `0xe10b6f6b275de231345c20d14ab812db62151b00`, resolving to
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

## Remaining launch gates

- Verify current token registry/beacon control and escrow/treasury eligibility; complete the issuer
  and distribution assessment. Fork compatibility does not establish permission or issuer solvency.
- Obtain reliable finalized/archive state on both networks and independently approve Core
  implementations, governance, finality policy, and observation in both directions.
- Verify the selected hardware-wallet governance/guardian account and deployment signer; complete
  treasury addresses and per-stock raw-token maxima/receiving ceilings. Safe thresholds/modules need
  review only if contract wallets are chosen. Metadata lifetime is 30 days. There is no aggregate cap
  or rate bucket.
- Freeze source and permitted configuration, obtain independent external review, resolve its findings,
  and retest before production deployment. Public deployment is not a prerequisite for that audit.
- After audit and deployment approval, verify deployed code/configuration and exercise both directions
  with real Guardian attestations, including fees, failed relays, delayed delivery, and reconciliation.
- Rehearse user-submitted completion, interrupted-session recovery, and signature replacement; retain
  message identity and monitor issuer, governance, metadata, and collateral changes. Users perform
  both bridge transactions; no automatic relayer is planned. Metadata publication/completion must
  still be performed before expiry or on changes. Manual unsigned preparation tools are included;
  the complete frontend retrieval/recovery flow and monitoring remain integration work.

## Reproduction

```sh
ROBINHOOD_REVIEW_BLOCK=71270443 ARC_REVIEW_BLOCK=22497821 bash tools/check_live.sh
python3 tools/network_probe.py
python3 tools/network_probe.py --network robinhood --block-tag latest
python3 tools/verify_live_vaa.py
```

Historical replay needs archive-capable RPCs. Override `ROBINHOOD_REVIEW_RPC` and `ARC_REVIEW_RPC`
if public providers have pruned state. Omitting block overrides checks a different snapshot.
`check_live.sh` runs only fork tests, never broadcasts. Local checks use a separate profile and do
not silently skip network tests. Do not publish private RPC credentials in evidence logs.

The collectors are read-only. `network_probe.py` fails on incomplete required state reads.
`verify_live_vaa.py` requires verified observations in both source directions; the recorded reverse
route check failed. A successful unrelated command does not convert that failure into a pass.
The limited 10,000-block Arc scan and empty chain-71 API result do not prove absence of historical
messages or unsupported routing. No later successful reverse-route observation is claimed here.

Public references used for the recorded research: [Robinhood connection details](https://docs.robinhood.com/chain/connecting/),
[official asset registry API](https://docs.robinhood.com/chain/stock-token-apis/),
[Arc connection details](https://docs.arc.io/arc/references/connect-to-arc), and
[Wormhole Core addresses](https://wormhole.com/docs/reference/contract-addresses/).
