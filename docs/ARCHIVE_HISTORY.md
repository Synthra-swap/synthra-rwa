# Historical evidence

Generated archives, manifests and logs are no longer versioned. The references below identify
historical checkpoints; retrieve historical binaries from the corresponding Git revision or preserved
local evidence. Regenerate new handoff artifacts with `tools/package_audit.py`.

The current documentation describes the current source. Superseded design notes, intermediate test
logs, and duplicate archives have been removed from the working tree. Their original bytes remain
in the pinned Git commit below; history has not been rewritten. Some historical documents are in
Italian. Current documentation and the current audit package are in English.

Use [LAYERZERO_VALIDATION.md](LAYERZERO_VALIDATION.md) for current results, `audit/RELEASE_MANIFEST.json` for the current
package contents, and `audit/SHA256SUMS` for its checksum. Historical counts and source hashes
must not be treated as validation of a later revision.

## Previous archives

The last package before the LayerZero internal review is preserved in
[commit `6fed369`](https://github.com/Synthra-swap/synthra-rwa/tree/6fed3690c06b7e32e968e13c615e7f287091f87e).
Its [audit archive](https://github.com/Synthra-swap/synthra-rwa/blob/6fed3690c06b7e32e968e13c615e7f287091f87e/audit/synthra-rwa-bridge-audit.tar.gz)
has SHA-256 `2bfc92726541423fe8ebdd83820ca6ced2ba8a3bfa92664e047194779295e0b9`.
The new package includes separate LayerZero mutation/ABI evidence and combined regression logs.

| Archive | SHA-256 |
| --- | --- |
| [baseline-20260923.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/baseline-20260923.tar.gz) | `1cb14ba96e6717186201c226980b4fea8c7a00c740c0428a5c694b7c1027527c` |
| [baseline-before-mutable-transfer-limit-20260924.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/baseline-before-mutable-transfer-limit-20260924.tar.gz) | `4645e24a606295be9d2e3bf30c3709b29e02743d07805f46f13f446bfdbc1cad` |
| [baseline-before-rate-removal-20260924.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/baseline-before-rate-removal-20260924.tar.gz) | `c07531620a448f076dfdd5a311417b489cad83bad509cea23368c9b73dd6507c` |
| [baseline-before-total-cap-removal-20260924.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/baseline-before-total-cap-removal-20260924.tar.gz) | `411a1ac8f2e662cd483fdfb775ce28f7507f6b74d1d68769aa30b594a1c4e7d2` |
| [baseline-pre-treasury-20260923.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/baseline-pre-treasury-20260923.tar.gz) | `d73adc2b2c1b0c596aec41cc7edbb0ff5035d3a282db30aac28e404c530d0ed0` |
| [Package before English documentation and cleanup](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/synthra-rwa-bridge-audit.tar.gz) | `f8d8d5f976730e505a9dde0b846876140d06bbbe574d9275e96780bd86b3160c` |

## Superseded notes and intermediate evidence

All removed files are available in [commit `25a83a9`](https://github.com/Synthra-swap/synthra-rwa/tree/25a83a974a72aeae0d87989cf1dbb0af8286ba2c).

- [docs/TOTAL_CAP_REMOVAL.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/docs/TOTAL_CAP_REMOVAL.md)
- [docs/TRANSFER_LIMIT_GOVERNANCE.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/docs/TRANSFER_LIMIT_GOVERNANCE.md)
- [docs/TREASURY_CHANGE.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/docs/TREASURY_CHANGE.md)
- [docs/TWELVE_ASSET_VALIDATION.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/docs/TWELVE_ASSET_VALIDATION.md)
- [docs/NO_RATE_LIMIT.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/docs/NO_RATE_LIMIT.md)
- [audit/READINESS_REVIEW_2026-09-23.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/READINESS_REVIEW_2026-09-23.md)
- [audit/readiness-review/PRODUCT_DECISIONS.md](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/PRODUCT_DECISIONS.md)
- [audit/internal-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/internal-review-snapshot.json)
- [audit/treasury-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/treasury-review-snapshot.json)
- [audit/twelve-asset-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/twelve-asset-review-snapshot.json)
- [audit/no-total-cap-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/no-total-cap-review-snapshot.json)
- [audit/mutable-transfer-limit-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/mutable-transfer-limit-review-snapshot.json)
- [audit/readiness-review/forge-audit.log](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/forge-audit.log)
- [audit/readiness-review/forge-audit-expanded.log](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/forge-audit-expanded.log)
- [audit/readiness-review/forge-audit-assets.log](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/forge-audit-assets.log)
- [audit/readiness-review/no-total-cap-fork-pins.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/no-total-cap-fork-pins.json)
- [audit/readiness-review/mutable-transfer-limit-fork-pins.json](https://github.com/Synthra-swap/synthra-rwa/blob/25a83a974a72aeae0d87989cf1dbb0af8286ba2c/audit/readiness-review/mutable-transfer-limit-fork-pins.json)

The current source/evidence snapshot retains its original baseline archive hash. That baseline is
listed above; removing a duplicate local copy does not change the historical hash. Dependency,
registry, code-identity, and network observations remain in the current package where they support
explicitly dated claims. Their inclusion does not imply that those checks were rerun.

## Pre-monthly-metadata checkpoint

The 30-day metadata change supersedes the previous source/evidence snapshot. The earlier
English package, source hashes, and fork pins remain available without changing their original bytes:

- [audit/synthra-rwa-bridge-audit.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/e38335d40bd2f5e8d2a2df37d49d4514e9eaf180/audit/synthra-rwa-bridge-audit.tar.gz), SHA-256 `0aadee574507ad045920ad4ddb9f4a17d89f3e861a13172191c38e08b1ee7b82`.
- [audit/no-rate-limit-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/e38335d40bd2f5e8d2a2df37d49d4514e9eaf180/audit/no-rate-limit-review-snapshot.json), SHA-256 `a3a2616e98cb8be95aeae30743b3b53da3bed24feda3e9aa21fc6ce726bfe9fd`.
- [audit/readiness-review/no-rate-limit-fork-pins.json](https://github.com/Synthra-swap/synthra-rwa/blob/e38335d40bd2f5e8d2a2df37d49d4514e9eaf180/audit/readiness-review/no-rate-limit-fork-pins.json), SHA-256 `a7cf05522ddcb462e037ce9f3c2aa5adcf0a68ab482a9bdf827fc0a337aae964`.

## Before shared hardware-wallet governance

The preceding package and evidence record the contract-only, separate-account deployment policy.
Their original identities remain available in Git history:

- [audit/synthra-rwa-bridge-audit.tar.gz](https://github.com/Synthra-swap/synthra-rwa/blob/8ff05bf0d33cde331369ef8d95f549a628756617/audit/synthra-rwa-bridge-audit.tar.gz), SHA-256 `816c5b5f4e7db18012c887d753449fd4565bbcc87a609fe6c0634c266cfa340e`.
- [audit/current-review-snapshot.json](https://github.com/Synthra-swap/synthra-rwa/blob/8ff05bf0d33cde331369ef8d95f549a628756617/audit/current-review-snapshot.json), SHA-256 `1f85c4e5da0fb173d1eb42b650b5d6885ff5555282536a108a2e2c13c4315e82`.

## Before deployment-bundle preparation

The shared-wallet candidate, before the per-asset helpers and separate deployment execution profile,
remains available at [commit `aceccd7`](https://github.com/Synthra-swap/synthra-rwa/tree/aceccd785b9e0c96eeff857b63967c305f257ae9).
Its [audit archive](https://github.com/Synthra-swap/synthra-rwa/blob/aceccd785b9e0c96eeff857b63967c305f257ae9/audit/synthra-rwa-bridge-audit.tar.gz)
has SHA-256 `a5b36989fdb47921eba56b0ed1b9fafc2376ba5462849a0ce5ee08ab0917df16`.

## Before one-time immediate setup

The deployment-bundle candidate before changes to endpoint bootstrap authority is preserved at
[commit `da9e00c`](https://github.com/Synthra-swap/synthra-rwa/tree/da9e00c).
Its [audit archive](https://github.com/Synthra-swap/synthra-rwa/blob/da9e00c/audit/synthra-rwa-bridge-audit.tar.gz)
has SHA-256 `f0e5502a0be8551f0a5da772a9076ae840bb94ac5547810eaf5b2716ae770f92`.

## Before free-RPC deployment support

The immediate-bootstrap contract revision before optional finalized providers and shared request pacing
is preserved at [commit `fbd37ef`](https://github.com/Synthra-swap/synthra-rwa/tree/fbd37ef4f740a248863ba04957088db91f559cf9).
Its [audit archive](https://github.com/Synthra-swap/synthra-rwa/blob/fbd37ef4f740a248863ba04957088db91f559cf9/audit/synthra-rwa-bridge-audit.tar.gz)
has SHA-256 `4258f0c7d854cda4d0b2ae0f73166823de5d7bce21a9088ea7d1e053e2f6fa6a`.
The free-RPC change affects operational Python tooling, not deployed Solidity or asset parameters.

## Before manual pilot VAA retrieval

The free-RPC tooling snapshot is preserved at
[commit `6370d7f`](https://github.com/Synthra-swap/synthra-rwa/tree/6370d7f).
Its [audit archive](https://github.com/Synthra-swap/synthra-rwa/blob/6370d7f/audit/synthra-rwa-bridge-audit.tar.gz)
has SHA-256 `0a856851c13395e1aa19300f0dad973767815a2df6eea7ac641928f54b11984c`.
The manual pilot helper changes no deployed contract or deployment configuration.
