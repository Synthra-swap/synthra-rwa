# Archived implementation

The source tree on `main` contains the LayerZero asset bridge, its tests, deployment tooling and
required dependencies. The earlier Wormhole implementation, recovery tools and historical reports
are preserved in [https://github.com/Synthra-swap/synthra-rwa/tree/archive/wormhole-20260926](https://github.com/Synthra-swap/synthra-rwa/tree/archive/wormhole-20260926), pinned at commit
`90fe6b54bd43f67fe4b477d5c84c61648f37462c`.

This cleanup does not redeploy contracts, migrate balances, release reserves or settle old claims.
Any recovery for an earlier deployment must use its original implementation and addresses from the
archive. Git history is retained; no force push or history rewrite is involved.

Mixed-implementation validation counts and hashes belong to the archive. Current generated reports
are produced by `tools/check.sh`, `tools/check_live.sh` and `tools/layerzero_mutation_check.py`.
Create a new audit package for the exact revision under review; historical reports are not current
validation or independent audit approval.
