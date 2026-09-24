# Treasury rotation — 24 September 2026

**Treasury change checkpoint.** The subsequent removal of aggregate reserve/supply caps and current
validation are documented in `TOTAL_CAP_REMOVAL.md`. Earlier retained-cap statements describe
the preceding revision, not the current source.

The source vault now permits governance to change the recipient of future deposit fees. This is an
explicit user-requested change to production source after the 23 September audit baseline; the old
source hashes, coverage and statements of immutable treasury do not describe this revision.

## Behavior and authority

`SourceVault.setFeeRecipient(next)` is owner-only and non-reentrant. The deployment script makes the
timelock the owner, with an initial delay of at least 48 hours. Ordinary depositors, the treasury and
the emergency guardian have no authority to call it. Governance must schedule and execute the call.
Existing governance caveats still apply: the standard timelock's delay can be reduced, endpoint
ownership can migrate, and an already-ready unpause is not invalidated by a new pause. Permanent
restrictions on those powers have not been silently added by this change.

The next recipient cannot be zero, the source vault, or the original token. The function emits
`FeeRecipientChanged(previous,next)` and may be called while lanes are paused. It does not require
the new recipient to accept: the operator must verify address control and issuer transfer eligibility.

Only subsequent deposits pay the new treasury. Previously paid fees remain at earlier recipients;
pending deposits/redemptions and backing are unchanged. The fee remains the constant 50 basis points.
No reserve withdrawal, admin mint, admin burn or transfer of existing fees is introduced.

The non-reentrancy check prevents even an authorized owner callback from changing the recipient
partway through a guarded token transfer. If the new recipient is blocked by the issuer, a deposit
reverts atomically. Governance can rotate to a compatible recipient without redeploying the bridge.

## Immediate actions versus delayed actions

| Action | Timing under the deployment configuration |
| --- | --- |
| Emergency guardian pauses either/both lanes | Immediately, once its transaction is included; no timelock |
| Governance cancels a queued operation | Immediately through its canceller role |
| Governance resumes a lane | Timelock execution; see already-ready-operation caveat above |
| Change treasury or emergency guardian | Timelock execution |
| Initial peer binding, ownership migration, timelock role/delay administration | Existing governance procedure; initial delay >=48 hours |

The immediate guardian is a separate configured contract from the governance Safe. Its own signing
procedure must not route an emergency pause through the timelock. Onchain immediacy does not remove
multisig signing latency, transaction inclusion latency, or the possibility of an exploit completing
before the pause is included. No administrative waiting period is imposed on ordinary user deposits,
redemptions or message relay.

## Regression coverage

`test/TreasuryGovernance.t.sol` exercises unauthorized callers, invalid recipients, the rotation event,
old and new fee payments, pending-message completion, exact reserve conservation and redemption,
blocked-recipient rollback/recovery, timelock enforcement, owner-callback reentrancy and an immediate
guardian pause with a timelock-owned endpoint.

Python preflight tests verify rejection of an unexpected recipient and acceptance after the reviewed
operational configuration is updated. The runtime hash stays constant across treasury rotations;
the storage getter remains explicitly checked against the operator's expected address.

Mutation testing now also removes treasury access control and the treasury reentrancy guard, so the
suite must fail for either missing protection. Results are recorded in the current validation logs.

The earlier proposal to remove amount caps/limits was superseded on 24 September: the user accepts
retaining them as additional safety controls, and they remain in place. Production limit values must
still be selected explicitly. Twelve stock candidates and expansion tests are documented in
`audit/readiness-review/PRODUCT_DECISIONS.md`; the expanded real-token fork results are tracked
in `docs/TWELVE_ASSET_VALIDATION.md` (19 passed on the current source). No public deployment
or transaction has occurred.
