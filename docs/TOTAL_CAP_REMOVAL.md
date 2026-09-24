# Aggregate cap removal — 24 September 2026

Historical checkpoint: the later transfer-maximum governance change supersedes statements that
all remaining limits are immutable. See `TRANSFER_LIMIT_GOVERNANCE.md` for the latest behavior and
validation. This checkpoint's logs are preserved in the pre-mutable-limit archive.

The user chose to remove the cumulative reserve/supply ceiling while retaining a reasonably high
per-transfer maximum and the time-based token bucket. This supersedes the preceding decision to
retain all three controls. No public deployment or transaction was performed.

## Resulting behavior

There is no `reserveCap` or `supplyCap` and no corresponding constructor argument or `capRaw`
configuration field. Deposits may accumulate beyond bucket capacity across refills, and the same
applies to wrapped supply. SourceVault still checks existing backing and exact token balance deltas;
DestinationBridge still verifies authenticated, correctly bound, unconsumed messages before minting.
The accounting identity remains `locked = supply + pending deposits + pending redemptions`.

Both directions retain `maxTransfer` and independent inbound/outbound buckets. For example, an
exhausted bucket can temporarily prevent another deposit even though no cumulative cap exists;
after enough refill, a valid transfer can proceed. A request above the immutable maximum must be
split; simply waiting does not make it eligible. On return, holders can burn their balance in
eligible pieces. Limits apply equally to users and do not create an individual allowlist.

The maximum is in 18-decimal raw token units, not dollars or UI-adjusted share counts. A high value
must be selected per stock together with bucket capacity/refill; `0 < maxTransfer <= rateCapacity`
is required, with identical limits on both endpoints. Existing example values remain test fixtures,
not a recommendation or an approved production limit. Limits remain immutable after deployment.

Removing the aggregate ceiling allows total collateral at risk to grow. Rate limits constrain flow
through the checked paths, not every possible exploit or direct issuer action. Monitoring and the
immediate guardian pause remain part of the operational model.

## Implementation and compatibility

Changed production contracts: `src/SourceVault.sol`, `src/DestinationBridge.sol`.
Updated all constructor callers, deployment parameters, preflight, fixtures and invariant handler.
Old JSON containing `capRaw` is rejected by both deployment parsing and preflight to avoid silently
presenting an unenforced cap. The constructor ABI and bytecode changed; use this release's hashes
for external audit and subsequent deployment. No deployed state needs migration.

## Fresh validation of this revision

- `tools/check.sh`: passed, including 93 Solidity tests, 50 Python tests, the audit fuzz/invariant
  profile (65,536 handler calls), coverage, demo, gas report and static analysis.
- Three revised scenarios demonstrate pending deposits above the former ceiling, cumulative supply
  growth across refills with maximum-transfer rejection retained, and a complete return of funds
  above the former ceiling with out-of-order delivery and rate-respecting retries.
- New Solidity/Python regressions reject obsolete cap configuration.
- All 17 compiling security mutations detected; source/test/vendor input hashes rechecked.
- Slither: no High/Medium findings; six previously reviewed Low timestamp findings.
- All 19 real-token fork tests passed again, including all twelve selected stocks, treasury rotation
  and issuer-interference scenarios, SPY regression and Core/VAA checks.

Fork blocks: Robinhood **71225064**, Arc **22488784**. Both block hashes were checked again after
execution and are recorded in `audit/readiness-review/no-total-cap-fork-pins.json`. These are pinned
recent/latest blocks, not finalized-state evidence. The preceding per-token implementation identity
snapshot is historical; it was not recollected for these new blocks.

Fork simulations use injected balances, mocked issuer role/block responses for interference, and
mock attestations for the Synthra return route. They are not a public Guardian round trip. See the
scenario details and limitations in `TWELVE_ASSET_VALIDATION.md`; its original result predates this
change. The current log is `audit/live-fork-tests.log`.

The previous full package is preserved as `audit/baseline-before-total-cap-removal-20260924.tar.gz`
(SHA-256 `411a1ac8f2e662cd483fdfb775ce28f7507f6b74d1d68769aa30b594a1c4e7d2`).
Current source/evidence hashes are in `audit/no-total-cap-review-snapshot.json` and the release
manifest. An external audit is still required; passing tests is not production certification.
