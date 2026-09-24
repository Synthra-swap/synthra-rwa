// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {WormholeEndpoint} from "./WormholeEndpoint.sol";
import {BridgeMessage} from "./BridgeMessage.sol";
import {WrappedAsset} from "./WrappedAsset.sol";
import {IWormholeCore} from "./interfaces/IWormholeCore.sol";

contract DestinationBridge is WormholeEndpoint {
    address public immutable originToken;
    WrappedAsset public immutable wrappedAsset;
    event Minted(bytes32 indexed messageId, address indexed recipient, uint256 amount);
    event RedemptionRequested(
        uint64 indexed sequence, address indexed holder, address indexed recipient, uint256 amount
    );

    constructor(
        Config memory c,
        address sourceToken,
        string memory name_,
        string memory symbol_,
        uint256 maxAge
    ) WormholeEndpoint(c) {
        if (sourceToken == address(0)) {
            revert InvalidConfiguration();
        }
        originToken = sourceToken;
        wrappedAsset = new WrappedAsset(name_, symbol_, c.remoteChain, sourceToken, maxAge);
    }

    function _validateRemoteToken(address token) internal view override {
        if (token != originToken) revert InvalidConfiguration();
    }

    function completeDeposit(bytes calldata encodedVAA) external nonReentrant {
        (BridgeMessage.Transfer memory t, bytes32 id) =
            _consume(encodedVAA, BridgeMessage.DEPOSIT, originToken);
        if (t.recipient == address(wrappedAsset)) revert InvalidMessage();
        wrappedAsset.bridgeMint(t.recipient, t.amount);
        emit Minted(id, t.recipient, t.amount);
    }

    function redeem(uint256 amount, address recipient)
        external
        payable
        nonReentrant
        returns (uint64 sequence)
    {
        _checkOutbound(amount, recipient);
        if (recipient == originToken) revert InvalidMessage();
        wrappedAsset.bridgeBurn(msg.sender, amount);
        sequence = _publish(BridgeMessage.REDEEM, originToken, recipient, amount);
        emit RedemptionRequested(sequence, msg.sender, recipient, amount);
    }

    function completeMetadata(bytes calldata encodedVAA) external nonReentrant returns (bool applied) {
        (IWormholeCore.VM memory message,) =
            _verifyAndConsume(encodedVAA, BridgeMessage.METADATA, originToken, BridgeMessage.METADATA_LENGTH);
        BridgeMessage.Metadata memory m = abi.decode(message.payload, (BridgeMessage.Metadata));
        return wrappedAsset.applySnapshot(message.sequence, m.observedAt, m.current, m.next, m.effectiveAt);
    }
}
