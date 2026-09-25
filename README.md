# Synthra RWA Bridge

Permissionless stock bridging between **Robinhood Chain (4663)** and **Arc (5042)** using LayerZero V2.
Each stock has a source vault on Robinhood and a destination bridge with its own wrapped ERC-20 on Arc.

**Mainnet deployment is active; external audit is pending. Use at your own risk.** The twelve pairs
were verified active with initial metadata received on September 25, 2026. Deployment and successful
transactions do not establish audit approval.

Supported stocks: **NVDA, META, PLTR, GOOGL, AAPL, MSFT, INTC, AMZN, AMD, TSLA, COIN, AVGO**.
Public contract addresses, runtime hashes, deployment transactions and metadata transactions are in
[the mainnet registry](config/layerzero.mainnet.json). Operational signing configs and private keys
are never committed. Registry observations are dated; query the chains for current pause and metadata state.

## How transfers work

1. **Robinhood → Arc:** approve the stock if needed, then deposit. The vault transfers a fixed 0.5%
   entry fee to the fee recipient and locks the net raw amount.
2. **Verification:** LayerZero Labs and Nethermind must both attest under the explicitly pinned
   15-confirmation policy. There is no additional application timer and no guaranteed delivery time.
3. **Completion:** the user submits a second transaction on Arc to mint the net wrapped amount.
4. **Arc → Robinhood:** burn wrapped tokens, then complete on Robinhood to unlock the underlying.
   There is no bridge fee on redemption; network and messaging fees still apply.

Completion is permissionless and does not require an operator relayer. Claims can be recovered from
the original source transaction and authenticated destination state.
Metadata snapshots come from the source issuer, remain valid for 30 days from observation, and may
be refreshed early. They affect share display conversions, never raw ERC-20 balances.

There is no aggregate cap or shared rate bucket. Each pair has a fixed raw-unit transfer ceiling,
initially based on approximately USD 100,000 at the reviewed reference prices; it is not a live USD cap.
Governance changes use a timelock. Guardian pause is immediate. Initial binding/activation was a
one-time exception, now closed on the deployed pairs. Governance can rotate the recipient of future
fees; it cannot withdraw reserves or bypass message authentication. The same hardware wallet currently
holds governance and guardian authority. Issuer custody, freezing, seizure and upgrade powers remain
external risks, as do chain reorganizations and the security/availability of both required DVNs.

## Repository guide

| Path | Purpose |
| --- | --- |
| `src/layerzero/` | Current bridge contracts and local LayerZero interfaces |
| `script/DeployLayerZero.s.sol` | Deployment and immutable protocol configuration |
| `test/layerzero/`, `integration/LayerZeroLive.t.sol` | Unit/fuzz/invariant and local mainnet-fork tests |
| `tools/layerzero_*.py` | Deployment, pairing, activation, metadata and recovery |
| `config/layerzero.stocks.json` | Reviewed stock identities and initial raw limits |
| `config/layerzero.mainnet.json` | Public deployed identities and transaction references |
| `docs/` | Protocol, audit scope and operational runbooks |
| `audit/` | Dated evidence; generated logs/archives are local or CI artifacts |

Start with [protocol and security](docs/LAYERZERO.md), [audit scope](docs/AUDIT_SCOPE.md),
[deployment operations](docs/LAYERZERO_PILOT.md), [multi-stock rollout](docs/LAYERZERO_STOCK_ROLLOUT.md),
and [validation and its limits](docs/LAYERZERO_VALIDATION.md).

The older Wormhole contracts and recovery tools remain in this repository to support their separate
existing deployment and pending claims. LayerZero does not migrate those balances or settle Wormhole
claims. Their specification is [here](docs/SPECIFICATION.md); recovery instructions are in
[OPERATIONS.md](docs/OPERATIONS.md). The completed message-only LayerZero experiment is no longer
part of the source tree; the asset bridge tests and operational tools are the maintained path.

## Development and verification

Prerequisites: Foundry 1.5.1, Solidity 0.8.28, Python >=3.11; Slither 0.11.3 for static analysis.
OpenZeppelin and forge-std are vendored with provenance and checksums.

```sh
bash tools/check.sh
python3 tools/layerzero_mutation_check.py
bash tools/check_live.sh
python3 tools/verify_layerzero_abi.py
python3 tools/package_audit.py
```

`check.sh` runs dependency integrity, Python tests, Solidity formatting, unit/fuzz/invariant tests,
coverage, gas reports and static analysis. The fork and ABI checks use public network reads; none
of these commands broadcasts transactions. Local compiler overrides are detected by `check.sh`;
Foundry can otherwise obtain the configured compiler. See the runbooks before using any `--broadcast` command.

CI runs the local checks and LayerZero mutation campaign, then publishes an audit artifact. Generated
logs, coverage, manifests and tarballs are not committed. An archive records exact file hashes; packaging
alone does not certify that every included historical report applies to the current revision.
Independent audit, reconciliation of the real asset round-trip evidence, explorer verification and
resolution of audit findings remain part of the release handoff.
