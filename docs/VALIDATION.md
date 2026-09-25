# Validation evidence — 24 September 2026

> Version boundary: this document describes the earlier Wormhole implementation.
> The new LayerZero contracts and their separate validation are documented in
> [LAYERZERO.md](LAYERZERO.md) and [LAYERZERO_VALIDATION.md](LAYERZERO_VALIDATION.md).
> Previous audit results and deployment commands do not cover the new implementation.
> Current root test logs have been replaced by the combined regression run described in
> LAYERZERO_VALIDATION.md. Original logs supporting the historical counts below remain in the
> pre-LayerZero Git snapshot indexed in [ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).

Local toolchain: Foundry 1.5.1-stable (b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2),
Solidity 0.8.28 (7893614a), Slither 0.11.3, Python 3.14.6. EVM Paris, optimizer 200,
no CBOR/bytecode metadata. CI declares Foundry 1.5.1 and Python 3.11 but has not been run remotely.

`bash tools/check.sh` completed successfully for the immediate-bootstrap contract revision `fbd37ef`.
The subsequent free-RPC tooling update reran the Python suite; Solidity sources, deployment Solidity,
compiler settings and dependency inputs are unchanged, so their existing evidence is retained.
The reports below are packaged and hashed with the source snapshot; the independent audit remains outstanding.
The contract revision adds a one-time initial setup permission for the configured governance account.
Initial peer binding and activation have no timelock wait; the endpoint remains timelock-owned.
Every unpause, including partial and ordinary governance unpause, consumes the fast setup permission.
Ownership nomination also consumes it, and governance may close it explicitly without activating.
Later resumption and other administrative operations retain the ordinary timelocked path.

Full local checks, mutation testing, twenty pinned fork tests and twenty-four independent deployment
simulations were run for that contract revision. The deployment profile uses Cancun fork execution and Paris compilation;
creation bytecode and runtime templates match the default audit profile for this same revision.
The previous revision's deployment bundle and runtime hashes must not be reused for the new contracts.
These simulations do not replace finalized-state verification or live signed-VAA round trips.
See `SPECIFICATION.md` for current behavior, `OPERATIONS.md` for governance ordering, and
`INTEGRATION_REVIEW.md` for fork block pins.

| Check | Result | Evidence |
| --- | --- | --- |
| Solidity suite | 135 passed, 0 failed, 0 skipped | `audit/unit-tests.log` |
| Audit profile | 135 passed; 7 fuzz tests × 2,048 cases | `audit/audit-tests.log` |
| Stateful conservation | 512 runs × depth 128 = 65,536 handler calls; 0 unexpected reverts | `audit/audit-tests.log` |
| Pending-message drain | afterInvariant delivers outstanding messages and checks locked = supply | `test/BridgeInvariant.t.sol` |
| Native binary signed VAAs | 15 tests, including recovery with different Guardian keys in both directions | `test/SignedVAA.t.sol` |
| Fee behavior | 100 → 99.5 wrapped + immediate 0.5 treasury; failed fee/publication fully reverts | `test/Bridge.t.sol` |
| Treasury rotation / immediate pause | 7 tests: authority, timing, invalid recipients, backing, callback protection, rollback and emergency action | `test/TreasuryGovernance.t.sol` |
| Transfer maximum governance | 14 tests: authority, timing, active updates, incoming preparation, pending claims, raise/lower and reentrancy | `test/TransferLimitGovernance.t.sol` |
| No shared quota | 32 users and repeated round trips in one block; no refill or time advance | `test/Bridge.t.sol` |
| Monthly metadata | 12 tests at 30 days: early renewal, changed/scheduled values, cancellation, exact expiry, delayed delivery, replay, raw redemption, and constructor bounds; 8 existing metadata cases also run at one day | `test/Metadata.t.sol` |
| Asset expansion | 2 local tests: add a thirteenth pair; isolate messages and pauses | `test/AssetExpansion.t.sol` |
| Immediate bootstrap | 10 tests: correct authority on both sides, no initial wait, paused binding, no repeat activation, timelocked later resume, partial-unpause closure, ownership-migration closure, invalid input rollback and no unrelated admin powers | `test/Bootstrap.t.sol` |
| Deployment simulation | Both sides created paused and timelock-owned; shared EOA roles, immediate pause, delayed resume/treasury changes, zero-authority and short-delay rejection | `test/DeploymentConfig.t.sol`, `test/HardwareWalletGovernance.t.sol` |
| Operational-tool validation | 101 Python tests passed, including exact multiplier conversion, config tampering, shared RPC pacing, failure without fallback, cross-provider block agreement, read-only simulation and receipt/VAA/finality/signature-verification rejection cases | `audit/python-tests.log`, `tools/test_*.py` |
| Free public RPC workflow | NVDA finalized deploy preflight and simulation passed on both chains; Robinhood execution/finalized providers agree on the pinned block; no broadcast | `audit/network/free-rpc-validation.json` |
| Selected deployment preparation | 24/24 latest-state simulations passed; all 12 stocks on both chains; 7/7 artifact comparisons byte-identical to the default audit profile | `audit/deployment-preparation.json` |
| Real-network fork simulations | 20 passed on the current source; all 12 selected stocks, treasury rotation and issuer interference | `audit/live-fork-tests.log`, `docs/INTEGRATION_REVIEW.md` |
| Mutation sensitivity | All 32 compiling mutations detected, including outgoing/incoming maxima and receive-preparation authority, reentrancy and monotonicity, plus deployment owner, bootstrap admin, minimum delay and zero-authority guards | `audit/mutation-report.json` |
| Upstream provenance | Historical: 63 files byte-matched on 23 September; dependencies unchanged and local lock rechecked | `audit/dependency-verification.json` |
| Slither | 0 High/Medium, 4 reviewed Low timestamp findings | `audit/slither.json`, `docs/SECURITY_ANALYSIS.md` |
| Formatting / dependencies | Passed; 65 dependency files match lock | `tools/check.sh`, `vendor/SHA256SUMS.json` |
| Demo | Successful simulation; 9.95 minted, 4 redeemed, 5.95 remaining, 0.05 immediately paid | `audit/demo.log` |

## Coverage

These are instrumented Foundry coverage numbers, not a proof of correctness or absence of vulnerabilities.
Source-only total: 263/265 lines (99.25%), 55/55 functions (100%), 43/47 branches (91.49%).

| Contract | Lines | Functions | Branches |
| --- | --- | --- | --- |
| SourceVault | 54/55 | 7/7 | 9/11 |
| DestinationBridge | 23/24 | 5/5 | 2/4 |
| WormholeEndpoint | 122/122 | 26/26 | 25/25 |
| WrappedAsset | 64/64 | 17/17 | 7/7 |

Deployment script: 50/50 lines and 3/3 functions; 17/20 branches. Full file-by-file summary and
LCOV in `audit/coverage.log` and `audit/coverage.lcov`. Uncovered branches include invalid deployment/
configuration paths and redundant remote-token rejection; these remain visible for auditor review.

Production runtime sizes: SourceVault 11,650 bytes, DestinationBridge 9,234 bytes, WrappedAsset
4,455 bytes; all below EIP-170's 24,576-byte limit. Gas output is in `audit/gas-report.log` and
includes artificial mock overhead; it is not a gas-cost estimate for the live chains.

## What has not been established

- Twenty fork tests passed on 24 September against the current source with one-time immediate bootstrap and mutable transfer maxima.
  See `INTEGRATION_REVIEW.md` and `audit/live-fork-tests.log`.
  Real token balances were injected locally, and return-flow attestations were mocked. No public
  transaction was broadcast, and no Synthra live end-to-end transfer has been demonstrated.
- An actual Robinhood-origin Guardian-set-7 VAA was verified on both real Core implementations;
  it belongs to another emitter and uses consistency 202. Our intended level-0 policy and Arc-origin
  Guardian observation remain unproven by this evidence.
- All twelve selected stocks passed compatibility and issuer-interference scenarios. The preceding token identity
  snapshot showed a shared implementation; identities were not recollected at the new fork pins. Deployed escrow/treasury
  eligibility and issuer role governance require deployment-specific verification. Operator addresses and the
  USD reference policy are now supplied; exact raw amounts/configurations are prepared privately.
- Production pair preflight/relay execution still needs deployed endpoints and approved real configs.
  Robinhood's public RPC returned no historical state for the finalized block; latest reads are
  separately labeled and do not satisfy that gate.
- Independent review, issuer/distribution review, user-facing VAA retrieval/completion and pending-
  transfer recovery and reconciliation/monitoring remain outstanding at this historical checkpoint.
  No automatic relayer is planned; users submit both bridge transactions. This does not remove the
  requirement to publish and deliver metadata updates or recover interrupted user sessions.

Foundry emits non-blocking debug-source-parser warnings during the demo for certain test/vendor
files. Compilation, script assertions, emitted logs and final exit code confirm successful execution.
One intentional Slither suppression ignores only the unused human-readable Core diagnostic string;
validity is checked explicitly. Disposition is documented, not represented as a detector-free audit.

## Current source and package identity

`audit/current-review-snapshot.json` records the source, configuration, and evidence hashes for
this revision. Full local checks, 32 mutations, twenty fork tests and twenty-four independent deployment
simulations were rerun for one-time immediate setup. Contract runtime hashes and deployment bundles
changed; old artifacts cannot identify the new endpoints. Test/fork fixtures were updated for the
constructor configuration field. Wrapped token behavior, message format and transfer accounting are
unchanged. The current package is identified by `audit/RELEASE_MANIFEST.json` and `audit/SHA256SUMS`;
superseded evidence is linked in [ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).
