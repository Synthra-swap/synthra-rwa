# Validation evidence — 24 September 2026

Local toolchain: Foundry 1.5.1-stable (b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2),
Solidity 0.8.28 (7893614a), Slither 0.11.3, Python 3.14.6. EVM Paris, optimizer 200,
no CBOR/bytecode metadata. CI declares Foundry 1.5.1 and Python 3.11 but has not been run remotely.

`bash tools/check.sh` completed successfully for this source candidate. The reports below are
packaged and hashed with the source snapshot; the independent audit remains outstanding.
The latest revision allows a shared hardware-wallet EOA as governance account and emergency guardian
in deployment and preflight. Endpoints remain timelock-owned with an initial delay of at least 48 hours.
Production `src/` contracts, monthly metadata policy, message format, and transfer accounting are
unchanged. Full local checks were rerun; upstream comparison and the preceding fork run remain
explicitly dated evidence, not new executions for this deployment-policy change.
See `SPECIFICATION.md` for current behavior, `OPERATIONS.md` for governance ordering, and
`INTEGRATION_REVIEW.md` for fork block pins.

| Check | Result | Evidence |
| --- | --- | --- |
| Solidity suite | 125 passed, 0 failed, 0 skipped | `audit/unit-tests.log` |
| Audit profile | 125 passed; 7 fuzz tests × 2,048 cases | `audit/audit-tests.log` |
| Stateful conservation | 512 runs × depth 128 = 65,536 handler calls; 0 unexpected reverts | `audit/audit-tests.log` |
| Pending-message drain | afterInvariant delivers outstanding messages and checks locked = supply | `test/BridgeInvariant.t.sol` |
| Native binary signed VAAs | 15 tests, including recovery with different Guardian keys in both directions | `test/SignedVAA.t.sol` |
| Fee behavior | 100 → 99.5 wrapped + immediate 0.5 treasury; failed fee/publication fully reverts | `test/Bridge.t.sol` |
| Treasury rotation / immediate pause | 7 tests: authority, timing, invalid recipients, backing, callback protection, rollback and emergency action | `test/TreasuryGovernance.t.sol` |
| Transfer maximum governance | 14 tests: authority, timing, active updates, incoming preparation, pending claims, raise/lower and reentrancy | `test/TransferLimitGovernance.t.sol` |
| No shared quota | 32 users and repeated round trips in one block; no refill or time advance | `test/Bridge.t.sol` |
| Monthly metadata | 12 tests at 30 days: early renewal, changed/scheduled values, cancellation, exact expiry, delayed delivery, replay, raw redemption, and constructor bounds; 8 existing metadata cases also run at one day | `test/Metadata.t.sol` |
| Asset expansion | 2 local tests: add a thirteenth pair; isolate messages and pauses | `test/AssetExpansion.t.sol` |
| Deployment simulation | Both sides created paused and timelock-owned; shared EOA roles, immediate pause, delayed resume/treasury changes, zero-authority and short-delay rejection | `test/DeploymentConfig.t.sol`, `test/HardwareWalletGovernance.t.sol` |
| Operational-tool validation | 67 Python tests passed, including limit updates, historical ceilings and maintenance preflight | `audit/python-tests.log`, `tools/test_*.py` |
| Real-network fork simulations | 19 passed on the preceding unchanged production source; all 12 selected stocks, treasury rotation and issuer interference | `audit/live-fork-tests.log`, `docs/INTEGRATION_REVIEW.md` |
| Mutation sensitivity | All 27 compiling mutations detected, including outgoing/incoming maxima and receive-preparation authority, reentrancy and monotonicity, plus deployment owner, bootstrap admin, minimum delay and zero-authority guards | `audit/mutation-report.json` |
| Upstream provenance | Historical: 63 files byte-matched on 23 September; dependencies unchanged and local lock rechecked | `audit/dependency-verification.json` |
| Slither | 0 High/Medium, 4 reviewed Low timestamp findings | `audit/slither.json`, `docs/SECURITY_ANALYSIS.md` |
| Formatting / dependencies | Passed; 65 dependency files match lock | `tools/check.sh`, `vendor/SHA256SUMS.json` |
| Demo | Successful simulation; 9.95 minted, 4 redeemed, 5.95 remaining, 0.05 immediately paid | `audit/demo.log` |

## Coverage

These are instrumented Foundry coverage numbers, not a proof of correctness or absence of vulnerabilities.
Source-only total: 239/241 lines (99.17%), 47/47 functions (100%), 39/45 branches (86.67%).

| Contract | Lines | Functions | Branches |
| --- | --- | --- | --- |
| SourceVault | 54/55 | 7/7 | 9/11 |
| DestinationBridge | 23/24 | 5/5 | 1/4 |
| WormholeEndpoint | 98/98 | 18/18 | 22/23 |
| WrappedAsset | 64/64 | 17/17 | 7/7 |

Deployment script: 49/49 lines and 3/3 functions; 17/20 branches. Full file-by-file summary and
LCOV in `audit/coverage.log` and `audit/coverage.lcov`. Uncovered branches include invalid deployment/
configuration paths and redundant remote-token rejection; these remain visible for auditor review.

Production runtime sizes: SourceVault 11,252 bytes, DestinationBridge 8,836 bytes, WrappedAsset
4,455 bytes; all below EIP-170's 24,576-byte limit. Gas output is in `audit/gas-report.log` and
includes artificial mock overhead; it is not a gas-cost estimate for the live chains.

## What has not been established

- Nineteen fork tests passed on 24 September against the current source with mutable transfer maxima.
  See `INTEGRATION_REVIEW.md` and `audit/live-fork-tests.log`.
  Real token balances were injected locally, and return-flow attestations were mocked. No public
  transaction was broadcast, and no Synthra live end-to-end transfer has been demonstrated.
- An actual Robinhood-origin Guardian-set-7 VAA was verified on both real Core implementations;
  it belongs to another emitter and uses consistency 202. Our intended level-0 policy and Arc-origin
  Guardian observation remain unproven by this evidence.
- All twelve selected stocks passed compatibility and issuer-interference scenarios. The preceding token identity
  snapshot showed a shared implementation; identities were not recollected at the new fork pins. Deployed escrow/treasury
  eligibility, issuer role governance, production risk values and remaining operator addresses remain unresolved.
- Production pair preflight/relay execution still needs deployed endpoints and approved real configs.
  Robinhood's public RPC returned no historical state for the finalized block; latest reads are
  separately labeled and do not satisfy that gate.
- Independent review, issuer/distribution review, user-facing VAA retrieval/completion and pending-
  transfer recovery, reconciliation/monitoring, frontend and liquidity integration remain outstanding.
  No automatic relayer is planned; users submit both bridge transactions. This does not remove the
  requirement to publish and deliver metadata updates or recover interrupted user sessions.

Foundry emits non-blocking debug-source-parser warnings during the demo for certain test/vendor
files. Compilation, script assertions, emitted logs and final exit code confirm successful execution.
One intentional Slither suppression ignores only the unused human-readable Core diagnostic string;
validity is checked explicitly. Disposition is documented, not represented as a detector-free audit.

## Current source and package identity

`audit/current-review-snapshot.json` records the source, configuration, and evidence hashes for
this revision. Full local checks and mutation testing were rerun for the shared hardware-wallet
policy. The twelve-stock fork evidence is retained from the monthly metadata revision: production
contracts, integration test source, and fixture hashes are unchanged. It does not exercise the new
deployment governance policy; local deployment and adversarial RPC tests cover that policy.
Example deployment parsing still verifies the 30-day value.

The Solidity production source and runtime sizes above remain unchanged; deployment script and
preflight behavior differ from the previous candidate. Earlier manifests and test counts must not
be reused as the identity of this revision. The current package is identified by
`audit/RELEASE_MANIFEST.json` and `audit/SHA256SUMS`; superseded evidence is linked in
[ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).
