# Deployment and operations runbook

No live deployment is configured or authorized by the example files. They intentionally contain
zero addresses/domains; the script and preflight reject them. Never replace unknown values with
unverified guesses. Scripts do not load or print private keys.

## 1. Before deployment

For multiple selected stocks, use the [deployment bundle workflow](DEPLOYMENT_BUNDLE.md) to generate
paired configurations, record exact amount conversions and simulate each asset with the actual sender.

Complete one deployment JSON per chain from `config/deployment.example.json` and a pair file from
`config/pair.example.json`. Store reviewed real copies outside the audit archive. Verify against dated
primary sources and RPC reads:

- EVM and Wormhole IDs; Core proxy and current implementation code/provenance/governance.
- Accepted finality/consistency enum on each chain and actual Guardian support in both directions.
- Official original-token registry entry, bytecode/proxy, 18 decimals, raw transfer semantics,
  freeze/upgrade powers, multiplier API and permissionless wrapper compatibility.
- Governance account and emergency guardian. The selected policy permits one hardware-wallet EOA
  for both roles; verify control of the approved address. Nonzero addresses are required, while
  separate accounts or contract wallets remain supported. The legacy `governanceSafe` JSON field
  identifies the proposer/executor/canceller account; it does not require a Safe. If a Safe is used,
  verify its signers, threshold, and modules separately.
- Initial treasury ownership/access and ability to receive the source token. Governance can rotate
  the recipient of future fees through the timelock; this does not change the fee rate.
- Per-transfer maximum, approved receiving ceiling and metadata freshness agreed with
  risk owners. Numbers in examples are test parameters, not production recommendations.

Keep approved maxTransferRaw and inboundMaxTransferRaw equal on both endpoints. Consistency
is reciprocal: source outbound = destination inbound, and vice versa. Match origin asset address.

```sh
python3 tools/preflight.py --pair config/pair.json --config-only
```

This checks configuration coherence only. It does not contact a network or establish legal approval.

## 2. Deploy each side paused

Simulate first against the correct RPC with the selected deployer. Signing may use a named keystore,
hardware wallet, or a user-operated script that supplies a private key locally. Do not hardcode keys
in source/config, commit them, print them, or enable shell tracing around signing. Deployment and
test transactions can use a separate hot wallet; governance operations still require the configured
administrative signer and timelock. `Deploy` creates a TimelockController and one endpoint. Destination creates its
wrapped ERC20 internally. Source feeRecipient is initialized from configuration. The script never unpauses.

```sh
FOUNDRY_PROFILE=deployment DEPLOY_CONFIG=config/source.json forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SOURCE_RPC_URL" --account deployer
```

The command above is a simulation. Broadcasting is a separate operator action after checking output
and review: the same command with `--broadcast`. Do not broadcast LocalDemo. Save receipts, chain IDs,
constructor arguments, exact artifact/runtime hashes and governance addresses in the deployment record.
Verify source on the explorer using the audited compiler settings and constructor args.
A two-contract deployment is not atomic across transactions; if interrupted, reconcile receipts before
retrying to avoid confusing duplicate governors/endpoints. There is no automated resume/migration tool.

## 3. Bind and activate the initial pair without a timelock wait

The deployment script sets the selected governance account as each endpoint's one-time `bootstrapper`.
Ownership remains with the timelock from deployment; the hot deployment wallet gains no setup role.
From the hardware governance wallet, call each endpoint directly:

- Source `bootstrapSetPeer(destinationEndpoint, destinationWrappedToken)`.
- Destination `bootstrapSetPeer(sourceVault, originalSourceToken)`.

Both bindings are one-time. Verify the actual remote addresses before signing. No owner can change
them later. A mistake requires a new pair. Do not activate deposits before checking the reciprocal
binding and token identities.
Binding leaves both lanes paused. There is no scheduling transaction or 48-hour wait for these initial
calls. The hardware wallet needs native gas on each chain because it submits these transactions.

Enter reviewed runtime hashes and deployment addresses in the pair file. Run:

```sh
python3 tools/preflight.py --pair config/pair.json --phase prepared
```

It pins independent finalized blocks, validates domains, owners, peers, remote tokens, parameters,
fees, paused state, governance roles and source backing, then rechecks block hashes. It intentionally
fails if the RPC does not support the finalized tag. It does not prove a Core proxy implementation,
issuer registry membership or all historical governance-role assignments: verify these separately.
Expected runtime hashes must come from reviewed artifacts, never blindly accept current RPC bytecode.
The pair file now requires approved timelock and source-asset/destination-wrapped runtime hashes
as well as endpoint/Core hashes. The preflight rejects pending ownership transfers, missing
cancellation authority and open governance roles under the deployment script's closed-role policy.
It still does not enumerate every historical role holder or pending timelock operation: review
RoleGranted/RoleRevoked and scheduled/cancelled/executed operations from each timelock's creation.
Proxy runtime hashes do not validate implementation addresses or issuer control powers.

After all checks and the audit sign-off, call `activate()` directly on each endpoint from the hardware
governance wallet. An explicitly operator-approved mainnet pilot may precede audit sign-off; this
opens the pair publicly and does not constitute production launch approval. Complete the prepared
finalized preflight first, deliver metadata successfully before locking test assets, and preserve
all pilot receipts and VAAs. The first activation is immediate and permanently clears `bootstrapper` to zero.
Check both endpoints are active and their bootstrap authorities are cleared. Every later resumption
uses the ordinary timelocked `unpause` path; emergency pause is immediate throughout.
Any ordinary unpause, including a partial one, also closes bootstrap. Ownership nomination closes it
even if the nomination is later cancelled. Governance can explicitly call `disableBootstrap()` through
the timelock to abandon the fast path while leaving the endpoint paused. There is no way to restore it.
Initial metadata requires source outbound + destination inbound enabled. Publish and relay a snapshot,
then test one minimum-size round trip, fee payment and manual relay before widening exposure.
Start with one selected stock for the first real end-to-end test. This validates the messaging path,
not every other pair's deployment or issuer restrictions. Verify every pair's configuration; additional
asset smoke tests can use small meaningful amounts rather than a mandatory USD 10 per stock.
Incoming ceilings and outgoing maxima can change through timelock as described below.
There is no aggregate reserve/supply ceiling or shared throughput quota. Legacy configs containing
`capRaw`, `rateCapacityRaw` or `refillSeconds` are rejected by the deployment reader and preflight.
After the first metadata delivery, run `--phase active`; this phase also rejects stale wrapped metadata.

### Transfer maximum changes without pausing service

Choose the raw-token amount per stock from the approved reference value (initial target approximately
USD 100,000 equivalent per request). This is a configuration reference, not an oracle-enforced USD
cap. Record the contemporaneous, unit-correct quote, multiplier and rounding with approval.

For an increase above either existing receive ceiling:

1. Schedule `prepareInboundMaxTransfer(next)` on both endpoint timelocks where needed, and the
   subsequent `setMaxTransfer(next)` operations. Both functions are owner-only. Use local timelock
   predecessors where useful, but do not mistake them for cross-chain atomic ordering.
2. Once mature, execute the receive preparations on both chains. They do not change the current
   outgoing maximum, so old-size requests continue. Update `inboundMaxTransferRaw` in both approved
   configs and run paired `--phase active` preflight to verify the receive ceilings before increasing
   either outgoing limit. Do not activate larger requests if one preparation failed.
3. Execute both outgoing-maximum updates, set the approved `maxTransferRaw` values and rerun active
   preflight. An intermediate difference in outgoing maxima is expected during sequential execution;
   both receivers already accept the larger size, so this introduces no size-based delivery block.

If the approved incoming ceilings already cover the new amount, skip preparation. For decreases,
only update the outgoing maxima; keep incoming ceilings unchanged so earlier claims remain eligible.
Neither function requires or changes pause flags, and no capacity is consumed or recharged.
Scheduling/maturity never imposes a cooldown on ordinary user transfers. The governor starts with
at least 48 hours delay; its subsequent delay and ownership changes retain the documented trust model.

The incoming ceiling can only increase. This is a per-message acceptance ceiling, not shared capacity,
and does not expire automatically. Lowering the outgoing maximum cannot revoke earlier incoming
approvals; use immediate inbound pause for suspected fraud. Emergency pause remains available.
`--phase maintenance` is optional when operators deliberately pause outbound; it is not required for
normal limit updates. Fresh deployments initialize both maxima equally; an approved live config
with different outgoing/incoming values must be adapted before reuse as a new deployment config.

### Treasury rotation

Verify control of the replacement address and its ability to receive the original token. Schedule
`SourceVault.setFeeRecipient(next)` through the source timelock, wait its current delay, then execute.
Zero, the vault and original-token addresses are rejected. No recipient acceptance transaction is
required by the contract; independent address verification before scheduling is therefore essential.
The guardian cannot redirect fees. Deposits before execution pay the old treasury; deposits after
execution pay the new treasury. Principal and previously paid fees remain untouched.

Monitor `FeeRecipientChanged` and queued treasury changes. Keep the original deployment record;
after an approved rotation, update the operational configuration's `treasury` expectation and rerun
preflight with the appropriate paused/active phase. The approved endpoint runtime hash does not
change when this storage value changes. Do not learn an expected recipient blindly from the RPC.
Rotation is allowed while paused; a blocked treasury does not require redeploying the bridge.

## 4. User completion and retry

The production model uses two user-submitted bridge transactions and no automatic relayer service.
For Robinhood to Arc, the user calls `deposit` on the source, waits for a signed Wormhole VAA, then
calls `completeDeposit` on the destination. A separate original-token `approve` transaction may be
needed first. For Arc to Robinhood, the user calls `redeem` and then `completeRedemption`; no wrapped
allowance is required. Users pay gas on both chains and the source-side Core message fee, if any.

Completion remains permissionless: another address may deliver the same valid message, but cannot
change its recipient or amount. This capability does not imply an operated delivery service.
Retrieve the native binary signed VAA from the selected attestation service and retain the source
transaction, finalized emitter/sequence, VAA, destination transaction, and status for retry.
A UI must let users resume from a source transaction after closing the page or changing devices,
retrieve pending messages, and reconcile destination completion before offering another submission.
The repository currently provides manual preparation; the complete user-facing recovery flow is
an integration requirement, not a hosted relayer requirement.

```sh
python3 tools/prepare_relay.py --kind deposit --vaa deposit-vaa.hex \
  --endpoint "$DESTINATION_ENDPOINT" --sender "$USER_ADDRESS" \
  --rpc-env DESTINATION_RPC_URL --chain-id "$DESTINATION_EVM_CHAIN_ID"
```

Output is an **unsigned** transaction after `eth_call` and gas estimation. Sign/send with the user's
wallet after re-simulation. `--kind redemption` targets the source vault; `--kind metadata` targets
DestinationBridge. The helper never signs or transmits. The user or another willing submitter must
perform completion; Wormhole attestation does not automatically execute the destination transaction.

- Above incoming ceiling after misordered governance: reconcile receive approvals through timelock
  and retry the same VAA; do not create a second user deposit. Proper preparation avoids this case.
- Endpoint pause: investigate and resume via governance when safe; retry is conditional on the VAA's
  Guardian set still being accepted. A long pause may require replacement signatures.
- Original issuer freeze/tax behavior: investigate with issuer. Reverts do not consume the claim.
- Already consumed: confirm finalized destination event; treat as completed only after reconciliation.
- Stale metadata: publish a new snapshot; original transfers remain denominated in raw units.
- Expired Guardian set / long outage: work with Wormhole; do not fabricate attestations, force mint,
  or refund from reserves. This implementation has no privileged emergency recovery route.
  Rehearse Wormhole's [signature replacement procedure](https://wormhole.com/docs/products/messaging/tutorials/replace-signatures/)
  for this exact chain pair before launch. Preserve the original message body and emitter/sequence;
  only genuinely valid quorum signatures are acceptable. The local rotation test proves verifier
  behavior, not availability of re-observation or replacement signatures on a live network.

### Metadata refresh policy

Use `metadataMaxAgeSeconds = 2592000` (30 exact days) for the selected monthly policy. The value
is immutable for a deployed wrapped token. Both the constructor and preflight reject zero or values
above 30 days. This lifetime does not impose a minimum interval between updates.

Publish and relay a fresh observation before expiry, with an operational margin for finality,
retries, and outages. Refresh immediately on source multiplier/schedule changes or cancellation;
do not wait for the monthly deadline. An unchanged multiplier can also be republished to renew
freshness. The deadline is measured from source observation, not destination receipt. Re-delivering
a consumed or older snapshot cannot restart it. Keep timestamp-skew tolerance at five minutes.

Operators must monitor original-token changes and metadata age and arrange timely publication and
destination completion, which can both be submitted manually. No hosted keeper or automatic relayer
is selected. If nobody refreshes, stale UI getters fail closed after the deadline,
while raw ERC20 transfers and bridge mint/burn/redemption remain independent of metadata freshness.
Integrating frontends should expose raw redemption and clearly indicate unavailable display data.
The 30-day window trades fewer unchanged-state publications for longer potential display staleness
when a source update is missed.

## 5. Monitoring and incidents

Monitor finalized events and backing continuously; operators must define detection and response
SLOs before launch. There is no automatic throughput delay to provide a response window.

| Signal | Response |
| --- | --- |
| Source balance below locked | Emergency pause affected inbound/outbound, investigate issuer/transfer behavior |
| Unexplained mint/unlock or wrong emitter evidence | Pause inbound on both endpoints immediately; preserve VAAs/logs |
| Stuck transfers / Guardian/RPC outage | Stop new admissions if appropriate, keep safe exit path available, disclose pending state |
| Missing/stale multiplier | Publish/relay fresh state; disable share-equivalent quotes/UI; raw redemption continues |
| Ownership/guardian/Timelock role or delay change | Review schedule/transactions before delayed execution |
| Transfer-limit change | Verify both receiving ceilings before activating increases; update approved configs and current outgoing maxima |
| Treasury change | Verify approved replacement and update the expected recipient after execution |
| Core implementation or issuer proxy upgrade | Review compatibility; pause admissions if uncertain |
| Treasury fee-transfer failure | New deposits revert; investigate and, if needed, rotate recipient through timelock; principal already locked can still be redeemed |

Guardian `pause(1)` stops outbound initiation, `pause(2)` stops inbound execution, `pause(3)` stops both.
For ordinary maintenance stop only source outbound, preserving exits. Security incidents may require
stopping inbound despite delaying withdrawals. `unpause` is owner-only and timelocked by deployment
configuration. Neither incident response nor governance can seize backing or freeze wrapped transfers.
The delay is initially >=48h but can be reduced by a scheduled Timelock `updateDelay` call or removed
by endpoint ownership migration. An already-ready unpause can override a fresh pause immediately.
On incidents, the proposer/canceller account must inspect and cancel incompatible queued unpauses.
The selected shared hardware wallet has that cancellation role as well as immediate pause authority.
The guardian role alone does not grant timelock cancellation rights to a separately configured
guardian. Monitor delay changes and the full queue.

## 6. Frontend integration obligations

Show gross amount, 0.5% fee, net wrapped amount, gas on both chains, separate message fees, and the
two-transaction flow (plus approval when needed) before signing. Provide network switching,
attestation waiting, explicit destination completion, and a recoverable pending-transfer view. Fee is collected at source success even if remote completion is delayed.
Validate destination addresses including known endpoint/token contracts; never label a raw token as
one share. Show metadata freshness and handle UI accessor reverts. Prices are external data with
explicit units; metadata is not an oracle. Do not advertise instant cross-chain settlement or an
atomic 100% proof from unsynchronized snapshots.
