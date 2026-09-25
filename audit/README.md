# Validation evidence

JSON observations and reports in this directory are dated evidence, not a current audit certificate.
They include earlier Wormhole checks and the September 25 LayerZero contract review. Check source
hashes before applying a report to a later commit. Operational tooling and documentation changed
since the initial LayerZero validation snapshot.

Generated logs, coverage, Slither output, tarballs, release manifests and checksums are excluded from
Git. `bash tools/check.sh` writes current local reports here. CI uploads the generated reports and
archive as an artifact. `python3 tools/package_audit.py` packages the available source and explicitly
selected evidence; it does not rerun tests or certify historical evidence as current.

The source repository retains JSON network/provenance observations needed to understand earlier
findings. Mainnet deployed identities and initial metadata transaction hashes are in
`config/layerzero.mainnet.json`. Never add private keys, signed raw transactions, authenticated RPC
URLs or local deployment-run directories to an audit artifact.
