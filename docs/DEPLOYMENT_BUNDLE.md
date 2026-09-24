# Preparing and executing the selected stock deployments

`tools/prepare_deployment.py` creates one source configuration, one destination configuration,
and a pending pair-verification template per asset. Real inputs and generated files belong under
ignored `config/deployments/`. They are not included in the public audit archive. The generator
does not fetch prices, sign, or send transactions. Keep the raw registry, quote and RPC evidence
alongside the local reviewed input file.

## Reviewed input and amount conversion

The plan contains `source` and `destination` network objects with `evmChain`, `wormholeChain`,
`core`, `governanceSafe`, `guardian`, `deployer`, `outboundConsistency` and `inboundConsistency`.
`source.treasury` is the fee recipient. Top-level fields are `governanceDelaySeconds`,
`metadataMaxAgeSeconds`, decimal strings `referenceLimitUsd` and `referenceTestUsd`, boolean
`amountPolicyApproved`, and an `assets` array. Each asset records:

- `symbol`, `token`, `uid`, `decimals`, `wrappedName`, `wrappedSymbol`;
- `quoteBidUsd`, `quoteAskUsd`, `currency`, `isTradingHalt`, `quoteGeneratedAt`;
- `multiplierRaw`, `registryMultiplier`, `registryStatus`, `multiplierObservedAt`;
- the quote URL and the onchain observation block/hash as supporting evidence.

Check token address and UID against the official registry and onchain getters. The generator
requires positive, matching API/onchain multipliers, USD quotes, an active asset without a trading
halt, and observations no older than 24 hours at generation. These are dated configuration inputs,
not permanent eligibility assertions. Refresh and reconcile them before signing if conditions change.

Robinhood's [REST prices](https://docs.robinhood.com/chain/stock-token-apis/) are USD per underlying
share, before the multiplier. Use `uiMultiplier()` from the original token and 18-decimal raw units:

```text
raw = floor(referenceUSD × 10^36 / (REST_ask_USD × multiplierRaw))
feeRaw = floor(testGrossRaw × 50 / 10000)
testNetRaw = testGrossRaw - feeRaw
```

The ask and downward rounding keep the reference amount at or below the chosen USD budget at
that quote. Execution prices, gas and later price/multiplier changes are not covered. Do not apply
this conversion to an already multiplier-adjusted Chainlink price. Initial outgoing and incoming
limits match on both chains. The limits remain fixed raw-token amounts until governance changes them.

```sh
python3 tools/prepare_deployment.py \
  --plan config/deployments/reviewed-plan.json \
  --output config/deployments/mainnet
```

The output directory must be new. Review `AMOUNTS.md`, the generated JSON files and `bundle.json`.
The bundle fingerprints configuration, production sources, vendored dependencies, deployment script,
runner and compiler settings. Any edit invalidates execution until a fresh bundle is generated.
The manifest detects accidental drift; it is not a signed approval or an independent audit.

## Simulate each asset and chain

Run from the repository root. Set `SOURCE_RPC_URL` and `DESTINATION_RPC_URL` locally; keep provider
credentials out of committed files and chat. The broadcast path requires a provider that supports
state reads at finalized blocks. Public/latest-state simulations do not satisfy that check.

```sh
python3 tools/deploy_asset.py --bundle config/deployments/mainnet/bundle.json \
  --asset NVDA --side source
python3 tools/deploy_asset.py --bundle config/deployments/mainnet/bundle.json \
  --asset NVDA --side destination
```

Repeat for the other selected symbols. Each invocation simulates **one** side using its configured
sender and current network state. It creates a timelock and endpoint; the destination endpoint also
creates its wrapped token. Independent simulations can report the same predicted addresses because
they start from the same current sender nonce. These are not the addresses of an entire future batch.
Do not bind peers from simulation output. Only actual successful deployment receipts establish them.

Logs and Foundry transaction records are separated by chain and asset under `.tools/deployment-runs/`.
The simulation never needs the private key. Verify native gas balances on both chains and acquire the
specified original stock amounts for live round trips. Simulated/fork-injected token balances do not
fund the real deployer. Use `s<TICKER>` / `Synthra Wrapped <TICKER>` only if those generated names are
the intended public token identifiers; names and symbols cannot be changed after deployment.

The runner uses the `deployment` Foundry profile: Cancun execution for remote token opcodes, with
compiler restrictions keeping the script, production contracts and their dependencies on the audited
Paris target. Inherited `FOUNDRY_*` / `DAPP_*` overrides are removed. Do not simply recompile the
production contracts with `--evm-version cancun` to work around a `NotActivated` fork error.

## Explicit operator broadcast

The operator supplies `DEPLOYER_PRIVATE_KEY` in their local environment. The runner checks that the
derived address equals the reviewed deployer, checks finalized-state Core identity, then runs a fresh
simulation before sending. It passes the key to local Foundry without printing it; command-line
arguments may be visible to other processes under the same user. Use a trusted local machine and
unset the variable afterward. No key is written to the plan, manifest or runner logs.

```sh
python3 tools/deploy_asset.py --bundle config/deployments/mainnet/bundle.json \
  --asset NVDA --side source --broadcast
python3 tools/deploy_asset.py --bundle config/deployments/mainnet/bundle.json \
  --asset NVDA --side destination --broadcast
unset DEPLOYER_PRIVATE_KEY
```

Broadcast one side at a time; confirm the two creation receipts before proceeding. Each attempt
leaves an exclusive marker, including failed or interrupted attempts. There is no automatic retry,
resume, activation or bulk broadcast. A deployment spans two transactions and can partially succeed.
After an error, inspect the preserved Foundry receipts and sender nonce, record any deployed contracts,
and reconcile the remaining transaction manually before clearing a marker. Never blindly rerun or
use a second output directory to bypass a recorded attempt.

## Record, bind and activate

For each pair, copy `pair.pending.json` to `pair.json` and fill it from actual receipts and reviewed
runtime hashes. Leave the original template intact so its bundle hash continues to match. Record both
timelocks, source vault, destination bridge and wrapped token, transaction hashes, constructor arguments,
chain IDs and source revision. Verify every endpoint is paused, owned by its timelock, and uses the
approved guardian, roles, fees and limits. Verify published contract sources on the chain explorers.

Follow [OPERATIONS.md](OPERATIONS.md#3-bind-and-activate-the-initial-pair-without-a-timelock-wait): submit reciprocal
`bootstrapSetPeer` calls directly from the hardware governance wallet, with no initial timelock wait. Run paired
`preflight.py --phase prepared` at finalized blocks. Source `remoteToken` must be the actual wrapped
token; destination `remoteToken` must be the original stock. Peer bindings are irreversible.

Then submit `activate()` directly from that wallet on each endpoint after the documented audit sign-off
and readiness checks. This immediately enables both lanes and permanently clears the bootstrap authority.
The deployer cannot perform these actions. Subsequent unpauses and administrative changes use the timelock.
Publish and deliver metadata, then deposit the recorded test gross amount, retrieve the signed VAA,
complete on Arc, redeem the net amount and complete the return on Robinhood. Assert the fee recipient
received `testFeeRaw`, no return fee was charged, and supply/backing returned to their starting state.
Run `preflight.py --phase active`. There is no automatic relayer and no timeout refund. Keep source
transactions/emitter sequences and VAAs so interrupted user completion can be retried.
The initial live pilot may use one stock; the other pairs still need individual configuration checks.
The generated USD 10 amounts are optional per-asset test references, not a requirement to fund all twelve
before the pilot. A successful pilot does not establish every issuer's transfer eligibility.
