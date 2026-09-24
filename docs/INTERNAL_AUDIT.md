# Synthra RWA Bridge — adversarial internal review

**Historical review log.** The subsequent removal of aggregate reserve/supply caps and current
validation are documented in `TOTAL_CAP_REMOVAL.md`. Earlier retained-cap statements describe
the preceding revision, not the current source.

Date: 23 September 2026. Status: local review complete; production launch not approved.

Historical baseline: production source was subsequently changed on 24 September to allow treasury
rotation. The statements below that source was unchanged apply to the 23 September review only.
See `TREASURY_CHANGE.md` and current validation evidence for the subsequent revision.

This is an internal, AI-assisted engineering review performed in the same development context as
the implementation. It uses an external-review style, but is **not an independent third-party audit**,
a formal verification, or a guarantee of complete security. No auditor was contacted and no payment,
deployment, signing or public-chain transaction was performed as part of this review.

## Executive decision

No Critical, High or Medium **implementation vulnerability exploitable without the assumed trusted
authorities** was reproduced in this local review. Three Low findings in release/deployment checks
were corrected. This statement is scoped to the tested model; it does not establish the security of
live Wormhole, the issuer, networks or operational wallets. The six Low Slither timestamp warnings
are separate, reviewed findings, not six newly discovered exploits.

An indicative audit quote can use this package. Before committing to a final audit scope and price,
freeze the actual asset/Core interfaces, finality policy, immutable paired limits, governance policy
and delayed-message recovery procedure. Otherwise the paid review may need to be repeated after an
integration or governance redesign. A final mainnet audit must review the resolved configuration as
well as the source.

The production contracts in `src/` remain byte-for-byte identical to the starting candidate. Changes
are in operational validation, test coverage, analysis gating, explicit compiler configuration and
documentation. The review did not silently remove governance powers or add a privileged refund path.

The additional real-network review is documented in [INTEGRATION_REVIEW.md](INTEGRATION_REVIEW.md),
including confirmed issuer block/pause/admin-burn powers and the unresolved reverse messaging route.

## Identity and scope

Starting archive SHA-256:
`1cb14ba96e6717186201c226980b4fea8c7a00c740c0428a5c694b7c1027527c`.

The source tree was compared with that archive's manifest before review; no non-report differences
were present. The new handoff archive is identified by `audit/SHA256SUMS` and its included manifest.
`audit/internal-review-snapshot.json` records the production source hashes and comparison.

Reviewed: all eight Solidity files under `src/`, `script/Deploy.s.sol`, tests and mocks, invariant
model, vendored dependency selection, unsigned relay helper, preflight, packaging and CI/analysis
checks. The eight production files plus deployment script contain 769 physical lines including
comments and blanks; this is not a normalized audit SLOC estimate.

Assumptions challenged: authentication and exact domain binding; replay identity across signature
sets; 0.5% fee rounding and atomic payout; net backing; delayed/reordered deposit and redemption;
mint/burn authorization; exact token balance deltas; reentrancy; separate rate buckets, max transfer
and outstanding cap; role transitions; metadata sequence/freshness/cancellation; deployment coherence.

## Findings and disposition

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| IA-01 | Low | Configuration coercion accepted values not valid for the intended Solidity configuration | Fixed; regression tests pass |
| IA-02 | Low | Network preflight omitted several code-identity, pending-authority and metadata checks | Fixed within the stated preflight scope; historical roles/proxy implementations remain manual gates |
| IA-03 | Low | Static-analysis gate accepted all findings in the timestamp category | Fixed; exact reviewed-location/expression matching and incomplete-output rejection |
| OBS-01 | Informational / governance trust | Initial two-day delay is mutable and does not restart on a fresh emergency pause | Reproduced and documented; governance design decision remains open |
| OBS-02 | Informational / conditional liveness | A mismatched remote maximum can make a valid funded transfer permanently unexecutable | Existing pair validator rejects mismatch; added executable failure demonstration |
| OBS-03 | Informational / external liveness | Guardian rotation and expiry can prevent retry of an otherwise valid pending message | Reproduced; re-signing compatibility demonstrated locally, live recovery remains open |

### IA-01 — integer coercion in configuration validation

Location: `tools/preflight.py:validate_pair`.

The original parser used `int(value)`. Both files could contain `maxTransferRaw: 10.9`; validation
silently compared 10. It also accepted `capRaw = 2**256`. A same-Wormhole-domain pair could evade the
final inequality by mixing string `"100"` and integer `100`, despite numeric reciprocal checks.
All three inputs were executed against the original validator and were accepted.

Impact: false-positive configuration approval and disagreement with Solidity parsing/constructor
rules, primarily failed or unsafe operator preparation. This is not an on-chain fund-theft exploit;
the constructors independently reject several such invalid inputs.

Fix: strict decimal unsigned integers, explicit bit widths, no booleans/floats/exponents/whitespace,
and numeric local/remote inequality on both sides. Evidence: four additional tests in
`tools/test_preflight.py`, including boundary and rejected-coercion cases.

### IA-02 — incomplete network preflight assurance

Location: `tools/preflight.py:inspect`, `config/pair.example.json`.

Previously, only endpoint and Core runtime hashes were compared. A pending endpoint ownership
transfer was not rejected; cancellation authority was not checked; the active phase could return
success with stale wrapped metadata. The full network-inspection function had no RPC-fixture tests.
The original runbook already required manual review of historical roles and Core implementations;
this finding does not claim the tool ever proved those properties.

Fix: require approved timelock and source-asset/destination-wrapped runtime hashes; reject a pending
owner; check cancellation and timelock self-admin authority, closed-role policy and governance/guardian
contract existence; verify wrapped origin/domain/decimals; require fresh metadata in active phase.
Thirteen adversarial network-fixture tests now cover those checks, finalized-block requirements,
block-hash change, backing deficit and fee mismatch. These are simulated RPC results, not live reads.

Residual: hashes of proxy shells do not identify their implementations. Additional role holders,
Safe modules/signers/thresholds, pending timelock operations, issuer eligibility and source asset
authenticity still require the deployment-specific review. A malicious RPC remains outside this
tool's trust model. Open executors are not inherently an exploit; this release rejects them because
the deployment script specifies a closed executor policy.

### IA-03 — blanket timestamp-category suppression

Location: `tools/check_slither.py`.

The old gate accepted any finding with `check == "timestamp"`, including a new function or materially
different expression that had never been reviewed. It could also treat a successful-looking response
without detector results as an empty findings list.

Fix: compare detector, severity, source file, function and flagged expressions against the six
reviewed entries in `tools/slither-reviewed.json`. Reject missing analysis output and all High/Medium
results. Five regression tests cover newly introduced expressions/locations and invalid outputs.
Fingerprinting is a review gate, not proof that unchanged expressions are safe in every new context.

### OBS-01 — governance guarantees are conditional

`TimelockController.updateDelay(0)` can be scheduled under the existing delay and then executed.
Subsequent operations may be immediate. `Ownable2Step` also allows a delayed transfer to an EOA,
which can subsequently resume lanes without a timelock. Finally, an unpause scheduled earlier and
already ready can execute immediately after a new guardian pause. These behaviors are all reproduced
in `InternalAudit.t.sol` and do not give an arbitrary outsider governance authority.

Impact: emergency containment depends on the governance/canceller Safe and its queue, not solely on
the emergency guardian. There is no permanent 48-hour floor or guaranteed post-pause waiting period.
Operations documentation now requires inspection/cancellation of incompatible queued unpauses.

Decision before scope freeze: retain this documented governance model, or commission a design that
enforces a permanent floor/owner topology and binds resumption to a particular pause. Such a change
would alter protocol behavior and needs its own audit. No such redesign is included here.

### OBS-02 — pair compatibility is a safety prerequisite

The local demonstration deploys a source maximum of 1,000 tokens and destination maximum of 1 token.
A 10-token deposit succeeds, collects its fee, and locks 9.95. The authenticated message cannot mint,
even after 30 days, because waiting cannot change the destination's immutable maximum. A unilateral
refund would create a double-spend risk and is deliberately unavailable.

This requires an incorrectly configured/activated pair, not a permissionless caller modifying limits.
`validate_pair` already enforces equal caps, capacities, refill periods and maxima. Complete its checks
and verify actual deployed values before enabling any lane. Do not activate each side independently
without the paired review. The test preserves this failure mode as a deployment warning.

### OBS-03 — retry has a Guardian-set availability condition

An unchanged VAA can fail after its Guardian set expires, despite the bridge imposing no transfer
deadline. A local test rotates the set, waits two days, confirms failure, then signs the **same message
body** with an accepted set and completes the pending mint. Signing the already-consumed body again
does not bypass emitter/sequence replay protection.

Wormhole documents a [signature replacement procedure](https://wormhole.com/docs/products/messaging/tutorials/replace-signatures/).
The synthetic test does not prove that a live quorum will re-observe this application's historical
messages. Rehearse the exact operational recovery path and retention requirements before funding.
Without an accepted attestation, the current immutable design has no independent recovery route.

## Evidence and adversarial coverage

| Check | Result | Evidence |
| --- | --- | --- |
| Solidity unit/fuzz suite | 81 passed, zero failed/skipped | `audit/unit-tests.log` |
| Audit fuzz profile | Six fuzz tests, 2,048 cases each | `audit/audit-tests.log` |
| Stateful conservation | 512 × 128 = 65,536 handler calls, zero unexpected reverts | `audit/audit-tests.log` |
| Signed native VAA verification | 13 tests using unmodified pinned Wormhole verifier, synthetic keys, distinct EVM domains | `test/SignedVAA.t.sol` |
| Live-fork compatibility and issuer interference | 10 passed | `audit/live-fork-tests.log`, `INTEGRATION_REVIEW.md` |
| Operational Python tests | 47 passed | `audit/python-tests.log` |
| Targeted mutation testing | All 15 compiling mutations detected by failing tests | `audit/mutation-report.json` |
| Slither | No High/Medium; six explicitly reviewed Low timestamp findings | `audit/slither.json` |
| Dependency provenance | 63 upstream files byte-matched; 65 local locked files checked | `audit/dependency-verification.json`, vendor lock |
| Formatting, gas, local demo | Completed | standard audit logs |

The stateful model uses distinct EVM domains 111/222 with chain-ID switching (shared local storage).
It uses cap > bucket capacity > maximum transfer, randomly changes pause lanes,
interleaves delivery and transfers between holders, and calculates fees independently rather than
calling the implementation's quote function. It checks gross deposits = remaining locked + paid
fees + originals released, as well as supply plus pending claims. Handler calls may legitimately be
no-ops when a lane is paused, a balance is empty or capacity is unavailable; they are not 65,536
completed transfers. Final draining assumes honest delivery, restored lanes and valid attestations.

New tests also exercise exact reserve-cap filling, depositor equal to treasury, dirty ABI high bits,
wrong entry points without claim consumption, release reentrancy, raw transfers while everything is
paused and metadata stale, normalized expired schedules, duplicated/out-of-bounds Guardian indices,
unsupported VAA versions and truncation. Relay-helper tests confirm simulation only, wrong-chain
rejection, failure on reverted calls and bounded input sizes; no transaction submission is exercised.

Mutation testing removes or changes VAA validity, emitter/domain/endpoint binding, replay protection,
pause enforcement, rate limiting, resume authority, fees/backing, exact recipient credit, mint amount,
burn and metadata freshness/order. Compilation errors are not counted as detected defects. This is
a finite sensitivity experiment, not a claim that every possible vulnerability would be detected.

## Dependency and compiler review

Pinned upstream bytes were downloaded from the URLs recorded in the provenance files and compared
without running downloaded code. Local lock verification alone would not have established this.
The OpenZeppelin [advisory index](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories)
was reviewed against the included components. Entries concerning Bytes.lastIndexOf, Base64,
Multicall, ERC2771Context, MerkleProof, Governor and proxy components do not apply to this vendored
production subset. This does not re-audit OpenZeppelin or the live Wormhole implementation.

The official [Solidity known-bugs list](https://raw.githubusercontent.com/ethereum/solidity/develop/docs/bugs.json)
was checked for 0.8.28. SOL-2026-1/2/4/6 require via-IR; this build explicitly uses `via_ir = false`
and EVM Paris. SOL-2026-3 was introduced after this compiler version. SOL-2026-5 concerns deleting
individual memory-byte-array elements; production sources and vendored OpenZeppelin use no such
operation. SOL-2025-1 concerns arrays crossing the end of storage; no custom layout or intentionally
boundary-spanning array is used here. These applicability assessments must be repeated after any
compiler, pipeline, dependency or source change; retaining 0.8.28 is not a blanket compiler endorsement.

## Open launch gates and limits of this review

1. **Real asset selection and semantics:** original address/registry, proxy implementation, escrow and
   treasury transfer compatibility, freeze/seizure/upgrade powers and handling of every relevant
   corporate action. Off-chain cash distributions would not automatically flow through this code.
   Ten fork tests now cover four real token implementations/interfaces and issuer interference; actual launch configuration and issuer control review remain open (see `INTEGRATION_REVIEW.md`).
2. **Live messaging/finality:** actual Core implementations and governance, chain IDs, source finality,
   Guardian observation and end-to-end attestations in both directions. The
   [Core address list](https://wormhole.com/docs/reference/contract-addresses/) expressly does not prove
   live connectivity. The current [finality table](https://wormhole.com/docs/reference/consistency-levels/)
   lists finalized level 0 for Arc and Robinhood; unit-test level 1 is synthetic; the example config uses 0, which is still not deployment approval. Verify the selected implementations and policy before deployment.
3. **Operational readiness:** recovery after Guardian rotation/outages, durable relaying and event
   reconciliation, monitoring, queue cancellation, Safe signers/modules and launch risk limits. A
   permissionless entry point does not operate itself or guarantee fair scheduling under congestion.
4. **Issuer/distribution compatibility:** confirm the intended wrapper distribution against the issuer's
   terms; this review supplies no legal authorization. Permissionless code does not settle that question.
5. **Independent audit and real-network rehearsal:** externally review the frozen source/configuration,
   resolve findings, then test actual-network round trips and incident handling before funding mainnet.

No approved production network configuration exists in this package. The follow-up in
`INTEGRATION_REVIEW.md` records ten successful live-fork tests, actual token bytecode/source checks,
issuer intervention simulations and a real signed Robinhood-origin VAA. No deployed Synthra
end-to-end transfer or production pair preflight has been validated. No hosted worker, indexer, frontend, price
oracle or liquidity integration was audited. A same-context internal review cannot remove correlated
design blind spots and is not a substitute for the requested independent audit.

## Reproduction

```sh
bash tools/check.sh
python3 tools/mutation_check.py
python3 tools/verify_upstream.py  # public network reads only
python3 tools/package_audit.py
```

`mutation_check.py` creates and deletes a disposable copy; it does not mutate the production tree.
Do not weaken assertions, static-analysis acceptance or risk disclosures merely to obtain a green run.
