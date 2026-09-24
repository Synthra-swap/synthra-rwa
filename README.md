# Synthra RWA Bridge — audit candidate

A permissionless protocol that bridges the representation of **one original asset per pair**
from Robinhood to Arc and redeems it on the source chain. Contracts are non-upgradeable, balances
are backed 1:1 in raw units, and Synthra contracts have no user allowlist, blacklist, or administrative
withdrawal function. Original tokens remain subject to their issuer's blocking, pausing, burning,
and upgrade powers.

**Synthra charges 0.5% on entry only, paid immediately to the treasury.**
A deposit of 100 tokens produces 99.5 wrapped tokens and pays 0.5 tokens to the treasury in the same
transaction. Redemption has no Synthra fee. Native network and Wormhole fees are separate.
The fee rounds down in raw token units; its rate is immutable. Governance can change the recipient
of future fees through the timelock without moving reserves or fees already paid.
The guardian can pause immediately, without waiting for the timelock.

This is an **audit candidate**, not an audited release or approval to launch.
No public deployment has been performed. Fork checks for all twelve selected stocks and the real
Core contracts are documented; final configuration, issuer checks, and a complete Synthra round
trip with live Guardians remain launch requirements.

## User transaction flow

Users submit both bridge transactions: initiation on one chain, then completion with a signed
Wormhole VAA on the receiving chain. An original-token allowance may require an additional approval
transaction before a deposit; redemption burns the caller's wrapped balance without an approval.
There is no automatic relayer service in the planned production model. Anyone may still complete a
valid message, but users must have gas on both chains and cannot assume someone else will deliver it.
Metadata updates likewise require publication and destination completion; they are not automatic.

## Documents for auditors

- [Internal adversarial review: findings, fixes, and open conditions](docs/INTERNAL_AUDIT.md)
- [Real network and token checks, issuer powers, and remaining limitations](docs/INTEGRATION_REVIEW.md)
- [Scope, properties, and dependencies](docs/AUDIT_SCOPE.md)
- [Specification, message format, and fees](docs/SPECIFICATION.md)
- [Trust model](docs/THREAT_MODEL.md)
- [Static analysis and security decisions](docs/SECURITY_ANALYSIS.md)
- [Deployment, relay, and incident response](docs/OPERATIONS.md)
- [Validation performed and its limitations](docs/VALIDATION.md)
- [Package manifest](audit/RELEASE_MANIFEST.json)
- [Historical audit archives](docs/ARCHIVE_HISTORY.md)

## Setup and verification

Prerequisites: Foundry 1.5.1, Solidity 0.8.28, and Python >=3.11. Static analysis requires Slither 0.11.3.
Solidity dependencies are vendored with provenance and checksums; npm installation is unnecessary.

```sh
git clone https://github.com/Synthra-swap/synthra-rwa.git
cd synthra-rwa
forge test
forge script script/LocalDemo.s.sol:LocalDemo
bash tools/check.sh
python3 tools/package_audit.py
```

If the official compiler is installed locally at `.tools/solc-0.8.28`, it can also be used offline
(the compiler binary is not included in the repository):

```sh
forge test --use .tools/solc-0.8.28 --offline
forge script script/LocalDemo.s.sol:LocalDemo --use .tools/solc-0.8.28 --offline
```

`tools/check.sh` automatically selects that compiler when available. The demo does not broadcast
transactions: it deposits 10 mock tokens, immediately pays 0.05, mints 9.95, and redeems 4.
The final balances are 5.95 vault tokens and 5.95 wrapped tokens. Do not add `--broadcast` to the demo.

## Architecture

| Component | Responsibility |
| --- | --- |
| `SourceVault` | Deposits, immediate fees, net backing, redemption, multiplier publication |
| `DestinationBridge` | Minting, burning, receiving authenticated snapshots |
| `WrappedAsset` | Permissionless ERC-20; UI multiplier and conversions separate from raw balances |
| `WormholeEndpoint` | VAA verification, EVM/Wormhole domains, peer immutable after setup, replay protection, per-message limits, emergency pause |
| `TimelockController` | Initial governance with a minimum 48-hour delay in deployment scripts |

The guardian role permits immediate pausing of one or both directions. The selected hardware wallet
also holds governance proposal/execution/cancellation roles, but resuming and administrative changes
still require execution through the timelock. This concentrates both roles in one signing key.
Pauses do not freeze wrapped ERC-20 transfers. The system depends on the original issuer, chain
finality, and Wormhole Guardians/Core; a pause can delay redemptions.

## Features in this release

- Complete net lock/mint and burn/unlock flows, with permissionless delivery and retries.
- Atomic fees in the original token, with no treasury claim on reserves.
- No total reserve or supply cap; a per-transfer maximum adjustable through the timelock, without shared capacity or refill.
- Contracts start paused; the peer can be configured only once.
- Current and scheduled multiplier synchronization, protection against out-of-order updates,
  schedule replacement/cancellation, and a 30-day metadata lifetime with permissionless early refresh.
- Tests with mocks and cryptographically signed binary VAAs verified by upstream Wormhole code.
- Stateful solvency tests, finalized-block preflight tools, and unsigned relay preparation.
- Deployment of a governance/endpoint pair on each chain, CI, and a reproducible audit archive.


## Current validation

The current source passed 125 Solidity tests, 67 Python tests, 27 security mutations, and 19 fork
checks covering all twelve selected stocks. Slither reported no High/Medium findings and four
reviewed Low timestamp findings. These are internal results, not an independent audit opinion.
See [VALIDATION.md](docs/VALIDATION.md) for evidence and limitations and
[INTEGRATION_REVIEW.md](docs/INTEGRATION_REVIEW.md) for real-token scenarios and fork pins.
