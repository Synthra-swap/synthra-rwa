# Additional stock rollout

NVDA is already deployed and active. The batch commands below exclude NVDA by default and operate on META, PLTR, GOOGL, AAPL, MSFT, INTC, AMZN, AMD, TSLA, COIN and AVGO. Use `--assets AAPL MSFT` to limit a batch. Each stock has an independent source vault, destination bridge, wrapped token, timelocks, configuration directory and receipt directory.

The reviewed identities and fixed raw transfer ceilings are in `config/layerzero.stocks.json`. The ceilings retain the approved September 24 allocation, approximately USD 100,000 at that reference price and issuer multiplier; they do not track live prices. All pairs use 15 confirmations, both LayerZero Labs and Nethermind, manual completion, the same hardware governance/guardian and fee receiver as NVDA, a 48-hour governance delay after bootstrap, and 30-day metadata validity.

All twelve pairs are now deployed and active with initial metadata received; the independent audit is pending. The commands below document the deployment procedure. Preserve actual receipt-based identities in the public mainnet registry; simulated addresses are not deployment evidence.

## 1. Prepare and deploy — deployment wallet

Run from the repository root with Foundry on PATH. Keep `DEPLOYER_PRIVATE_KEY` local; it must resolve to `0xfd2301819C2064b7Bd06212D22594CEB172c07bf`.

```sh
python3 tools/layerzero_batch.py prepare
python3 tools/layerzero_batch.py deploy --chain robinhood --broadcast
python3 tools/layerzero_batch.py deploy --chain arc --broadcast
```

Without `--broadcast`, deploy only simulates. Each side creates a timelock and an endpoint; Arc also creates the wrapped token inside the endpoint constructor. Existing reconciled deployments are checked against their live state and skipped. There is no automatic retry after an ambiguous broadcast. If interrupted, reconcile the affected stock explicitly:

```sh
python3 tools/layerzero_deploy.py reconcile --asset AAPL --chain robinhood
```

Preserve `.tools/layerzero-deployment-runs/<SYMBOL>/` and `config/deployments/layerzero-mainnet/<SYMBOL>/`. Never delete attempt markers to rerun a deployment. The old commands without `--asset` still refer to NVDA.

## 2. Pair and activate — hardware wallet

Connect `0x20A32b077906Feb43D5EcaC7EF1425a48E25B4CC` when each browser signing prompt opens. The batch processes one stock at a time and displays the exact chain, contract and calldata. There are four hardware signatures per stock: pair on both chains, then activate on both chains. Initial activation has no timelock wait.

```sh
python3 tools/layerzero_batch.py wire --chain robinhood --broadcast
python3 tools/layerzero_batch.py wire --chain arc --broadcast
python3 tools/layerzero_batch.py activate --chain robinhood --broadcast
python3 tools/layerzero_batch.py activate --chain arc --broadcast
```

Both sides must be paired before either is activated. Existing paired/active state is verified before skipping an action. After a signing interruption, inspect wallet activity and preserve the per-stock operation record before retrying.

## 3. Publish and receive metadata — deployment wallet

```sh
python3 tools/layerzero_batch.py metadata --broadcast
python3 tools/layerzero_batch.py status
python3 tools/layerzero_batch.py complete --broadcast
```

Metadata originates on Robinhood. Completion automatically uses Arc. Each stock has its own publication and message path. The batch reuses successful publication receipts; it never republishes to accelerate verification. Stocks still attesting are listed and skipped by `complete`; rerun that command later. Already consumed messages are skipped. An ambiguous completion attempt stops the batch until reconciled.

## 4. Confirm the deployed state

Check `peer()` and `remoteToken()` on both endpoints, `pausedLanes() == 0`, and
`bootstrapper() == address(0)`. For each initial metadata GUID, require
`consumedMessages(guid) == true` on Arc and `metadataFresh() == true` on the wrapped token.
Preserve source and destination receipts. A successful metadata message does not establish an
asset round trip; validate deposit/redemption accounting separately before the audit handoff.

## Individual operation example

```sh
python3 tools/layerzero_operate.py status --asset AAPL --chain robinhood --tx <SOURCE_HASH>
python3 tools/layerzero_operate.py complete --asset AAPL --chain robinhood --tx <SOURCE_HASH> --broadcast --id metadata-complete
```

Operation IDs are scoped to the stock directory. Future metadata refreshes require a new operation ID per stock.
