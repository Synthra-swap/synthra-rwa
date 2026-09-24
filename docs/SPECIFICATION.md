# Protocol specification

All transfer amounts are unsigned **raw token units** with 18 decimals. They are not share counts.
The source asset address is an immutable allowlisted asset by construction; there is no ticker lookup
or user-supplied asset registration. User addresses are unrestricted.

## Deposit and fee

For gross amount G > 0:

- F = floor(G * 50 / 10000), N = G - F.
- Check the per-transfer maximum against G; there is no shared capacity or refill.
- Transfer G original tokens from caller to vault, checking exact received balance delta.
- Increase locked by N; transfer F immediately to the current feeRecipient, checking both exact
  vault debit and recipient credit. For F = 0, no fee transfer/event occurs.
- Publish a DEPOSIT message for N to the chosen destination recipient.

All steps are one local transaction. A fee-transfer failure, Core publication failure or other revert
undoes the deposit, fee, accounting and allowance spending. A later failure or delay
on the other chain does **not** refund the fee. Fee is collected on successful source initiation.
Governance may call `setFeeRecipient(next)` through the endpoint owner (the deployment timelock).
Zero, the vault itself and the original token address are rejected. The change emits
`FeeRecipientChanged(previous,next)` and affects deposits initiated after execution, including when
the vault is currently paused. It does not move existing reserves or previously paid fees, change
the fee rate, or alter pending cross-chain claims. Rotation cannot occur during a guarded transfer.
Recipient ownership and issuer transfer eligibility must be checked operationally before scheduling.

Tiny deposits below 200 raw units pay zero after rounding; splitting can save less than one raw unit
per deposit. Native message fees and gas are separate. No commercial fee applies to redemption.

## Mint / burn / redemption

Anyone may deliver a valid deposit VAA. Validate envelope and payload, enforce the approved
inbound maximum, and mint N wrapped to the encoded recipient.

`redeem(A, sourceRecipient)` burns A from **msg.sender** only and publishes REDEEM. There is no
allowance-based burn of other holders. Check the outgoing maximum against A. Anyone can deliver
the resulting VAA to the vault: check its incoming ceiling, reduce locked and transfer A
original tokens to the signed recipient, verifying exact balance deltas.

Consumed-message writes revert if mint or transfer fails. No timeout refunds,
manual reserve recovery or administrative message cancellation exist: unilateral refunds would
permit a later mint against released collateral. Frozen originals can make exits wait indefinitely.

## Message wire format

Wormhole Core validates the native binary VAA. Local code decodes **only its verified payload**.
Header fields, in ABI order:

| Field | Type / condition |
| --- | --- |
| domain | bytes32, keccak256("synthra.rwa.bridge.v1") |
| version | uint8, 1 |
| action | uint8: 1 deposit, 2 redeem, 3 metadata |
| sourceEvmChain | uint256, remoteEvmChain |
| destinationEvmChain | uint256, deploymentChainId |
| destinationChain | uint16, local Wormhole ID |
| destinationBridge | address, receiving endpoint |
| originToken | address, original source token |

Transfers append `address recipient, uint256 amount`: exactly 320 bytes.
Metadata appends `uint256 observedAt, uint256 current, uint256 next, uint256 effectiveAt`:
exactly 384 bytes. Extra trailing data and truncated payloads are rejected. The prototype wire
format from before this candidate is not compatible; no production deployment used it.

Envelope must have remoteWormholeChain, padded remote peer address and exact configured
inbound consistency enum. Consistency numbers are not an ordered security scale. Replay identity:
`keccak256(abi.encode(emitterChainId, emitterAddress, sequence))`. Guardian re-signing/alternative
quorums do not change this identity. No expiry is imposed on transfer payloads by the bridge;
Core guardian-set expiry can still make a stale attestation unusable.

## Accounting and per-transfer limits

Under honest finality and valid attestations, for a causally consistent cut of both chains:

`locked = totalSupply + pendingNetDeposits + pendingRedemptions`

`sourceToken.balanceOf(vault) >= locked` (surplus may be unsolicited donations).
The sum paid to all fee recipients over time equals the sum of F for successful source deposits.
Fees are not collateral; changing the recipient does not reassign earlier payments.
At full delivery, locked = supply. Separate wall-clock snapshots must not be presented as an
atomic proof; the event indexer needs finalized events and their corresponding consumptions.

There is no configured total cap, shared throughput allowance, cooldown or refill. Many users may
initiate and complete eligible messages in the same block without consuming each other's allowance.
Maximum amounts use raw token units, not a USD oracle. Splitting an amount into multiple requests
is allowed and means the maximum is not a bound on aggregate flow or losses.

`maxTransfer` bounds new outgoing deposits (gross amount) and burns. `inboundMaxTransfer` bounds
authenticated incoming completions and starts equal to the initial outgoing maximum.
`prepareInboundMaxTransfer(next)` is owner-only and nonReentrant and requires `next` strictly greater
than the existing incoming ceiling. It emits `InboundTransferLimitRaised(previous,next)`. The
ceiling never decreases, preserving older claims, and does not by itself allow larger local sends.

`setMaxTransfer(next)` is owner-only and nonReentrant and requires `0 < next <= inboundMaxTransfer`.
It emits `TransferLimitChanged(previous,next,inboundMaximum)` and changes only the outgoing maximum.
Neither operation pauses or resumes any lane, changes accounting, or requires a paused lane. The
intended owner is the existing deployment timelock. There is no protocol amount ceiling other than
uint256 representation and the chosen per-message settings.

For an increase, prepare and verify receive ceilings on BOTH endpoints before activating larger
outgoing maxima. The contracts cannot inspect remote live state; wrong operational ordering may
still delay a claim until the remote ceiling is corrected. For decreases, update outgoing maxima;
incoming ceilings retain earlier approvals with no automatic expiry. Lowering outgoing policy does
not revoke an earlier incoming approval; use the guardian's emergency inbound pause for incidents.

Paired approved maxima are checked by preflight; fresh deployment requires equal incoming/outgoing
values. A normal two-stage update can be checked with the active preflight while users continue
transferring. No waiting window is imposed on users by these administrative operations.

## Multiplier snapshots

A permissionless keeper calls `publishMetadata`, paying the Core message fee. The source reads
uiMultiplier/newUIMultiplier/effectiveAt directly from the original. If no future schedule exists,
it normalizes next=current and effectiveAt=0. No caller can submit arbitrary multiplier values.

Destination verifies the METADATA VAA before passing its emitter sequence to WrappedAsset.
Only later sequences replace current state. Older authenticated snapshots are consumed but ignored.
A replacement can supersede or cancel a pending schedule. Observed timestamp must not decrease,
must be no more than 5 minutes in the future and no older than configured metadataMaxAge.
Current and next must be positive; a future schedule must be after the observation time.

Raw ERC20 balances, supply, allowances and burn/redeem are independent from snapshots.
UI accessors and conversions revert before the first snapshot or when stale. `snapshot()` remains
readable for monitoring. This is an intentional fail-closed deviation from the happy-path behavior
of ERC-8056 UI consumers, which must handle reverts and check metadataFresh. ERC-8056 is a draft.
A source cancellation cannot be known before its message arrives; a schedule may temporarily be
wrong within the freshness bound. These values are **not a price oracle**. No double application
to an already multiplier-adjusted price is permitted in an integrating frontend.
