// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LayerZeroMessage as Message} from "./LayerZeroMessage.sol";
import {
    ILayerZeroEndpoint,
    ILayerZeroUln,
    Origin,
    MessagingParams,
    MessagingReceipt,
    SetConfigParam,
    UlnConfig
} from "./ILayerZero.sol";

/// @notice Non-upgradeable single-peer bridge with explicit two-required-DVN security.
/// @dev Libraries, DVNs and confirmations are immutable. No external Endpoint delegate exists.
abstract contract LayerZeroEndpoint is Ownable2Step, ReentrancyGuard {
    uint8 public constant OUTBOUND = 1;
    uint8 public constant INBOUND = 2;

    struct Config {
        address endpoint;
        uint32 localEid;
        uint32 remoteEid;
        uint256 localEvmChain;
        uint256 remoteEvmChain;
        address sendLibrary;
        address receiveLibrary;
        address dvnA;
        address dvnB;
        uint64 sendConfirmations;
        uint64 receiveConfirmations;
        address owner;
        address guardian;
        uint256 maxTransfer;
        address bootstrapper;
    }

    /// @notice Proof commitment only: no recipient, amount or execution authority.
    struct Verification {
        uint64 nonce;
        bytes32 payloadHash;
    }
    ILayerZeroEndpoint public immutable endpoint;
    address public immutable sendLibrary;
    address public immutable receiveLibrary;
    address public immutable dvnA;
    address public immutable dvnB;
    uint64 public immutable sendConfirmations;
    uint64 public immutable receiveConfirmations;
    uint32 public immutable localEid;
    uint32 public immutable remoteEid;
    uint256 public immutable deploymentChainId;
    uint256 public immutable remoteEvmChain;
    uint256 public maxTransfer;
    uint256 public inboundMaxTransfer;
    address public guardian;
    address public bootstrapper;
    address public peer;
    address public remoteToken;
    uint8 public pausedLanes = 3;
    mapping(bytes32 => bool) public consumedMessages;
    /// @notice Authenticated packets moved out of the protocol queue, still owed by this application.
    mapping(bytes32 => bytes32) public checkpointedPayloads;

    error InvalidConfiguration();
    error PeerAlreadySet();
    error PeerNotSet();
    error WrongEvmChain();
    error OnlyEndpoint();
    error WrongEmitter();
    error MessageAlreadyConsumed();
    error InvalidMessage();
    error LanePaused(uint8 lane);
    error UnauthorizedGuardian();
    error UnauthorizedBootstrapper();
    error TransferTooLarge();
    error RenunciationDisabled();
    event PeerSet(address indexed peer, uint32 indexed remoteEid, address indexed remoteToken);
    event GuardianChanged(address indexed previous, address indexed next);
    event BootstrapClosed(address indexed previousBootstrapper);
    event PauseChanged(uint8 lanes, bool paused, address indexed actor);
    event MessageConsumed(bytes32 indexed guid, uint64 indexed nonce, uint8 indexed action);
    event MessageCheckpointed(bytes32 indexed guid, uint64 indexed nonce, bytes message);
    event MessageSent(bytes32 indexed guid, uint64 indexed nonce, bytes message);
    event InboundTransferLimitRaised(uint256 previous, uint256 next);
    event TransferLimitChanged(uint256 previous, uint256 next, uint256 inboundMaximum);

    constructor(Config memory c) Ownable(c.owner) {
        if (
            c.endpoint.code.length == 0 || c.sendLibrary.code.length == 0 || c.receiveLibrary.code.length == 0
                || c.sendLibrary == c.receiveLibrary || c.dvnA.code.length == 0 || c.dvnB.code.length == 0
                || c.dvnA == c.dvnB || c.guardian == address(0) || c.localEvmChain != block.chainid
                || c.remoteEvmChain == 0 || c.remoteEvmChain == c.localEvmChain || c.localEid == 0
                || c.remoteEid == 0 || c.remoteEid == c.localEid || c.maxTransfer == 0
                || c.sendConfirmations == 0 || c.receiveConfirmations == 0
                || c.sendConfirmations == type(uint64).max || c.receiveConfirmations == type(uint64).max
        ) revert InvalidConfiguration();
        endpoint = ILayerZeroEndpoint(c.endpoint);
        if (endpoint.eid() != c.localEid) revert InvalidConfiguration();
        localEid = c.localEid;
        remoteEid = c.remoteEid;
        deploymentChainId = c.localEvmChain;
        remoteEvmChain = c.remoteEvmChain;
        sendLibrary = c.sendLibrary;
        receiveLibrary = c.receiveLibrary;
        dvnA = c.dvnA;
        dvnB = c.dvnB;
        sendConfirmations = c.sendConfirmations;
        receiveConfirmations = c.receiveConfirmations;
        guardian = c.guardian;
        bootstrapper = c.bootstrapper;
        maxTransfer = c.maxTransfer;
        inboundMaxTransfer = c.maxTransfer;
        _configure(c);
    }

    function _configure(Config memory c) private {
        address[] memory dvns = new address[](2);
        (dvns[0], dvns[1]) = c.dvnA < c.dvnB ? (c.dvnA, c.dvnB) : (c.dvnB, c.dvnA);
        endpoint.setSendLibrary(address(this), c.remoteEid, c.sendLibrary);
        endpoint.setReceiveLibrary(address(this), c.remoteEid, c.receiveLibrary, 0);
        SetConfigParam[] memory outgoing = new SetConfigParam[](2);
        outgoing[0] = SetConfigParam(
            c.remoteEid, 2, abi.encode(UlnConfig(c.sendConfirmations, 2, 255, 0, dvns, new address[](0)))
        );
        // No automatic execution job: this OApp is a zero-fee executor; users deliver manually.
        outgoing[1] =
            SetConfigParam(c.remoteEid, 1, abi.encode(uint32(Message.METADATA_LENGTH), address(this)));
        endpoint.setConfig(address(this), c.sendLibrary, outgoing);
        SetConfigParam[] memory incoming = new SetConfigParam[](1);
        incoming[0] = SetConfigParam(
            c.remoteEid, 2, abi.encode(UlnConfig(c.receiveConfirmations, 2, 255, 0, dvns, new address[](0)))
        );
        endpoint.setConfig(address(this), c.receiveLibrary, incoming);
    }

    function setPeer(address remotePeer, address tokenOnRemoteChain) external onlyOwner {
        _setPeer(remotePeer, tokenOnRemoteChain);
    }

    /// @notice Bind the initial peer without a delay. Does not enable either transfer lane.
    function bootstrapSetPeer(address remotePeer, address tokenOnRemoteChain) external {
        _checkBootstrapper();
        _setPeer(remotePeer, tokenOnRemoteChain);
    }

    function _setPeer(address remotePeer, address tokenOnRemoteChain) private {
        if (peer != address(0)) revert PeerAlreadySet();
        if (remotePeer == address(0) || tokenOnRemoteChain == address(0) || remotePeer == tokenOnRemoteChain) revert InvalidConfiguration();
        _validateRemoteToken(tokenOnRemoteChain);
        remoteToken = tokenOnRemoteChain;
        peer = remotePeer;
        emit PeerSet(remotePeer, remoteEid, tokenOnRemoteChain);
    }

    function _validateRemoteToken(address) internal view virtual {}

    /// @notice First activation only. The fast setup authority cannot be restored afterward.
    function activate() external {
        _checkBootstrapper();
        _unpause(OUTBOUND | INBOUND);
    }

    /// @notice Governance may abandon fast setup and retain the ordinary timelocked path.
    function disableBootstrap() external onlyOwner {
        _closeBootstrap();
    }

    function _checkBootstrapper() private view {
        if (bootstrapper == address(0) || msg.sender != bootstrapper) revert UnauthorizedBootstrapper();
    }

    function _closeBootstrap() private {
        address previous = bootstrapper;
        if (previous != address(0)) {
            bootstrapper = address(0);
            emit BootstrapClosed(previous);
        }
    }

    /// @dev Ownership migration must not leave an earlier administrator's setup permission alive.
    function transferOwnership(address newOwner) public override onlyOwner {
        _closeBootstrap();
        super.transferOwnership(newOwner);
    }

    function setGuardian(address next) external onlyOwner {
        if (next == address(0)) revert InvalidConfiguration();
        emit GuardianChanged(guardian, next);
        guardian = next;
    }

    /// @notice Prepare a higher receive ceiling before raising the outgoing maximum on the peer.
    /// @dev Timelock only. Never decreases: existing authenticated claims retain their eligibility.
    function prepareInboundMaxTransfer(uint256 next) external onlyOwner nonReentrant {
        if (next <= inboundMaxTransfer) revert InvalidConfiguration();
        uint256 previous = inboundMaxTransfer;
        inboundMaxTransfer = next;
        emit InboundTransferLimitRaised(previous, next);
    }

    /// @notice Change the maximum for new outgoing requests without pausing transfers.
    /// @dev Prepare and verify both incoming ceilings before activating a larger paired maximum.
    function setMaxTransfer(uint256 next) external onlyOwner nonReentrant {
        if (next == 0 || next > inboundMaxTransfer) revert InvalidConfiguration();
        uint256 previous = maxTransfer;
        maxTransfer = next;
        emit TransferLimitChanged(previous, next, inboundMaxTransfer);
    }

    /// @notice Guardian may only stop lanes. Only governance can resume, through its timelock.
    function pause(uint8 lanes) external {
        if (msg.sender != guardian && msg.sender != owner()) revert UnauthorizedGuardian();
        _validateLanes(lanes);
        pausedLanes |= lanes;
        emit PauseChanged(lanes, true, msg.sender);
    }

    function unpause(uint8 lanes) external onlyOwner {
        _unpause(lanes);
    }

    function _unpause(uint8 lanes) private {
        _validateLanes(lanes);
        _checkChainAndPeer();
        // Also consumed by a partial or ordinary timelocked unpause: no later pause bypass.
        _closeBootstrap();
        pausedLanes &= ~lanes;
        emit PauseChanged(lanes, false, msg.sender);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }

    function _validateLanes(uint8 lanes) private pure {
        if (lanes == 0 || lanes > 3) revert InvalidConfiguration();
    }

    function _checkChainAndPeer() internal view {
        if (block.chainid != deploymentChainId) revert WrongEvmChain();
        if (peer == address(0)) revert PeerNotSet();
    }

    function _checkLane(uint8 lane) internal view {
        _checkChainAndPeer();
        if (pausedLanes & lane != 0) revert LanePaused(lane);
    }

    function _checkOutbound(uint256 amount, address recipient) internal view {
        _checkLane(OUTBOUND);
        if (amount == 0 || recipient == address(0) || recipient == peer || recipient == remoteToken) {
            revert InvalidMessage();
        }
        if (amount > maxTransfer) revert TransferTooLarge();
    }

    function _header(uint8 action, address token) internal view returns (Message.Header memory) {
        return Message.Header(
            Message.DOMAIN, Message.VERSION, action, deploymentChainId, remoteEvmChain, remoteEid, peer, token
        );
    }

    function _params(bytes memory message) private view returns (MessagingParams memory) {
        _checkChainAndPeer();
        return MessagingParams(remoteEid, bytes32(uint256(uint160(peer))), message, hex"0003", false);
    }

    function _quote(bytes memory message) internal view returns (uint256) {
        return endpoint.quote(_params(message), address(this)).nativeFee;
    }

    function _send(bytes memory message) internal returns (MessagingReceipt memory receipt) {
        // Endpoint charges its current quote, refunds any surplus directly to the initiating caller.
        receipt = endpoint.send{value: msg.value}(_params(message), msg.sender);
        emit MessageSent(receipt.guid, receipt.nonce, message);
    }

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return block.chainid == deploymentChainId && peer != address(0) && origin.srcEid == remoteEid
            && origin.sender == bytes32(uint256(uint160(peer)));
    }

    /// @notice Unordered application delivery. Endpoint still requires every preceding nonce to be verified.
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function _checkOrigin(Origin memory origin) private view {
        _checkChainAndPeer();
        if (origin.srcEid != remoteEid || origin.sender != bytes32(uint256(uint160(peer)))) {
            revert WrongEmitter();
        }
        if (origin.nonce == 0) revert InvalidMessage();
    }

    function packetHeader(Origin memory origin) public view returns (bytes memory) {
        _checkOrigin(origin);
        return abi.encodePacked(
            uint8(1),
            origin.nonce,
            origin.srcEid,
            origin.sender,
            localEid,
            bytes32(uint256(uint160(address(this))))
        );
    }

    function _checkGuid(Origin calldata origin, bytes32 guid) private view {
        if (
            guid
                != keccak256(
                    abi.encodePacked(
                        origin.nonce,
                        origin.srcEid,
                        origin.sender,
                        localEid,
                        bytes32(uint256(uint160(address(this))))
                    )
                )
        ) revert InvalidMessage();
        if (consumedMessages[guid]) revert MessageAlreadyConsumed();
    }

    /// @notice Anyone may commit the exact DVN-authenticated packet and execute it in one transaction.
    /// @dev Deliberately not nonReentrant: Endpoint calls the guarded lzReceive synchronously.
    /// The wrapper has no accounting effects; all asset effects occur inside that guarded callback.
    function complete(Origin calldata origin, bytes32 guid, bytes calldata message) public {
        _checkLane(INBOUND);
        bytes memory header = packetHeader(origin);
        _checkGuid(origin, guid);
        bytes32 payloadHash = keccak256(abi.encodePacked(guid, message));
        if (checkpointedPayloads[guid] != bytes32(0)) {
            this.executeCheckpointed(origin, guid, message);
            return;
        }
        if (
            endpoint.inboundPayloadHash(address(this), origin.srcEid, origin.sender, origin.nonce)
                != payloadHash
        ) {
            ILayerZeroUln(receiveLibrary).commitVerification(header, payloadHash);
        }
        endpoint.lzReceive(origin, address(this), guid, message, "");
    }

    /// @notice Register DVN-verified packets without executing their asset or metadata effects.
    /// @dev Useful for earlier nonces whose owners have not completed. May be called while paused;
    /// verification does not authorize execution through a paused lane or consume any application claim.
    function commitVerifications(Verification[] calldata verifications) external {
        _checkChainAndPeer();
        _commitVerifications(verifications);
    }

    /// @notice Fill verified predecessor gaps and complete only the caller-selected packet, atomically.
    /// @dev All preceding nonces must still be verified by both DVNs; missing attestations cannot be skipped.
    function completeWithVerifications(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        Verification[] calldata verifications
    ) external {
        _checkLane(INBOUND);
        _commitVerifications(verifications);
        // Reuse the same authenticated delivery path; calling externally would change no authority,
        // but the public internal call avoids an unnecessary call frame.
        complete(origin, guid, message);
    }

    function _commitVerifications(Verification[] calldata verifications) private {
        for (uint256 i; i < verifications.length; ++i) {
            Verification calldata v = verifications[i];
            Origin memory origin = Origin(remoteEid, bytes32(uint256(uint160(peer))), v.nonce);
            bytes memory header = packetHeader(origin);
            if (v.payloadHash == bytes32(0) || v.payloadHash == bytes32(type(uint256).max)) {
                revert InvalidMessage();
            }
            bytes32 guid = keccak256(
                abi.encodePacked(
                    v.nonce, remoteEid, origin.sender, localEid, bytes32(uint256(uint160(address(this))))
                )
            );
            // Another user may have completed or committed this predecessor since calldata was prepared.
            if (consumedMessages[guid] || checkpointedPayloads[guid] != bytes32(0)) continue;
            if (
                endpoint.inboundPayloadHash(address(this), remoteEid, origin.sender, v.nonce) != v.payloadHash
            ) {
                ILayerZeroUln(receiveLibrary).commitVerification(header, v.payloadHash);
            }
        }
    }

    /// @notice Advance the protocol queue without executing a potentially blocked asset transfer.
    /// @dev No message is skipped or discarded: Endpoint.clear verifies the exact authenticated payload,
    /// and its hash remains stored here until successful application execution. Anyone can checkpoint
    /// intermediate nonces to keep backlog traversal within a transaction's gas limit, even while paused.
    function checkpoint(Origin calldata origin, bytes32 guid, bytes calldata message) external nonReentrant {
        bytes memory header = packetHeader(origin);
        _checkGuid(origin, guid);
        bytes32 hash = keccak256(abi.encodePacked(guid, message));
        bytes32 saved = checkpointedPayloads[guid];
        if (saved != bytes32(0)) {
            if (saved != hash) revert InvalidMessage();
            return;
        }
        checkpointedPayloads[guid] = hash;
        if (endpoint.inboundPayloadHash(address(this), origin.srcEid, origin.sender, origin.nonce) != hash) {
            ILayerZeroUln(receiveLibrary).commitVerification(header, hash);
        }
        endpoint.clear(address(this), origin, guid, message);
        emit MessageCheckpointed(guid, origin.nonce, message);
    }

    /// @notice Execute an exact, previously checkpointed claim. All normal pause and asset checks apply.
    function executeCheckpointed(Origin calldata origin, bytes32 guid, bytes calldata message)
        external
        nonReentrant
    {
        _checkLane(INBOUND);
        _checkOrigin(origin);
        _checkGuid(origin, guid);
        if (checkpointedPayloads[guid] != keccak256(abi.encodePacked(guid, message))) {
            revert InvalidMessage();
        }
        delete checkpointedPayloads[guid];
        consumedMessages[guid] = true;
        _receiveMessage(origin.nonce, guid, message);
    }

    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        _checkLane(INBOUND);
        _checkOrigin(origin);
        _checkGuid(origin, guid);
        if (msg.value != 0) revert InvalidMessage();
        consumedMessages[guid] = true;
        _receiveMessage(origin.nonce, guid, message);
    }

    function _validateMessage(bytes calldata message, uint8 action, address token, uint256 length)
        internal
        view
    {
        if (message.length != length) revert InvalidMessage();
        Message.Header memory h = abi.decode(message, (Message.Header));
        if (
            h.domain != Message.DOMAIN || h.version != Message.VERSION || h.action != action
                || h.sourceEvmChain != remoteEvmChain || h.destinationEvmChain != deploymentChainId
                || h.destinationChain != localEid || h.destinationBridge != address(this)
                || h.originToken != token
        ) revert InvalidMessage();
    }

    function _transfer(bytes calldata message, uint8 action, address token)
        internal
        view
        returns (Message.Transfer memory t)
    {
        _validateMessage(message, action, token, Message.TRANSFER_LENGTH);
        t = abi.decode(message, (Message.Transfer));
        if (t.recipient == address(0) || t.recipient == address(this) || t.amount == 0) {
            revert InvalidMessage();
        }
        if (t.amount > inboundMaxTransfer) revert TransferTooLarge();
    }
    function _receiveMessage(uint64 nonce, bytes32 guid, bytes calldata message) internal virtual;

    // ILayerZeroExecutor ABI: no off-chain executor job, no execution fee, no privileged effect.
    function getFee(uint32, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function assignJob(uint32, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}
