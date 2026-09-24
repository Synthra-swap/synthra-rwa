# Trust and threat model

## Authorities

| Authority | Powers | Cannot do |
| --- | --- | --- |
| Timelock owner | One-time peer setup, pause/resume lanes, rotate emergency guardian and future fee recipient, prepare higher incoming ceilings and adjust outgoing maximum, two-step ownership migration | Change asset, Core or fee rate; mint/unlock directly; withdraw reserves; upgrade code |
| Emergency guardian | Immediately pause outbound, inbound or both | Resume, change peer, transfer funds |
| Treasury | Receive 0.5% source deposit fee | Claim any principal or donated reserves |
| User / any willing submitter | Submit VAA or publish metadata snapshot | Forge Guardian verification or redirect encoded recipient |
| Wormhole Guardian/Core authority | Establish validity of cross-chain messages | Assumed honest; compromise breaks backing guarantees |
| Original issuer | Observed token/global pause, address blocking, role-controlled burn of escrow balances, beacon upgrades and multiplier changes | Not controlled by Synthra |

This is non-custodial in the sense that Synthra has no signing/withdrawal authority over deposited
principal. It is **not trustless or censorship resistant**: pausability, issuer controls and Guardian
liveness can delay access. Wrapped ERC20 transfers themselves have no admin pause/blacklist.

Deployment scripts give ownership to a TimelockController with >=48h delay, contract governance
and emergency addresses, and no bootstrap admin. Ownership is still transferable in two steps;
a later governance-approved migration can change this topology and must trigger monitoring.
The standard TimelockController can also schedule its own `updateDelay(0)`: the current delay
applies to that change, but subsequent operations can be immediate. An already-ready unpause
can execute immediately after a new guardian pause. There is no enforced 48-hour cooldown
measured from each pause and no permanent minimum delay at the endpoint level. Tests in
`InternalAudit.t.sol` demonstrate all three cases. Any promise of permanent delay or a guardian
veto requires a different, separately reviewed governance design.
Renouncing endpoint ownership is disabled to prevent permanent loss of recovery controls.

## Safety/liveness tradeoffs

- Stop only source outbound to halt new deposits while preserving ordinary exit flows.
- Stop inbound to prevent suspected fraudulent execution. Already burned users must wait.
- No total cap or time-based throttle remains. Per-message maxima can be split across transactions;
  they do not bound aggregate damage or guarantee time for manual intervention. Guardian/Core
  compromise or a contract exploit can therefore drain reserves without a refill delay.
- Reducing `maxTransfer` affects new local requests. Previously approved incoming ceilings remain
  available to older authenticated claims. Inbound emergency pause stops suspected incoming fraud.
  Governance may raise incoming ceilings and then outgoing maxima through the timelock. These
  actions neither create backing nor authenticate messages. Prepare both receivers before increases.
- Immutable peers eliminate later governance rerouting but make initial configuration mistakes irreversible.
- Governance can redirect future fee revenue through `setFeeRecipient`; review scheduled changes.
  The change cannot transfer principal or earlier fee payments. A frozen/incompatible treasury makes
  new deposits revert atomically until a compatible recipient is selected through governance.
- No rescue function for unrelated tokens or accidental donations. Surplus stays trapped.
- A wrong recipient can lose funds. Inaccessible arbitrary addresses/contracts cannot be repaired.
  One-time peer setup binds the remote token address as well, so the known remote endpoint/token
  addresses are rejected before taking funds. Preflight verifies both bindings against the deployed pair.
- Metadata failure never blocks raw ERC20 transfer/redemption. UI values fail closed once stale.
- Fee is earned on source initiation, not remote completion; this must be visible before signing.
- Users submit the destination completion themselves; no automatic relayer is planned. A user who
  does not retrieve and submit the VAA leaves the transfer pending. Another address may deliver it,
  but this is not guaranteed. The UI must support resuming pending transfers and show gas on both chains.

## Attacks covered by code/tests

Forged/unsigned/tampered VAAs; insufficient, wrong or expired Guardian sets; replay with alternative
quorum/hash; wrong source/destination domains, peer, asset, action or version; noncanonical payload
length; unauthorized mint/burn; malicious token reentry; fee-on-transfer; issuer freeze; backing
shortfall; failed Core publication; immediate fee-transfer failure; unauthorized limit changes;
reordered delivery and metadata; scheduled split cancellation; stale snapshots; unauthorized pause/
resume; premature timelock execution; invalid deployment parameters.

## Residual assumptions / required external evidence

1. Identify the official token deployment, non-rebasing raw behavior, issuer upgrade/freeze powers,
   escrow compatibility, redemption rights and economic treatment of all corporate actions.
2. Verify live Core proxy/implementation/governance, Wormhole IDs, finality enums and supported
   Guardian observation for **both** chains. Presence of a contract alone is insufficient.
3. Confirm network timestamps, consistency policy and price-feed unit conventions.
4. Validate permissionless wrapper distribution against issuer terms. No on-chain allowlist is
   required by this code; that does not establish permission under the underlying product terms.
5. Obtain an independent audit, resolve findings, rehearse real-network round trips with test assets,
   and define monitored limits before funding mainnet.
6. Maintain RPC, attestation retrieval and public manual relay instructions. Core guardian expiry or
   long outages can require protocol-level recovery unavailable to these immutable contracts.

These are deployment gates, not invented assumptions of completed verification.

Real-token fork tests now reproduce issuer interference; see `INTEGRATION_REVIEW.md`.
A reserve burn invalidates the honest-issuer solvency assumption. Failed releases preserve the claim,
but neither governance nor retries can recreate missing original collateral.
