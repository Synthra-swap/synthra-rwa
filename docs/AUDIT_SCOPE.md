# Audit scope

## Current LayerZero deployment

The primary smart-contract scope is **all Solidity files in `src/layerzero/`**, plus
`src/interfaces/IScaledUIAmount.sol`, `script/DeployLayerZero.s.sol` and its transitive OpenZeppelin dependencies. These are the contracts
used by the twelve Robinhood/Arc pairs listed in [the mainnet registry](../config/layerzero.mainnet.json).
Deployment and initial metadata reception have been verified; the independent audit is in progress.
Review an exact commit and file hashes, not a moving branch name or an older evidence archive.

| Contract | Responsibility |
| --- | --- |
| LayerZeroSourceVault | Custody, exact transfers, fee payout, deposits, releases, source metadata |
| LayerZeroDestinationBridge | Minting, burning, destination metadata reception |
| LayerZeroWrappedAsset | ERC-20 balances and authenticated issuer multiplier snapshots |
| LayerZeroEndpoint | Peers, DVNs/libraries, confirmations, pauses, limits, bootstrap, checkpoint recovery |
| LayerZeroMessage | Payload encoding and domain validation |
| ILayerZero.sol | Local interface definitions for the external protocol |

Include `tools/check_layerzero_config.py`, `tools/layerzero_deploy.py`, `tools/layerzero_operate.py`,
`tools/layerzero_batch.py`, `tools/layerzero_roundtrip.py` and the shared `evm_rpc.py`, `deployment_helpers.py` and `rpc_policy.py` helpers in the operational
review. They validate deployment identities, handle ambiguous broadcasts and prepare authenticated
manual delivery. Include the selected configuration templates, stock registry and mainnet registry.
Tests live in `test/layerzero/` and `integration/LayerZeroLive.t.sol`; mocks are never production contracts.

## Properties to challenge

1. Only an authenticated packet from the bound peer, domain and asset can mint or unlock. Both required
   DVNs, pinned libraries, confirmation depth, GUID and replay checks must be enforced.
2. A deposit pays `floor(gross * 50 / 10000)` immediately and creates only net liabilities. Failed
   publication rolls back token movement, fee payout and accounting together.
3. A redemption burns only the caller's tokens and cannot redirect the original recipient on completion.
4. Under authentic messages, `locked = wrapped supply + pending net deposits + pending redemptions`.
5. There is no administrative reserve withdrawal, arbitrary mint, unsigned claim cancellation or
   protocol-security bypass. Fees, native messaging costs and backing remain distinct.
6. Per-transfer limits preserve previously initiated claims; the inbound ceiling is monotonic. No
   aggregate cap or shared throughput bucket exists. Governance prepares receivers before increases.
7. Guardian pause is immediate; post-bootstrap administration uses ownership/timelock authority.
   The initial exception closes permanently on activation or other documented closure paths.
8. Out-of-order completion, committed nonce backlogs and checkpoints cannot consume a claim twice,
   skip authentication, strand an otherwise deliverable claim or corrupt reserves.
9. Issuer snapshots cannot change raw balances, overwrite newer snapshots or restart their lifetime
   on delivery. Stale metadata must never silently authorize a display conversion.
10. Token/native callbacks, failed refunds, taxed/frozen/seized assets and partial operational failures
    preserve the intended accounting and retry semantics.

See [LAYERZERO.md](LAYERZERO.md) and [the internal review](LAYERZERO_INTERNAL_REVIEW.md) for details.

## Configuration and external dependencies

- Both **LayerZero Labs and Nethermind** are required; 15 source confirmations are pinned on both
  routes. There is no additional Ethereum-finality gate. Optional DVNs are disabled, delegate is zero,
  and the selected Endpoint, libraries, DVNs and counts are immutable for each deployed pair.
- LayerZero EndpointV2/ULN implementations are external dependencies. The local ABI subset was compared
  to LayerZero-v2 commit `9c741e7f9790639537b1710a203bcdfd73b0b9ac`; ABI equivalence does not establish
  source/runtime equivalence or off-chain worker availability.
- OpenZeppelin Contracts 5.1.0, including TimelockController, is vendored and unmodified. forge-std 1.9.1
  is a test/script dependency. See `vendor/PROVENANCE.json` and `vendor/SHA256SUMS.json`.
- Solidity 0.8.28, optimizer 200, Paris production bytecode, no bytecode metadata; Foundry 1.5.1.
  Deployment fork execution uses a separate Cancun profile with Paris compilation restrictions.
- Governance and guardian currently share the hardware-wallet EOA recorded in the registry. Endpoints
  are owned by their timelocks, initially 48 hours. Governance can subsequently change the timelock
  delay or nominate another owner through the existing authority paths; review that trust model.

Issuer solvency, share custody, eligibility, issuer freeze/seizure/upgrades, chain finality, RPC service
availability, DVN honesty/liveness and user key security remain external assumptions. Local forks
impersonate DVNs and do not prove genuine attestation or mainnet end-to-end reliability.

## Reproduction and handoff

Run `bash tools/check.sh`, the LayerZero mutation and live-fork checks, then
`python3 tools/package_audit.py`. CI provides generated reports as downloadable artifacts. Local
`audit/RELEASE_MANIFEST.json` and `audit/SHA256SUMS` identify a generated archive; they are not tracked
release approvals. Dated evidence in Git is historical unless its input hashes match the reviewed
revision. Read [LAYERZERO_VALIDATION.md](LAYERZERO_VALIDATION.md) for test limitations.
