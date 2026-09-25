# Internal review and static analysis

> Version boundary: this document describes the earlier Wormhole implementation.
> The new LayerZero contracts and their separate validation are documented in
> [LAYERZERO.md](LAYERZERO.md) and [LAYERZERO_VALIDATION.md](LAYERZERO_VALIDATION.md).
> Previous audit results and deployment commands do not cover the new implementation.

This file is an engineering review log, not an independent audit opinion.

## Slither dispositions

All production source contracts are analyzed with Slither 0.11.3. Test/script/vendor locations are
filtered from findings; upstream dependencies remain an explicitly identified audit assumption.
`audit/slither.json` and `audit/slither.log` preserve the latest result. The release check fails on
any High/Medium result or any unreviewed detector category.

| Detector | Disposition |
| --- | --- |
| unused-return at Core verification | Optional human-readable reason string intentionally discarded; `valid` checked immediately and VM decoded only after it. One line-local suppression, explained in source. Initial unsuppressed result reviewed; no global detector suppression. |
| missing-inheritance | Resolved: WrappedAsset explicitly implements the scaled-UI interfaces and ERC165. |
| timestamp: SourceVault publishMetadata | Expected: determines whether the source's scheduled multiplier is already effective. Raw amounts are unaffected. |
| timestamp: WrappedAsset snapshot application/freshness/effectiveness | Expected: scheduled corporate actions and stale-data bounds require timestamps. Five-minute future skew allowance is explicit; tested expiration and scheduled transitions. |

Low timestamp findings are accepted for this candidate, not proof of validator clock correctness.
`tools/check_slither.py` now matches detector, severity, file, function and exact flagged expressions
against `tools/slither-reviewed.json`. A new timestamp finding or changed expression fails review;
missing/incomplete analyzer output also fails closed. A high/medium finding cannot be allowlisted.

The adversarial internal review, remediations and executable residual-risk demonstrations are in
`INTERNAL_AUDIT.md`. The mutation campaign challenges whether tests detect removed security rules;
it does not prove coverage of all possible defects.

## Internal design review notes

- Keep fees outside backing; transfer fee and publish message within a single reverting transaction.
- Never refund solely because a relay is slow: pending mint remains possible.
- Bind action, source and destination EVM domains, Wormhole ID, peer, asset and recipient; consume
  emitter sequence rather than VAA signature bytes/hash alone.
- Preserve exits when pausing admissions, but provide a separate incoming circuit breaker for incidents.
- Do not rebase pool balances on a corporate action. Raw unit conservation is independent of display.
- No aggregate cap or throughput bucket remains. Per-message bounds do not restrict total flow;
  conservation and pending-claim accounting remain enforced independently of cumulative volume.
- A failed token/fee transfer must roll back message consumption and accounting for a later retry.
- Validate source balance plus exact recipient deltas to reject unsupported transfer fees and seizures.
- Prepare incoming ceilings on both chains before increasing outgoing maxima through the timelock.
  Keep receive ceilings nondecreasing for older claims; changes need no routine pause.
- Disable ownership renunciation; document censorship/liveness powers.

## Questions for external reviewers

Review exact ABI compatibility with the selected deployed Core version, token-specific transfer
semantics, metadata schedule/cancellation behavior and freshness choice, source/destination clock
skew, timelock/guardian operational security, fee disclosure, and any integrating DEX's unit handling.
Verify the one-time remote token binding and preflight cross-check: known endpoint/token recipients
are rejected before deposit, while arbitrary inaccessible user-selected contracts remain a user risk.
