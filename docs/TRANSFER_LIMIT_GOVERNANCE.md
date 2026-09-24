# Timelocked transfer maximum — 24 September 2026

Historical checkpoint. The subsequent revision removes shared capacity/refill and mandatory pauses
for limit updates; it introduces separate monotonic receive preparation before outgoing increases.
See `NO_RATE_LIMIT.md` for the current behavior and evidence. This checkpoint's logs are preserved
in `audit/baseline-before-rate-removal-20260924.tar.gz`.

Current revision: `maxTransfer` can change through the endpoint owner, intended to be the deployment
timelock. No total reserve/supply cap was restored. Bucket capacity and refill duration remain fixed.
No public deployment, signature or transaction was performed.

## What the time limit means

The example configuration has capacity 100 token units, maximum 10 per initiation, and refill period
3,600 seconds. With capacity available, initiation can proceed immediately. An empty bucket recovers
10 units in six minutes or its full 100 units in an hour if no one consumes its capacity in between.
There is no mandatory one-hour wait on every transaction. This is continuous refill, not a fixed
hourly window: an initially full bucket permits a burst plus subsequent replenishment.

Capacity is shared by users of that asset pair, with separate inbound/outbound buckets at each
endpoint. It is not a per-user allowance, custody term, message deadline or bound on Wormhole latency.
Exhausted source capacity makes initiation revert atomically. Exhausted destination capacity makes
completion retryable with the same VAA; the bridge does not automatically queue and execute it.
The one-hour example and numerical amounts are not approved production risk settings.

The accepted initial reference is approximately USD 100,000 equivalent per operation, converted to
raw units separately for each stock during configuration. The contract has no USD price oracle.
A fixed token maximum changes in economic value with price and multiplier changes. No production
per-stock raw limits were set in this revision.

## Update behavior

`setMaxTransfer(next)` requires:

- The endpoint owner (timelock in the intended deployment), not the guardian or an ordinary user.
- `0 < next <= rateCapacity`; the fixed bucket capacity is the upper bound on future maxima.
- Outbound initiation paused. The setter neither resumes lanes nor changes bucket state.
- No execution during another nonReentrant operation, including an owner reached through a token callback.

It emits `TransferLimitChanged(previous,next,inboundMaximum)`. New deposits check the new maximum
against the gross amount; new burns check it against the burn amount. Fee rate, accounting, replay
protection, message wire format and token metadata behavior are unchanged.

Incoming `inboundMaxTransfer` starts at the initial maximum and retains the highest maximum ever
configured locally. Raising the maximum raises this ceiling; lowering it does not reduce the ceiling.
This preserves older deposit and burn claims whose amounts exceed a later outgoing maximum.
There is no automatic expiry of this historical acceptance. Incoming messages still need valid
Guardian verification, the bound peer/domains/asset/action, unused sequence, sufficient bucket
capacity and all normal backing and transfer checks.

Consequently, lowering the maximum is a policy for new local initiations, not a mechanism for
retroactively rejecting incoming messages. Use immediate inbound pause during suspected fraud.
A cross-chain change is not atomic; if settings diverge, some claims may need a later governance
correction before they can be completed. The capacity ceiling remains absolute for each bucket.

## Timelock and coordination

The deployment timelock starts at least 48 hours. The standard governor can later change its delay
or transfer endpoint ownership as previously documented; this change does not add a permanent
minimum-delay guarantee or remove existing governance trust assumptions.

Schedule both changes first. Once mature, pause new outgoing requests on both chains, execute both
setters, update approved configs and run paired `preflight.py --phase maintenance`. This mode
requires outbound paused, permits inbound completion, and checks current/historical maxima along
with normal code/governance/domain/backing checks. Resume through mature timelock operations only
after both sides match. Scheduling does not require 48 hours of paused service. If one chain fails,
keep new initiations paused while reconciling the pair.

`inboundMaxTransferRaw` is a required expected-state config field. On a fresh deployment it must
equal `maxTransferRaw`; after lowering a live maximum it retains the historical ceiling. Preflight
rejects unexpected current or historical maxima. Constructors are otherwise unchanged by this
revision, but endpoint storage/runtime code changes. Use the new audit manifest/code hashes.

## Validation

- 105 Solidity tests passed, including 11 new governance scenarios and a constructor-config regression.
- Audit profile: seven fuzz tests with 2,048 cases each; invariant 512 runs at depth 128, including
  random paired maximum changes, mixed transfers, pauses, delayed delivery and pending-message drain.
- 58 Python tests passed, including approved/unapproved limit changes, historical-ceiling consistency
  and the outbound-only maintenance preflight. The full check script passed before the final two
  maintenance regressions; the Python suite was then rerun after that tooling change.
- All 21 compiling security mutations detected, including removed limit authority, reentrancy,
  outbound-pause requirement and old-claim preservation.
- Slither: zero High/Medium, six reviewed Low timestamp findings. Formatting, coverage, gas and demo passed.
- 19 fork tests passed, covering all twelve selected stocks, SPY and Core/VAA checks. Each selected
  stock's round trip now lowers the receiving endpoint's outgoing maximum before completing the
  older larger deposit/burn claim. Treasury rotation and the four issuer scenarios remain covered.

Fork pins: Robinhood **71237133**, Arc **22491184**; block hashes rechecked after execution, saved in
`audit/readiness-review/mutable-transfer-limit-fork-pins.json`. These are recent/latest pins, not
finalized-state evidence. Test balances and issuer role/block responses are injected locally;
Synthra return attestations are simulated. The independent real signed VAA remains a third-party
consistency-202 fixture, not a live Synthra level-0 round trip. Implementation identities were not
recollected at these new pins; earlier identity snapshots remain historical evidence.

Current hashes: `audit/mutable-transfer-limit-review-snapshot.json`, `audit/RELEASE_MANIFEST.json`.
Prior archive: `audit/baseline-before-mutable-transfer-limit-20260924.tar.gz`, SHA-256
`4645e24a606295be9d2e3bf30c3709b29e02743d07805f46f13f446bfdbc1cad`.
These are internal verification results for an external audit, not production certification.
