# Selected LayerZero verification policy

The owner selected the standard LayerZero ULN security model on 2026-09-25. It supersedes the
provisional five-minute wait and the later additional Ethereum-finality requirement.

| Route | Source send confirmations | Destination receive confirmations | Required DVNs |
| --- | ---: | ---: | --- |
| Robinhood to Arc | 15 | 15 | LayerZero Labs and Nethermind |
| Arc to Robinhood | 15 | 15 | LayerZero Labs and Nethermind |

Values are explicitly pinned in `config/layerzero.robinhood.example.json` and
`config/layerzero.arc.example.json`. Optional DVNs are disabled. Use the selected operators' addresses
for the relevant chain from the reviewed network registry; do not inherit the default verifier set.
Both operators must attest. Either worker being unavailable can delay completion.

## Basis for the choice

The public SendUln302 and ReceiveUln302 contracts exposed five-confirmation defaults on both
pathways at the recorded blocks. Read-only evidence, including chain IDs, block hashes, library
addresses and returned configurations, is in
`audit/layerzero/layerzero-default-confirmations-20260925.json`.

LayerZero's production guidance describes 15–30 confirmations as a typical floor for optimistic
L2s, recommends independent required DVNs, and says to pin symmetric values explicitly. We choose
15 in both directions: above the observed defaults, within the optimistic-L2 guidance, and matching
the successful message-only pilot and real-contract local fork tests. Fifteen on Arc retains the
tested setting with a margin above the observed five-confirmation default. This is our application's
configuration choice, not a route-specific certification or audit by LayerZero.

## When a transfer becomes completable

Complete as soon as both required DVNs have attested the authentic packet at the required depth,
ULN/Endpoint verification succeeds, and normal application checks pass. No additional elapsed-time
wait, parent-chain `finalized` RPC gate or separate operator policy approval is required by this
selected model. A user's manual completion transaction is still necessary. Prior nonce commitments
may need batch/checkpoint recovery; paused or failed asset claims remain pending and retryable.

A confirmation count is not an Ethereum-finality proof or a guaranteed latency. DVN observation,
attestation submission, prerequisite messages, destination execution and the user's timing affect
completion. Source reorganization, verifier compromise and availability remain trust assumptions.
The observed head-gap averages do not set production timers. Do not describe a verified packet as
independently proven Ethereum-finalized or advertise a guaranteed few-second end-to-end transfer.

## Release boundary

The selected counts and two-DVN configuration are deployed on all twelve mainnet pairs. Runtime,
ownership, peers and effective ULN settings were verified after activation;
see [the deployment registry](../config/layerzero.mainnet.json). Independent audit and review of the
complete release evidence remain outstanding. The existing Wormhole endpoints and claims are unchanged.

The declarative `config/layerzero.finality-policy.example.json` records this decision. DeployLayerZero
reads numeric settings from the per-side deployment JSON. Configuration compatibility alone never
grants production approval, and the existing contract suite is not a substitute for an external audit.

## References

- [LayerZero production DVN and confirmation guidance](https://docs.layerzero.network/v2/concepts/modular-security/production-dvn-configuration)
- [LayerZero send/receive configuration](https://docs.layerzero.network/v2/developers/evm/configuration/dvn-executor-config)
