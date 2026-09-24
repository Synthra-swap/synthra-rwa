// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWormholeCore} from "./interfaces/IWormholeCore.sol";
import {BridgeMessage} from "./BridgeMessage.sol";

/// @notice Non-upgradeable, single-peer endpoint. Owner is the deployment timelock.
abstract contract WormholeEndpoint is Ownable2Step, ReentrancyGuard {
    uint8 public constant OUTBOUND = 1;
    uint8 public constant INBOUND = 2;

    struct Config {
        address core;
        uint16 localChain;
        uint16 remoteChain;
        uint256 localEvmChain;
        uint256 remoteEvmChain;
        uint8 outboundConsistency;
        uint8 inboundConsistency;
        address owner;
        address guardian;
        uint256 maxTransfer;
    }
    IWormholeCore public immutable wormhole;
    uint256 public immutable deploymentChainId;
    uint256 public immutable remoteEvmChain;
    uint16 public immutable localWormholeChain;
    uint16 public immutable remoteWormholeChain;
    uint8 public immutable outboundConsistency;
    uint8 public immutable inboundConsistency;
    uint256 public maxTransfer;
    /// @notice Largest approved incoming amount; never decreases so older claims still fit.
    uint256 public inboundMaxTransfer;
    address public guardian;
    address public peer;
    address public remoteToken;
    uint8 public pausedLanes = 3;
    mapping(bytes32 => bool) public consumedMessages;

    error InvalidConfiguration();
    error PeerAlreadySet();
    error PeerNotSet();
    error WrongEvmChain();
    error IncorrectMessageFee();
    error InvalidVAA();
    error WrongEmitter();
    error WrongConsistency();
    error MessageAlreadyConsumed();
    error InvalidMessage();
    error LanePaused(uint8 lane);
    error UnauthorizedGuardian();
    error TransferTooLarge();
    error RenunciationDisabled();
    event PeerSet(address indexed peer, uint16 indexed wormholeChain, address indexed remoteToken);
    event GuardianChanged(address indexed previous, address indexed next);
    event PauseChanged(uint8 lanes, bool paused, address indexed actor);
    event MessageConsumed(bytes32 indexed messageId, uint64 indexed sequence, uint8 indexed action);
    event InboundTransferLimitRaised(uint256 previous, uint256 next);
    event TransferLimitChanged(uint256 previous, uint256 next, uint256 inboundMaximum);

    constructor(Config memory c) Ownable(c.owner) {
        if (
            c.core.code.length == 0 || c.guardian == address(0) || c.localEvmChain != block.chainid
                || c.remoteEvmChain == 0 || c.localChain == 0 || c.remoteChain == 0
                || c.remoteChain == c.localChain || c.maxTransfer == 0
        ) revert InvalidConfiguration();
        wormhole = IWormholeCore(c.core);
        if (wormhole.chainId() != c.localChain || wormhole.evmChainId() != c.localEvmChain) {
            revert InvalidConfiguration();
        }
        localWormholeChain = c.localChain;
        remoteWormholeChain = c.remoteChain;
        deploymentChainId = c.localEvmChain;
        remoteEvmChain = c.remoteEvmChain;
        outboundConsistency = c.outboundConsistency;
        inboundConsistency = c.inboundConsistency;
        guardian = c.guardian;
        maxTransfer = c.maxTransfer;
        inboundMaxTransfer = c.maxTransfer;
    }

    function setPeer(address remotePeer, address tokenOnRemoteChain) external onlyOwner {
        if (peer != address(0)) revert PeerAlreadySet();
        if (remotePeer == address(0) || tokenOnRemoteChain == address(0) || remotePeer == tokenOnRemoteChain) revert InvalidConfiguration();
        _validateRemoteToken(tokenOnRemoteChain);
        remoteToken = tokenOnRemoteChain;
        peer = remotePeer;
        emit PeerSet(remotePeer, remoteWormholeChain, tokenOnRemoteChain);
    }

    function _validateRemoteToken(address) internal view virtual {}

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
        _validateLanes(lanes);
        _checkChainAndPeer();
        pausedLanes &= ~lanes;
        emit PauseChanged(lanes, false, msg.sender);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }

    function _validateLanes(uint8 lanes) private pure {
        if (lanes == 0 || lanes > 3) revert InvalidConfiguration();
    }

    function messageFee() public view returns (uint256) {
        return wormhole.messageFee();
    }

    function _checkChainAndPeer() internal view {
        if (block.chainid != deploymentChainId) revert WrongEvmChain();
        if (peer == address(0)) revert PeerNotSet();
    }

    function _checkLane(uint8 lane) internal view {
        _checkChainAndPeer();
        if (pausedLanes & lane != 0) revert LanePaused(lane);
    }

    function _checkOutbound(uint256 amount, address recipient) internal {
        _checkLane(OUTBOUND);
        if (amount == 0 || recipient == address(0) || recipient == peer || recipient == remoteToken) {
            revert InvalidMessage();
        }
        if (amount > maxTransfer) revert TransferTooLarge();
        if (msg.value != messageFee()) revert IncorrectMessageFee();
    }

    function _header(uint8 action, address token) internal view returns (BridgeMessage.Header memory) {
        return BridgeMessage.Header(
            BridgeMessage.DOMAIN,
            BridgeMessage.VERSION,
            action,
            deploymentChainId,
            remoteEvmChain,
            remoteWormholeChain,
            peer,
            token
        );
    }

    function _publish(uint8 action, address token, address recipient, uint256 amount)
        internal
        returns (uint64)
    {
        return wormhole.publishMessage{value: msg.value}(
            0,
            abi.encode(BridgeMessage.Transfer(_header(action, token), recipient, amount)),
            outboundConsistency
        );
    }

    function _verifyAndConsume(bytes calldata encodedVAA, uint8 action, address token, uint256 length)
        internal
        returns (IWormholeCore.VM memory message, bytes32 id)
    {
        _checkLane(INBOUND);
        bool valid;
        // The optional diagnostic string is intentionally ignored; validity is checked immediately.
        // slither-disable-next-line unused-return
        (message, valid,) = wormhole.parseAndVerifyVM(encodedVAA);
        if (!valid) revert InvalidVAA();
        if (
            message.emitterChainId != remoteWormholeChain
                || message.emitterAddress != bytes32(uint256(uint160(peer)))
        ) revert WrongEmitter();
        if (message.consistencyLevel != inboundConsistency) revert WrongConsistency();
        id = keccak256(abi.encode(message.emitterChainId, message.emitterAddress, message.sequence));
        if (consumedMessages[id]) revert MessageAlreadyConsumed();
        if (message.payload.length != length) revert InvalidMessage();
        BridgeMessage.Header memory h = abi.decode(message.payload, (BridgeMessage.Header));
        if (
            h.domain != BridgeMessage.DOMAIN || h.version != BridgeMessage.VERSION || h.action != action
                || h.sourceEvmChain != remoteEvmChain || h.destinationEvmChain != deploymentChainId
                || h.destinationChain != localWormholeChain || h.destinationBridge != address(this)
                || h.originToken != token
        ) revert InvalidMessage();
        consumedMessages[id] = true;
        emit MessageConsumed(id, message.sequence, action);
    }

    function _consume(bytes calldata encodedVAA, uint8 action, address token)
        internal
        returns (BridgeMessage.Transfer memory transfer, bytes32 id)
    {
        IWormholeCore.VM memory message;
        (message, id) = _verifyAndConsume(encodedVAA, action, token, BridgeMessage.TRANSFER_LENGTH);
        transfer = abi.decode(message.payload, (BridgeMessage.Transfer));
        if (transfer.recipient == address(0) || transfer.recipient == address(this) || transfer.amount == 0) {
            revert InvalidMessage();
        }
        if (transfer.amount > inboundMaxTransfer) revert TransferTooLarge();
    }
}
