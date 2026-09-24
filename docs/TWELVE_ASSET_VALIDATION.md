# Twelve-stock fork validation — 24 September 2026

**Historical checkpoint before total-cap removal.** The subsequent removal of aggregate reserve/supply caps and current
validation are documented in `TOTAL_CAP_REMOVAL.md`. Earlier retained-cap statements describe
the preceding revision, not the current source.

Result: **19 tests passed, 0 failed, 0 skipped** against the current source including treasury
rotation. No public deployment, transaction or bridge message was sent. Production Solidity was
unchanged by this test expansion. This is internal compatibility evidence for external review.

## Assets and scenarios

| Stock | Deposit, fee, treasury rotation, metadata, mock-attested return | Four issuer scenarios |
| --- | --- | --- |
| NVDA | PASS | PASS |
| META | PASS | PASS |
| PLTR | PASS | PASS |
| GOOGL | PASS | PASS |
| AAPL | PASS | PASS |
| MSFT | PASS | PASS |
| INTC | PASS | PASS |
| AMZN | PASS | PASS |
| AMD | PASS | PASS |
| TSLA | PASS | PASS |
| COIN | PASS | PASS |
| AVGO | PASS | PASS |

The suite contains twelve individual stock tests, four aggregate issuer tests (each loops over all
twelve stocks), an additional SPY regression, and two Core/VAA tests. This is 60 selected-stock
scenario combinations inside 16 tests, plus the three regressions: 19 test functions, not 60.

For every stock, the tests check the official ticker and UID, 18 decimals, a positive UI multiplier,
and current/pending metadata. A 100-token deposit produces 99.5 escrow and 0.5 immediate fees.
The real source Core publishes the expected payload locally. A subsequent deposit after treasury
rotation sends only its fee to the new treasury, preserving prior fees and backing. The separate
mock-attested route mints 99.5 wrapped, propagates metadata, burns and returns exactly 99.5 originals,
leaving zero supply and backing for that completed route.

For each stock, the four issuer scenarios check:

1. A blocked treasury rolls back the deposit; changing to an eligible treasury restores deposits.
2. A blocked recipient prevents release while preserving the claim for retry after the block clears.
3. Issuer pause prevents release while preserving the claim for retry after unpause.
4. Issuer reserve destruction blocks unsafe operations; locally supplied replacement reserves allow
   recovery. Recapitalization is an external contribution, not automatic insurance.

The two Core tests cover Arc identity/unsigned-message rejection and an existing real Guardian VAA
accepted by both Core implementations but rejected as a foreign Synthra emitter; tampering fails.

## Pinned evidence

| Network | EVM chain | Block | Hash |
| --- | --- | --- | --- |
| Robinhood | 4663 | 71216322 | `0xff326f5fb2e6f26496cb4582f8a35177cb07dc42f9b9864e1c2c7111740054eb` |
| Arc | 5042 | 22487048 | `0xefbb56f542b25ecae5c585fc694e1e73cd64a7bd54d6e4bd97e8a9f4cca2f720` |

Both block hashes were checked again after execution. These are pinned recent/latest snapshots,
not proof of finalized state. The twelve addresses matched the freshly read
[official asset registry](https://api.robinhood.com/rhj/assets). The fixture is
`config/stock-assets.example.json`; it contains public asset addresses, not operator configuration.

All twelve token proxies resolve at the pinned Robinhood block to implementation
`0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2`, runtime Keccak-256
`0xdc07e86ee482f99641bdafb9a0d772846b167401e094d90a666b94dbdcd1eec7`.
This observation does not constrain future issuer upgrades or audit its governance.

Evidence files:

- `audit/baseline-before-total-cap-removal-20260924.tar.gz`: contains the original
  `audit/live-fork-tests.log` from this checkpoint; the loose log now records the newer rerun.
- `audit/readiness-review/fork-assets-registry-20260924.json`: official registry snapshot.
- `audit/readiness-review/fork-pins-20260924.json`: initial block pins.
- `audit/readiness-review/twelve-asset-code-identities.json`: per-token identities, RPC traces and
  post-test block-hash verification.
- `audit/twelve-asset-review-snapshot.json`: source, test, fixture and evidence hashes.

Reproduce with an RPC provider that retains state at these blocks:

```sh
ROBINHOOD_REVIEW_BLOCK=71216322 ARC_REVIEW_BLOCK=22487048 bash tools/check_live.sh
```

Public providers may prune historical state. Override `ROBINHOOD_REVIEW_RPC` / `ARC_REVIEW_RPC`
with archive-capable providers if necessary. Omitting block overrides tests a different snapshot.

## Limits and decisions

Balances are injected locally with Foundry `deal`. Issuer role/block registry responses are mocked
for interference scenarios; the real token bytecode executes the resulting transfers/pause/burn.
Bridge instances and treasury addresses are local fixtures. Return-flow attestations are mocked,
and the destination leg uses chain-ID switching in the same local storage environment. The separate
real signed VAA is a third-party publication with consistency 202, not a Synthra level-0 round trip.
These tests do not establish Guardian liveness, real operator-address eligibility or production
finality. Those limitations are not requirements to deploy publicly before the external audit.

Cap, maximum transfer and token bucket remain in place following the user's updated preference.
The cap limits total recorded exposure; the maximum limits one operation; the bucket limits flow
over time. Splitting transfers bypasses the usefulness of a per-operation maximum alone. Limits
are additional defenses and do not guarantee bounded losses under every exploit or prolonged
compromise. They apply equally to users without an individual allowlist. Production numerical
values still need sizing per pair before deployment; test/example values are not launch approval.

The existing 92 Solidity / 49 Python / 17 detected-mutation baseline was not rerun for this
integration-only expansion. Its source/test/vendor/compiler input hashes still match. Formatting
was checked and the expanded 19-test fork suite was newly executed. The thirteenth-pair addition
and pair isolation remain covered by the existing local `AssetExpansion.t.sol` tests.
