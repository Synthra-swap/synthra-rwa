# Validation evidence

This directory contains LayerZero evidence and source-asset research. Observations are dated; they
are not an independent audit certificate. Mainnet deployed identities and transaction references
are in `config/layerzero.mainnet.json`. The external audit is in progress.

`bash tools/check.sh` writes current Python, unit/fuzz/invariant, coverage, gas and static-analysis
reports. Live-fork and mutation checks run separately. CI uploads generated reports and the audit
archive. `tools/package_audit.py` packages tracked source, public configuration and explicitly selected
reports; it does not rerun checks or certify historical evidence as current.

Earlier implementation and mixed-scope evidence are preserved in the archive branch linked in
`docs/ARCHIVE_HISTORY.md`. Never add private keys, signed raw transactions, authenticated RPC URLs or
local deployment-run directories to a report or audit artifact.
