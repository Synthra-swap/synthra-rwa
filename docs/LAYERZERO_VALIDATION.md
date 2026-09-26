# LayerZero validation

## Scope and deployed release

This branch contains the LayerZero implementation, its shared issuer interface, tests and deployment
operations. The Solidity source of the deployed LayerZero contracts is unchanged by the repository
cleanup. Earlier implementation files and mixed-scope reports are available in
[the archive](ARCHIVE_HISTORY.md); their test counts are not the current suite's counts.

All twelve mainnet pairs were verified active with initial metadata received on September 25, 2026.
See [the registry](../config/layerzero.mainnet.json) for exact identities and transactions. All 60
Synthra contracts have explorer-verified source. Source verification is not a security audit.
The external audit is in progress. The user reported a successful NVDA asset trial; an independently
reconciled round-trip report remains a separate part of the audit handoff.

## Cleanup validation — September 26, 2026

| Check | Result |
| --- | --- |
| Solidity default profile | 62 passed |
| Solidity audit profile | 62 passed; 2,048 runs per fuzz test |
| Stateful solvency invariant | 512 runs, depth 128, zero handler reverts |
| Python operational tests | 44 passed |
| Local mainnet-fork integration | 14 passed, covering all 12 stocks |
| Targeted LayerZero mutations | 67/67 detected; no survivors or compile errors |
| Static analysis | No High/Medium findings; 9 specifically reviewed Low findings |
| Vendored integrity | 58 files; retained package sources rechecked against pinned upstream archives |
| Coverage | 100% branches/functions across the four bridge contracts; Endpoint lines 98.60%, others 100% |
| Deployed Solidity and deployment script | Byte-for-byte unchanged from archived commit `90fe6b5` |

## Reproducing checks

```sh
bash tools/check.sh
python3 tools/layerzero_mutation_check.py
bash tools/check_live.sh
python3 tools/verify_layerzero_abi.py
python3 tools/package_audit.py
```

`check.sh` verifies vendored dependency checksums, Python operational tests, Solidity formatting,
default and audit-profile unit/fuzz/invariant tests, coverage, gas reporting and static analysis.
The audit profile uses 2,048 runs per fuzz test and 512 invariant runs with depth 128.
`tools/slither-reviewed.json` permits only exact reviewed Low finding fingerprints. High/Medium
findings and unreviewed locations or expressions fail the gate.

Current generated reports are `audit/python-tests.log`, `audit/unit-tests.log`, `audit/audit-tests.log`,
`audit/coverage.log`, `audit/coverage.lcov`, `audit/gas-report.log`, `audit/slither.json` and
`audit/live-fork-tests.log`. The complete local check output is copied to `audit/layerzero/check.log`.
`audit/layerzero/validation.json` records completed checks and input hashes when all required reports
are available; `tools/record_layerzero_validation.py` rejects stale mutation and interface evidence.
Check the report's date and hashes against the revision under review.

The finite mutation campaign deliberately removes or corrupts 67 selected authentication,
accounting, governance, metadata and checkpoint protections in a temporary copy. Each mutation
must compile and cause a test failure. Compile failures, stale anchors or surviving mutations
fail the gate. This measures sensitivity to those mutations, not completeness against all defects.

`integration/LayerZeroLive.t.sol` exercises all twelve original stock contracts and live
Endpoint/ULN bytecode on local chain forks. It includes deposit, metadata, redemption, missing-DVN,
insufficient-confirmation, tampered-payload and replay cases. Balances and both DVN attestations
are injected only in fork state; these tests never submit transactions to mainnet and cannot prove
real verifier availability or real-user delivery time.

The local LayerZero ABI subset was compared against pinned LayerZero-v2 commit
`9c741e7f9790639537b1710a203bcdfd73b0b9ac`. ABI equivalence does not establish runtime identity or
protocol security. Network and source-asset research files retain their observation dates; packaging
them does not mean a historical network observation was rerun.

## Static-analysis review

- Four Low timestamp findings concern scheduled UI multipliers and metadata age. They do not
  authorize minting, redemption or raw-balance changes. Authenticated source timestamps are bounded
  by the clock-skew check and cannot restart the snapshot lifetime on delivery.
- The Low `reentrancy-events` finding in `LayerZeroEndpoint._send` concerns `MessageSent` after
  `endpoint.send`. The event uses that call's GUID and nonce; the deposit, redemption and metadata
  entry points are protected by `nonReentrant` and covered by callback regression tests.
- Four Low `calls-loop` findings concern protocol reads/commits in `_commitVerifications` from its
  two public entry paths. Protocol addresses are pinned. Callers can split work across transactions;
  checkpointing advances verified backlogs without executing blocked asset transfers.

These acceptances are internal review decisions, not an external auditor's approval. Coverage and
successful fuzzing are not correctness proofs. Issuer behavior, RPC reliability, chain finality,
verifier honesty/liveness and user key security remain external assumptions.

## Handoff

Generate a new archive for the exact reviewed commit. `audit/RELEASE_MANIFEST.json` identifies the
included file hashes and `audit/SHA256SUMS` identifies the archive; neither is an audit certificate.
CI publishes generated evidence as artifacts. The independent audit, findings resolution and
review of real asset round-trip evidence remain separate from local test results.
