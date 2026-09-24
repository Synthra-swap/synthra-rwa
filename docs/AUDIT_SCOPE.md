# Audit scope

Review candidate v0.1, single source asset and one destination representation. No public deployment.
The authoritative source snapshot is `audit/RELEASE_MANIFEST.json`; the archive checksum is in
`audit/SHA256SUMS`. Hashes, not a moving branch name, identify the version handed to the auditor.
Any post-review code change requires a new manifest and review of its impact.

## In scope

All `src/**/*.sol`, the deployment procedure in `script/Deploy.s.sol`, `tools/preflight.py`,
`tools/prepare_relay.py`, `tools/prepare_deployment.py`, `tools/deploy_asset.py`, `tools/rpc_policy.py`, dependency selection
and administrative configuration. The deployment helpers are operational tooling, not deployed contracts. Review the
financial consequences of instant fee payout and the independent metadata channel.

Primary contracts: SourceVault, DestinationBridge, WrappedAsset, WormholeEndpoint,
BridgeMessage and the two local interfaces. Contracts are not proxies. The deployed governance
is OpenZeppelin TimelockController with no external bootstrap administrator and an initial >=48h delay.
The selected hardware-wallet EOA holds proposer/executor/canceller roles and also serves as the
emergency guardian. Endpoints remain owned by the timelock, not directly by that EOA. Review this
single-key trust model and the one-time bootstrap exception: only initial binding and first activation
are immediate. All later resumptions and other administrative operations use the delayed execution path.
Bootstrap must close on any unpause or ownership nomination and must never be reopened.
That delay can subsequently be reduced by governance; endpoint ownership can also migrate away from
the timelock. See the reproduced governance properties in `INTERNAL_AUDIT.md`.

## External dependencies

- OpenZeppelin Contracts 5.1.0: ERC20, SafeERC20, ReentrancyGuard, Ownable2Step, Math, ERC165,
  TimelockController and their transitive imports. Unmodified vendored sources.
- Wormhole Core: live deployment is an externally governed dependency. The ABI subset is local.
  Signature tests use unmodified upstream Messages.sol / Getters.sol and their dependencies at
  commit `2df4000c5bd228e5ce3a3d87f0475837071587f9`. This verifier fixture is **test only**.
- forge-std 1.9.1: test/script dependency, not deployed in production.
- Solidity 0.8.28, optimizer 200 runs, EVM Paris, bytecode metadata disabled. Foundry 1.5.1.

`vendor/PROVENANCE.json`, `vendor/wormhole/PROVENANCE.json` and `vendor/SHA256SUMS.json`
identify origins and bytes. Test mocks deliberately expose unsafe setters; they must never be deployed
as replacements for an original token or Core.

## Properties to challenge

1. Only authenticated messages from the bound peer can mint/unlock. A different domain, action,
   asset, recipient encoding, signature set or replay cannot bypass the checks.
2. Successful deposits transfer exactly the gross amount, pay exactly floor(gross * 50 / 10000),
   and create net liabilities only. Any local failure rolls all three effects back.
3. A burn cannot consume another user's balance. Remote execution cannot redirect its recipient.
4. Under authentic messages, locked = supply + pending net deposits + pending burns.
5. Native message fee, revenue and principal remain separate. No owner/treasury reserve-withdrawal path.
6. Per-message maxima apply before committing funds. There is no aggregate cap or throughput
   bucket; repeated transfers in the same block must conserve backing and preserve authentication.
7. Pause/resume, transfer-limit changes, treasury rotation and ownership transitions respect their authority boundaries.
   Governance can change the recipient of future fees, but cannot alter asset, fee rate, Core,
   an already configured peer, nor transfer principal or previously paid fees.
   Receive-ceiling preparation is monotonic; outgoing changes need no pause and stay within that
   ceiling. Both operations require owner authority and reentrancy protection. Neither authenticates
   a claim or changes supply/backing. Operators prepare both receivers before outgoing increases.
8. Multiplier updates never alter supply or raw balances, cannot overwrite a later source snapshot,
   and stale metadata is never silently used for UI conversion.
9. Deployment begins paused with the intended timelock and no deployer bypass. Only the configured
   governance bootstrapper can bind and activate without delay before first unpause. It cannot change
   other parameters or bypass a later pause; normal partial unpause and ownership nomination also close it.

## Deliberately outside this audit's proof

Issuer solvency, legal eligibility/distribution rights, correctness and governance of live Core proxies,
Guardian availability, chain finality, external price feeds, underlying share custody, market making,
DEX/frontend integration, user device security, and operation of external RPC/attestation services.
The user completes the destination transaction; no automatic relayer is planned. Reliable message
retrieval, manual completion/recovery UX, and metadata refresh remain launch prerequisites, not
claims established by local tests. The standalone verifier harness does
not model Core proxy upgrades or prove that its revision matches a particular live deployment.

Research integration evidence and verified issuer powers are documented in `INTEGRATION_REVIEW.md`.
`integration/LiveFork.t.sol` and the public VAA fixture are test-only artifacts, not deployed code.

## Reproduction

Run `bash tools/check.sh`, inspect reports, then `python3 tools/package_audit.py`.
CI pins actions by commit and tool versions. Solidity dependencies are vendored and hash-checked.
The internal review additionally runs `python3 tools/mutation_check.py` and
`python3 tools/verify_upstream.py` (public network reads). Their evidence is included in the archive;
neither constitutes a third-party audit or live integration test.
The source archive is deterministic for a given set of files; test timings and gas-report logs can
change when re-run, and therefore regenerate the archive hash. This is not a hermetic OS image.

Current behavior is specified in [SPECIFICATION.md](SPECIFICATION.md); validation and its limits
are in [VALIDATION.md](VALIDATION.md). Superseded checkpoints are indexed in
[ARCHIVE_HISTORY.md](ARCHIVE_HISTORY.md).
