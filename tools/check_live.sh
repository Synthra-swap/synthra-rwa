#!/usr/bin/env bash
# Opt-in read-only RPC access; all state mutations stay inside Foundry forks.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROBINHOOD_REVIEW_RPC="${ROBINHOOD_REVIEW_RPC:-https://rpc.mainnet.chain.robinhood.com}"
export ARC_REVIEW_RPC="${ARC_REVIEW_RPC:-https://rpc.mainnet.arc.io}"
export FOUNDRY_PROFILE=deployment
export FOUNDRY_TEST=integration
compiler=()
if [[ -x .tools/solc-0.8.28 ]]; then compiler=(--use "$PWD/.tools/solc-0.8.28" --offline); fi
mkdir -p audit
forge test "${compiler[@]}" -vv > audit/live-fork-tests.log 2>&1
cat audit/live-fork-tests.log
