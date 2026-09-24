# Internal review findings and disposition

This is an internal, AI-assisted engineering review performed in the same development context as
the implementation. It is not an independent third-party audit, formal verification, or production
approval. No public deployment or transaction was performed as part of the review.

The September 23 review reproduced no Critical, High, or Medium implementation vulnerability
exploitable without the assumed trusted authorities. It corrected three Low findings in operational
validation and analysis gates. That conclusion applies to the reviewed model and is not proof of
absence of vulnerabilities. Subsequent treasury, transfer-limit and immediate-bootstrap changes require external review.
Current test results and their exact limitations are in [VALIDATION.md](VALIDATION.md).
Original reports and intermediate evidence remain in [Git history](ARCHIVE_HISTORY.md).

## Findings and current disposition

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| IA-01 | Low | Configuration coercion accepted values invalid for Solidity configuration | Fixed with strict integer parsing, width checks, and regression tests |
| IA-02 | Low | Network preflight omitted code identity, pending authority, and metadata checks | Fixed within the tool's stated scope; proxy control, historical roles, and issuer eligibility require separate checks |
| IA-03 | Low | Static-analysis gate accepted all timestamp-category findings | Fixed with exact reviewed-finding matching and incomplete-output rejection |
| OBS-01 | Governance trust | Initial two-day delay is mutable and does not restart on a new emergency pause | Behavior reproduced; no permanent delay or guardian veto is enforced |
| OBS-02 | Conditional liveness | A remote receiving ceiling below a sent amount prevents delivery | Current ceilings can be increased through governance; prepare both receivers before increasing outgoing maxima |
| OBS-03 | External liveness | Guardian-set expiry can prevent completion of a pending message | Replacement-signature compatibility tested locally; live quorum availability is an external dependency |

## IA-01: strict configuration validation

The former parser used `int(value)`, accepting floats through truncation and values outside Solidity
widths. Mixed string/integer chain IDs could evade a direct equality check. These cases produced
false configuration approval rather than an on-chain authority bypass.

`tools/preflight.py` now requires strict decimal unsigned integers with explicit bit widths, rejects
booleans/floats/exponents/whitespace, and compares local/remote domains numerically. Boundary and
coercion regressions are in `tools/test_preflight.py`. Legacy cap and bucket fields are rejected;
current maxima must satisfy the configuration and receiving-ceiling rules.

## IA-02: network preflight boundaries

The earlier preflight compared only endpoint/Core runtime hashes and omitted pending endpoint
ownership, cancellation authority, and active metadata freshness. The updated inspection requires
approved timelock and asset/wrapped runtime hashes, rejects pending ownership transfers, checks
cancellation/self-admin authority and the closed-role policy, verifies wrapped origin/domain/decimals,
and requires fresh metadata in active phase. The original contract-only governance/guardian policy
was explicitly replaced by support for a shared hardware-wallet EOA. Timelock code identity and
ownership checks remain mandatory; the governance account cannot hold direct timelock admin rights.

RPC-fixture tests cover these checks, finalized-state requirements, block-hash changes, backing
deficits, and fee mismatches. They simulate RPC responses and do not establish live configuration.
Proxy runtime hashes do not identify implementations. Historical role holders, Safe signers/modules/
thresholds, queued operations, token authenticity, and issuer eligibility require deployment-specific
review. A malicious RPC remains outside the tool's trust model. The deployment policy uses closed
executors; rejecting an open executor does not imply that open execution is inherently an exploit.

## One-time initial setup boundary

The selected governance account can call `bootstrapSetPeer` and `activate` directly before initial
activation. This is an intentional exception to delayed governance, not a timelock administrator role.
Binding leaves both lanes paused. All successful unpauses consume the setup authority, including the
ordinary owner path and partial unpause. Ownership nomination closes it even if later cancelled.
There is no reopening function. Fee, limit, guardian and ownership changes remain owner-only.

Ten bootstrap regressions and five added mutation cases challenge authorization, irreversible closure,
partial-unpause closure, ownership-migration closure and the deployed authority. Preflight allows only
the selected bootstrapper or a closed authority while prepared; active/maintenance phases require zero.
Initial authority compromise can still bind the wrong peer before activation; operators must verify
both chains before enabling transfers. These are tested properties, not independent audit approval.

## IA-03: static-analysis acceptance

The former gate accepted every timestamp finding and could treat missing detector output as an
empty result. `tools/check_slither.py` now matches detector, severity, file, function, and flagged
expressions against `tools/slither-reviewed.json`, rejects incomplete output, and rejects all
High/Medium findings. Four timestamp findings remain reviewed in the current source; findings
from the removed bucket are no longer allowlisted. Regression tests reject changed expressions,
new locations, and invalid output. Unchanged fingerprints are not proof of safety in every context.

## OBS-01: governance guarantees

The standard TimelockController can schedule `updateDelay(0)` under its current delay, after which
subsequent operations may be immediate. Endpoint ownership can migrate through the two-step owner
procedure. An already-mature unpause can execute immediately after a new guardian pause because
it is not tied to a specific pause episode. `test/InternalAudit.t.sol` reproduces these behaviors;
none gives an arbitrary outsider governance authority.

The initial delay is at least 48 hours; there is no permanent floor or guaranteed waiting period
after every pause. The guardian can pause immediately but cannot cancel timelock operations.
Incident response requires the proposer/canceller account to inspect and cancel incompatible queued
unpauses. Under the selected shared-wallet policy, that account is also the emergency guardian. A permanent floor, fixed ownership topology, or pause-specific resumption policy would
require a separately reviewed design change. See [THREAT_MODEL.md](THREAT_MODEL.md) and
[OPERATIONS.md](OPERATIONS.md).

## OBS-02: paired receiving ceilings

An outgoing maximum greater than the remote receiving ceiling can allow a deposit to lock funds
and pay its fee while the authenticated remote completion fails. Waiting alone cannot change that
ceiling. Current governance can repair this mismatch by raising the incoming ceiling through the
timelock and retrying the original message. There is no unilateral refund, which would allow a
later mint against collateral already released.

Unlike the historical immutable-limit implementation, the current design provides
`prepareInboundMaxTransfer`. Prepare and verify both receiving ceilings before activating larger
outgoing maxima. The local contracts cannot enforce the order of remote governance execution.
Incoming ceilings never decrease, so lowering outgoing limits does not invalidate earlier claims.
See `test/TransferLimitGovernance.t.sol` and the paired preflight procedure.

## OBS-03: Guardian availability and recovery

The bridge imposes no transfer-message deadline, but Core can reject a VAA after its Guardian set
expires. `test/SignedVAA.t.sol` tests both pending mint and reserve release after rotation to four
different synthetic Guardian keys: old signatures fail, a valid new quorum signs the same body,
the original request completes, and replay cannot mint or pay twice.

The upstream verifier checks these locally generated signatures. This proves retry behavior, not
availability of a live quorum or a historical re-observation service. The Wormhole dependency has
been accepted as part of the product model; it is not an unconditional recovery guarantee.
Wormhole's [signature replacement procedure](https://wormhole.com/docs/products/messaging/tutorials/replace-signatures/)
must be rehearsed operationally. Without an accepted attestation, this implementation has no
independent refund or administrative recovery route. Issuer blocks or missing collateral can also
prevent release even with a valid attestation.

## Evidence and remaining review scope

Current local, fork, mutation, static-analysis, and coverage results are maintained in one place:
[VALIDATION.md](VALIDATION.md). The current source identity is in `audit/RELEASE_MANIFEST.json`;
`audit/current-review-snapshot.json` binds source and selected evidence from the last full run.
The internal review does not audit live Core governance, issuer solvency, or operating services.

Before audit scope freeze, document governance and recovery assumptions and the permitted
configuration. Before launch, resolve external audit findings, verify deployed bytecode/roles,
approve actual addresses and per-asset limits, check issuer eligibility, validate finalized RPC
access, and rehearse real-network round trips and incident recovery. A public Synthra deployment
is not a prerequisite for the external code audit. Current integration evidence and its unresolved
boundaries are in [INTEGRATION_REVIEW.md](INTEGRATION_REVIEW.md).

## Reproduction

```sh
bash tools/check.sh
python3 tools/mutation_check.py
python3 tools/verify_upstream.py  # public network reads only
python3 tools/package_audit.py
```

The mutation tool uses a disposable copy, not the production tree. Dependency byte comparison is
separate from a dependency security audit. Do not weaken assertions, analysis acceptance, or
risk disclosures merely to obtain passing results.
