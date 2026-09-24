# Validation evidence — 24 September 2026

Local toolchain: Foundry 1.5.1-stable (b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2),
Solidity 0.8.28 (7893614a), Slither 0.11.3, Python 3.14.6. EVM Paris, optimizer 200,
no CBOR/bytecode metadata. CI declares Foundry 1.5.1 and Python 3.11 but has not been run remotely.

`bash tools/check.sh` completed successfully for this source candidate. The reports below are
packaged and hashed with the source snapshot; the independent audit remains outstanding.
The latest revision removes the shared token bucket and the mandatory pause for maximum changes.
Full checks were rerun against this revision. The upstream comparison remains explicitly historical.
See `SPECIFICATION.md` for current behavior, `OPERATIONS.md` for governance ordering, and
`INTEGRATION_REVIEW.md` for fork block pins.

| Check | Result | Evidence |
| --- | --- | --- |
| Solidity suite | 109 passed, 0 failed, 0 skipped | `audit/unit-tests.log` |
| Audit profile | 109 passed; 7 fuzz tests × 2,048 cases | `audit/audit-tests.log` |
| Stateful conservation | 512 runs × depth 128 = 65,536 handler calls; 0 unexpected reverts | `audit/audit-tests.log` |
| Pending-message drain | afterInvariant delivers outstanding messages and checks locked = supply | `test/BridgeInvariant.t.sol` |
| Native binary signed VAAs | 15 tests, including recovery with different Guardian keys in both directions | `test/SignedVAA.t.sol` |
| Fee behavior | 100 → 99.5 wrapped + immediate 0.5 treasury; failed fee/publication fully reverts | `test/Bridge.t.sol` |
| Treasury rotation / immediate pause | 7 tests: authority, timing, invalid recipients, backing, callback protection, rollback and emergency action | `test/TreasuryGovernance.t.sol` |
| Transfer maximum governance | 14 tests: authority, timing, active updates, incoming preparation, pending claims, raise/lower and reentrancy | `test/TransferLimitGovernance.t.sol` |
| No shared quota | 32 users and repeated round trips in one block; no refill or time advance | `test/Bridge.t.sol` |
| Asset expansion | 2 local tests: add a thirteenth pair; isolate messages and pauses | `test/AssetExpansion.t.sol` |
| Deployment simulation | Both sides created paused and owned by newly created timelock; placeholders rejected | `test/DeploymentConfig.t.sol` |
| Operational-tool validation | 60 Python tests passed, including limit updates, historical ceilings and maintenance preflight | `audit/python-tests.log`, `tools/test_*.py` |
| Real-network fork simulations | 19 passed on 24 September; all 12 selected stocks, treasury rotation and issuer interference | `audit/live-fork-tests.log`, `docs/INTEGRATION_REVIEW.md` |
| Mutation sensitivity | All 23 compiling mutations detected, including outgoing/incoming maxima and receive-preparation authority, reentrancy and monotonicity | `audit/mutation-report.json` |
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

Deployment script: 50/50 lines and 3/3 functions; 16/22 branches. Full file-by-file summary and
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
  eligibility, issuer role governance, production risk values and operator addresses remain unresolved.
- Production pair preflight/relay execution still needs deployed endpoints and approved real configs.
  Robinhood's public RPC returned no historical state for the finalized block; latest reads are
  separately labeled and do not satisfy that gate.
- Independent review, issuer/distribution review, hosted relayer, durable indexer/reconciliation,
  frontend and liquidity integration remain outstanding.

Foundry emits non-blocking debug-source-parser warnings during the demo for certain test/vendor
files. Compilation, script assertions, emitted logs and final exit code confirm successful execution.
One intentional Slither suppression ignores only the unused human-readable Core diagnostic string;
validity is checked explicitly. Disposition is documented, not represented as a detector-free audit.

## Documentation and package maintenance

The English documentation cleanup changed no contracts, deployment scripts, tests, configuration
examples, dependencies, or security-validation logic. The packaging allowlist was updated to omit
superseded notes and intermediate evidence. Test counts above describe the existing source runs,
not a new execution performed for translation. The source and evidence hashes in
`audit/no-rate-limit-review-snapshot.json` still identify those runs; the release manifest and archive
checksum are regenerated for the current documentation. Original historical artifacts are indexed
in [ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).
