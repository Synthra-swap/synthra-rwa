// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LayerZeroEndpoint} from "./LayerZeroEndpoint.sol";
import {LayerZeroMessage as Message} from "./LayerZeroMessage.sol";
import {LayerZeroWrappedAsset} from "./LayerZeroWrappedAsset.sol";
import {MessagingReceipt} from "./ILayerZero.sol";

/// @notice Raw-unit mint/burn representation. Only the authenticated source vault may mint or update metadata.
contract LayerZeroDestinationBridge is LayerZeroEndpoint {
    address public immutable originToken;
    LayerZeroWrappedAsset public immutable wrappedAsset;
    event MetadataReceived(bytes32 indexed guid, uint64 indexed nonce, bool applied);
    event Minted(bytes32 indexed guid, address indexed recipient, uint256 amount);
    event RedemptionRequested(
        uint64 indexed nonce, address indexed holder, address indexed recipient, uint256 amount
    );

    constructor(
        Config memory c,
        address sourceToken,
        string memory name_,
        string memory symbol_,
        uint256 maxAge
    ) LayerZeroEndpoint(c) {
        if (sourceToken == address(0)) revert InvalidConfiguration();
        originToken = sourceToken;
        wrappedAsset = new LayerZeroWrappedAsset(name_, symbol_, c.remoteEid, sourceToken, maxAge);
    }

    function _validateRemoteToken(address token) internal view override {
        if (token != originToken) revert InvalidConfiguration();
    }

    function _redemption(uint256 amount, address recipient) private view returns (bytes memory) {
        _checkOutbound(amount, recipient);
        return abi.encode(Message.Transfer(_header(Message.REDEEM, originToken), recipient, amount));
    }

    function quoteRedeemFee(uint256 amount, address recipient) external view returns (uint256) {
        return _quote(_redemption(amount, recipient));
    }

    function redeem(uint256 amount, address recipient)
        external
        payable
        nonReentrant
        returns (MessagingReceipt memory receipt)
    {
        bytes memory message = _redemption(amount, recipient);
        wrappedAsset.bridgeBurn(msg.sender, amount);
        receipt = _send(message);
        emit RedemptionRequested(receipt.nonce, msg.sender, recipient, amount);
    }

    function _receiveMessage(uint64 nonce, bytes32 guid, bytes calldata message) internal override {
        if (message.length < 256) revert InvalidMessage();
        Message.Header memory h = abi.decode(message, (Message.Header));
        if (h.action == Message.DEPOSIT) {
            Message.Transfer memory t = _transfer(message, Message.DEPOSIT, originToken);
            if (t.recipient == address(wrappedAsset)) revert InvalidMessage();
            wrappedAsset.bridgeMint(t.recipient, t.amount);
            emit Minted(guid, t.recipient, t.amount);
        } else if (h.action == Message.METADATA) {
            _validateMessage(message, Message.METADATA, originToken, Message.METADATA_LENGTH);
            Message.Metadata memory m = abi.decode(message, (Message.Metadata));
            bool applied = wrappedAsset.applySnapshot(nonce, m.observedAt, m.current, m.next, m.effectiveAt);
            emit MetadataReceived(guid, nonce, applied);
        } else {
            revert InvalidMessage();
        }
        emit MessageConsumed(guid, nonce, h.action);
    }
}
