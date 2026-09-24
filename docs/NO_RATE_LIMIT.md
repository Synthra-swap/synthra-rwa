# No shared capacity, refill or routine pause — 24 September 2026

The user rejected shared throughput capacity because it makes users compete for a common allowance.
This revision removes TokenBucket, its state, its configuration and its checks on both endpoints.
There is no total reserve/supply cap, rate quota, automatic cooldown or refill wait. The maximum for
one outgoing request remains, adjustable through timelock without a mandatory pause.

## Resulting behavior and risk

One user's completed transfer does not consume another user's capacity. Repeated requests can
execute in the same block, subject to balances, allowance, individual amount limits, valid messages,
network execution and the original issuer's restrictions. Wormhole finality/attestation latency
remains separate. The protocol does not promise instantaneous cross-chain completion.

A per-operation maximum can be bypassed by splitting an aggregate amount into multiple requests.
It is an operational policy, not a bound on total throughput or potential losses. Removing the
bucket removes the automatic slowdown that might have provided time to react to an incident.
Existing authentication, replay protection, exact backing checks, fee accounting, reentrancy guards
and the guardian's immediate emergency pause remain. Wrapped ERC20 transfers remain unpaused.
The initial paused deployment/setup procedure is also unchanged; no public deployment was performed.

The initial amount reference remains about USD 100,000 equivalent, converted into raw token units
per stock during configuration. No USD oracle or automatic price adjustment was added. Production
raw-token limits and operator addresses remain to be selected.

## Maximum changes while service continues

- `prepareInboundMaxTransfer(next)` is owner-only and nonReentrant. It accepts only a strict increase
  of the incoming per-message ceiling and emits `InboundTransferLimitRaised(previous,next)`. It does
  not increase the outgoing maximum, authenticate a message or change any balance.
- `setMaxTransfer(next)` is owner-only and nonReentrant. It requires a positive value covered by the
  locally approved incoming ceiling and emits `TransferLimitChanged(previous,next,inboundMaximum)`.
  It changes new outgoing requests only. It does not require or alter pause flags.
- Incoming ceilings never decrease, preserving messages sent before a later outgoing reduction.
  They are per-message bounds, not a shared quota, and their prior approvals do not expire.
- Prepare receive ceilings on BOTH chains and verify them before activating a larger outgoing
  maximum. Users can keep using the old maximum while this happens. During sequential outgoing
  updates the receivers already accept the larger amount. A local contract cannot enforce remote
  execution order; violating this procedure may delay claims until receive approvals are corrected.

Both governance actions use the existing timelock, initially at least 48 hours. That delay does not
apply to ordinary transfers or guardian emergency pause. Previously documented governance powers
to change its own delay or migrate ownership remain; no permanent delay guarantee was introduced.

The former bucket upper bound on the maximum is gone. Values must fit uint256, and outgoing values
must fit the approved incoming ceiling. Operators should not interpret numeric representability as
an economically appropriate setting. Active paired preflight checks expected incoming/outgoing
values; optional maintenance mode remains available only for deliberately paused operations.

## Source and configuration changes

Changed production source: `src/WormholeEndpoint.sol`. Deleted `src/TokenBucket.sol`.
Removed constructor Config members `rateCapacity` and `refillSeconds`, their getters and available-
capacity getters. Constructor ABI/runtime/storage therefore differ from the previous candidate.
Updated constructor callers, deploy script, preflight, invariant handler and adversarial tests.
Legacy config fields `capRaw`, `rateCapacityRaw` and `refillSeconds` are rejected explicitly.
Fresh deployment still initializes both per-message maxima equally. Message payload format is unchanged.

## Fresh validation

- Full `tools/check.sh` passed: **109 Solidity tests**, **60 Python tests**, audit fuzz/invariant
  profile, coverage, gas report, local demo and static analysis.
- Invariant campaign: 512 runs at depth 128 = 65,536 handler calls; paired maximum changes, pauses,
  transfers and delayed delivery preserve backing and all pending claims, with no unexpected reverts.
- Seven fuzz tests, 2,048 cases each in the audit profile.
- Tests demonstrate 32 users depositing and redeeming in one block, 20 immediate repeated round
  trips, growing pending/supply amounts without an aggregate cap, and batches completed after a
  maximum decrease without advancing time. Individual maximum and replay checks remain enforced.
- Fourteen transfer-governance tests cover authority on both methods, timelock maturity while service
  continues, strictly increasing receive approvals, zero/unprepared-value rejection, orderly increases
  without pause, prior claims after decreases, callback protection and full uint256 configuration.
- **23 compiling security mutations detected**. Obsolete rate/pause mutants were replaced with
  outgoing/incoming maximum checks; receive-preparation authority/reentrancy/monotonicity are tested.
- Slither: **0 High/Medium**, **4 reviewed Low** timestamp findings. The two bucket timestamp findings
  disappeared with the deleted library, and were removed from the reviewed-finding registry.
- **19 fork tests passed** again, including all twelve selected stocks, treasury rotation, legacy
  deposit/burn completion after lowering maxima without pausing, issuer interference, SPY and Core/VAA.

Fork blocks: Robinhood **71245557**, Arc **22492863**. Both hashes rechecked after execution;
`audit/readiness-review/no-rate-limit-fork-pins.json` contains the observations. Recent/latest pins
are not finalized-state evidence. Balances and issuer role/block responses are injected locally;
Synthra return attestations are simulated. No public transaction was sent. The independent signed
VAA fixture remains a third-party consistency-202 message. Earlier token identity snapshots were
not recollected at these pins and remain historical evidence.

Current hashes: `audit/no-rate-limit-review-snapshot.json`, `audit/RELEASE_MANIFEST.json`.
Previous checkpoint: `audit/baseline-before-rate-removal-20260924.tar.gz`, SHA-256
`c07531620a448f076dfdd5a311417b489cad83bad509cea23368c9b73dd6507c`.
External review is still required. These tests do not certify freedom from vulnerabilities or the
future availability of Wormhole/issuer dependencies.
