# NVDA LayerZero mainnet pilot

For the other eleven reviewed stocks, use [Additional stock rollout](LAYERZERO_STOCK_ROLLOUT.md). Its batch commands exclude the existing NVDA deployment by default.

This is the authorized pre-audit pilot. A successful pilot is evidence for the external audit, not an audit result. Keep the existing Wormhole contracts and saved transfer records: their liabilities cannot be redeemed through the new LayerZero pair.

Deploy NVDA first as the initial asset of the intended production deployment, with no public announcement. These are real mainnet contracts intended to remain in use if validation and the external audit support that decision. Extend to the other stocks after the live NVDA round trip succeeds. Local forks with impersonated DVNs cannot establish real operator availability or delivery latency; the mainnet test must receive actual LayerZero Labs and Nethermind attestations in both directions.

## Wallets and security settings

| Purpose | Wallet |
| --- | --- |
| Deployment, metadata and small asset test | `0xfd2301819C2064b7Bd06212D22594CEB172c07bf` (local private-key signer) |
| Initial peer binding and activation; later governance/guardian | `0x20A32b077906Feb43D5EcaC7EF1425a48E25B4CC` (hardware wallet through a browser wallet) |
| Fee recipient | `0x1CAB229e4D75E4DE0EC890bef0295a32BAaa1328` |

Both LayerZero Labs and Nethermind are required, with 15 source confirmations in each direction. Delivery uses the selected ULN verification policy without an additional elapsed-time or Ethereum-finalized gate. There is no relayer. The user sends on the source chain and completes on the destination, with a separate ERC-20 approval if needed. Queue recovery can require extra transactions; it never discards another user's claim.

The first hardware-wallet activation has no timelock. Subsequent governance uses the 48-hour timelock; guardian pause is immediate. New endpoints are deployed paused.

## 1. Deploy both sides — deployment wallet

Run from the contract repository. `DEPLOYER_PRIVATE_KEY` must already be set in your own terminal; never put a key in these files or chat. Foundry (`forge`, `cast`) must be on `PATH`.

```sh
python3 tools/layerzero_deploy.py prepare
python3 tools/layerzero_deploy.py deploy --chain robinhood --broadcast
python3 tools/layerzero_deploy.py deploy --chain arc --broadcast
```

Without `--broadcast`, these commands only simulate. Default RPCs are the free Robinhood and Arc mainnet endpoints. `SOURCE_RPC_URL` and `DESTINATION_RPC_URL` may override them. An archive subscription is not required for the selected message verification policy.

Actual receipts and checked runtime identities are written to:

- `config/deployments/layerzero-mainnet/NVDA/robinhood.deployed.json`
- `config/deployments/layerzero-mainnet/NVDA/arc.deployed.json`
- Original Foundry broadcasts: `.tools/layerzero-deployment-runs/NVDA/<chain>/foundry/DeployLayerZero.s.sol/<chain-id>/run-latest.json`

A permanent attempt marker prevents repeated or concurrent deployment after an uncertain outcome. If submission succeeded but receipt reconciliation was interrupted, use the read-only command:

```sh
python3 tools/layerzero_deploy.py reconcile --chain robinhood
python3 tools/layerzero_deploy.py reconcile --chain arc
```

Do not delete attempt markers or rerun a deploy to resolve an RPC error. Preserve partial receipts and investigate the recorded transaction hashes first. Simulated addresses are never treated as deployed addresses.

## 2. Bind peers and activate — hardware wallet

Connect the hardware account above to a supported browser wallet. These commands open Foundry's browser signer. Review the displayed chain, contract, calldata and zero native value before confirming on the hardware device. The hardware private key is never exported.

```sh
python3 tools/layerzero_operate.py wire --chain robinhood --broadcast --id wire-robinhood
python3 tools/layerzero_operate.py wire --chain arc --broadcast --id wire-arc
python3 tools/layerzero_operate.py activate --chain robinhood --broadcast --id activate-robinhood
python3 tools/layerzero_operate.py activate --chain arc --broadcast --id activate-arc
```

Each action first checks on-chain configuration and simulates. Both peers must be correct before either activation. Removing `--broadcast` prints the unsigned action only. The hardware account needs ETH on Robinhood and USDC on Arc for gas.

## 3. Publish and complete metadata — deployment wallet

```sh
python3 tools/layerzero_operate.py metadata --chain robinhood --broadcast --id metadata-initial
```

Save the printed transaction hash as `METADATA_TX`. It is also in `.tools/layerzero-deployment-runs/NVDA/operations/metadata-initial/receipt.json`.

```sh
python3 tools/layerzero_operate.py status --chain robinhood --tx "$METADATA_TX"
```

`attesting` means wait and rerun **status**, without publishing again. When it reports `ready`, complete on Arc:

```sh
python3 tools/layerzero_operate.py complete --chain robinhood --tx "$METADATA_TX" --broadcast --id metadata-complete
```

For `status` and `complete`, `--chain` is always the **original source chain**. The tool selects the opposite chain for completion. Metadata is read from the issuer contract; the publisher cannot provide arbitrary multiplier values. Refresh before its 30-day expiry, or earlier when needed, using a new operation ID.

## 4. Real asset round trip — deployment wallet

Take a baseline snapshot before the asset transfer:

```sh
python3 tools/layerzero_roundtrip.py snapshot
```

Use a small raw amount within the wallet balance and configured limit. For the NVDA example,
`10000000000000000` raw units is 0.01 token; after the 0.5% entry fee the net amount is
`9950000000000000` raw units. These are token quantities, not live USD values.

```sh
python3 tools/layerzero_operate.py approve --chain robinhood --amount-raw 10000000000000000 --broadcast --id pilot-approve
python3 tools/layerzero_operate.py send --chain robinhood --amount-raw 10000000000000000 --broadcast --id pilot-deposit
```

Save the deposit hash as `DEPOSIT_TX`. Wait for `ready`, then receive on Arc:

```sh
python3 tools/layerzero_operate.py status --chain robinhood --tx "$DEPOSIT_TX"
python3 tools/layerzero_operate.py complete --chain robinhood --tx "$DEPOSIT_TX" --broadcast --id pilot-deposit-complete
```

Redeem the received amount from Arc; no wrapped-token approval is needed:

```sh
python3 tools/layerzero_operate.py send --chain arc --amount-raw 9950000000000000 --broadcast --id pilot-redemption
```

Save this hash as `REDEMPTION_TX`. Wait for `ready`, complete on Robinhood, then verify accounting:

```sh
python3 tools/layerzero_operate.py status --chain arc --tx "$REDEMPTION_TX"
python3 tools/layerzero_operate.py complete --chain arc --tx "$REDEMPTION_TX" --broadcast --id pilot-redemption-complete
python3 tools/layerzero_roundtrip.py verify --deposit "$DEPOSIT_TX" --redemption "$REDEMPTION_TX"
```

The verifier checks consumption on both sides, raw amounts and fee, original-wallet and fee-recipient
deltas, and restoration of initial locked backing, wrapped supply and wrapped wallet balance. It fails
if unrelated activity makes balance comparisons ambiguous. Its output is
`config/deployments/layerzero-mainnet/NVDA/roundtrip-verified.json`.

Each operation ID is single-use. After an interrupted send, reconcile its receipt and wallet activity
before retrying. Never republish a source message merely because delivery is delayed.

## 5. Audit handoff

Freeze the contract and operational-tool revision, attach actual deployment receipts and the verified
round-trip report, and regenerate the audit manifest. Include the selected DVNs/confirmations and
legacy Wormhole liabilities. Obtain the independent audit and resolve its findings.

Local fork verification is reproducible with `tools/check_layerzero_operations_fork.py` against two
local anvil forks. Its DVN transactions are impersonated locally; they do not measure real mainnet
DVN availability or replace the live pilot.
