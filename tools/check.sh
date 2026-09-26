#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p audit/layerzero
compiler=()
if [[ -x .tools/solc-0.8.28 ]]; then
  export FOUNDRY_SOLC="$PWD/.tools/solc-0.8.28"
  compiler=(--use "$FOUNDRY_SOLC" --offline)
fi
python3 tools/verify_vendor.py
python3 -m unittest discover -s tools -p 'test_*.py' 2>&1 | tee audit/python-tests.log
forge fmt --check
forge test "${compiler[@]}" > audit/unit-tests.log 2>&1
FOUNDRY_PROFILE=audit forge test "${compiler[@]}" > audit/audit-tests.log 2>&1
forge coverage "${compiler[@]}" --report summary --report lcov --report-file audit/coverage.lcov > audit/coverage.log 2>&1
forge test "${compiler[@]}" --gas-report > audit/gas-report.log 2>&1
rm -f audit/slither.json
slither_status=0
slither . --filter-paths 'vendor/|test/|script/' --exclude-dependencies --json audit/slither.json > audit/slither.log 2>&1 || slither_status=$?
if [[ "$slither_status" != 0 && "$slither_status" != 255 ]]; then
  cat audit/slither.log
  exit "$slither_status"
fi
python3 tools/check_slither.py
printf 'Audit checks passed. Reports are in audit/.\n'
