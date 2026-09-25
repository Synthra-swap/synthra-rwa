// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LayerZeroEndpoint} from "./LayerZeroEndpoint.sol";
import {LayerZeroMessage} from "./LayerZeroMessage.sol";
import {IScaledUIAmount, IPendingUIAmount} from "../interfaces/IScaledUIAmount.sol";

import {MessagingReceipt} from "./ILayerZero.sol";

/// @notice Single-asset escrow. Fees are transferred immediately; only net principal remains in escrow.
contract LayerZeroSourceVault is LayerZeroEndpoint {
    using SafeERC20 for IERC20;
    uint256 public constant FEE_BPS = 50;
    uint256 public constant BPS = 10_000;
    IERC20 public immutable asset;
    address public feeRecipient;
    uint256 public locked;
    error UnsupportedTransfer();
    error InsufficientBacking();
    event Deposited(
        uint64 indexed sequence,
        address indexed sender,
        address indexed recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 fee
    );
    event Released(bytes32 indexed messageId, address indexed recipient, uint256 amount);
    event FeePaid(address indexed recipient, uint256 amount);
    event FeeRecipientChanged(address indexed previous, address indexed next);
    event MetadataPublished(
        uint64 indexed sequence, uint256 observedAt, uint256 current, uint256 next, uint256 effectiveAt
    );

    constructor(Config memory c, address sourceToken, address treasury) LayerZeroEndpoint(c) {
        if (
            sourceToken.code.length == 0 || treasury == address(0) || treasury == address(this)
                || treasury == sourceToken
        ) revert InvalidConfiguration();
        if (IERC20Metadata(sourceToken).decimals() != 18) revert InvalidConfiguration();
        asset = IERC20(sourceToken);
        feeRecipient = treasury;
    }

    /// @notice Governance can redirect future fees; no authority over existing reserves or paid fees.
    /// @dev Owner is the deployment timelock. Fee rate remains constant.
    function setFeeRecipient(address next) external onlyOwner nonReentrant {
        if (next == address(0) || next == address(this) || next == address(asset)) {
            revert InvalidConfiguration();
        }
        address previous = feeRecipient;
        feeRecipient = next;
        emit FeeRecipientChanged(previous, next);
    }

    /// @notice Fee rounded down in raw units; no fee on redemption. Fee rate cannot change.
    function quoteDeposit(uint256 gross) public pure returns (uint256 net, uint256 fee) {
        fee = Math.mulDiv(gross, FEE_BPS, BPS);
        net = gross - fee;
    }

    function deposit(uint256 gross, address recipient)
        external
        payable
        nonReentrant
        returns (MessagingReceipt memory receipt)
    {
        _checkOutbound(gross, recipient);
        (uint256 net, uint256 fee) = quoteDeposit(gross);
        uint256 beforeBalance = asset.balanceOf(address(this));
        if (beforeBalance < locked) revert InsufficientBacking();
        asset.safeTransferFrom(msg.sender, address(this), gross);
        if (asset.balanceOf(address(this)) != beforeBalance + gross) revert UnsupportedTransfer();
        locked += net;
        if (fee != 0) {
            _transferExact(feeRecipient, fee);
            emit FeePaid(feeRecipient, fee);
        }
        receipt = _send(
            abi.encode(
                LayerZeroMessage.Transfer(_header(LayerZeroMessage.DEPOSIT, address(asset)), recipient, net)
            )
        );
        emit Deposited(receipt.nonce, msg.sender, recipient, gross, net, fee);
    }

    function quoteDepositFee(uint256 gross, address recipient) external view returns (uint256) {
        _checkOutbound(gross, recipient);
        (uint256 net,) = quoteDeposit(gross);
        return _quote(
            abi.encode(
                LayerZeroMessage.Transfer(_header(LayerZeroMessage.DEPOSIT, address(asset)), recipient, net)
            )
        );
    }

    function _receiveMessage(uint64 nonce, bytes32 guid, bytes calldata message) internal override {
        LayerZeroMessage.Transfer memory t = _transfer(message, LayerZeroMessage.REDEEM, address(asset));
        if (t.recipient == address(asset)) revert InvalidMessage();
        if (t.amount > locked || asset.balanceOf(address(this)) < locked) revert InsufficientBacking();
        locked -= t.amount;
        _transferExact(t.recipient, t.amount);
        emit MessageConsumed(guid, nonce, LayerZeroMessage.REDEEM);
        emit Released(guid, t.recipient, t.amount);
    }

    function _transferExact(address recipient, uint256 amount) private {
        uint256 beforeBalance = asset.balanceOf(address(this));
        uint256 beforeRecipient = asset.balanceOf(recipient);
        asset.safeTransfer(recipient, amount);
        if (
            asset.balanceOf(address(this)) != beforeBalance - amount
                || asset.balanceOf(recipient) != beforeRecipient + amount
        ) revert UnsupportedTransfer();
    }

    /// @notice Quotes the current source snapshot. Publishing re-reads all values from the issuer.
    function quoteMetadataFee() external view returns (uint256) {
        _checkLane(OUTBOUND);
        return _quote(abi.encode(_metadata()));
    }

    /// @notice Permissionless refresh. Callers cannot supply multiplier values.
    function publishMetadata() external payable nonReentrant returns (MessagingReceipt memory receipt) {
        _checkLane(OUTBOUND);
        LayerZeroMessage.Metadata memory m = _metadata();
        receipt = _send(abi.encode(m));
        emit MetadataPublished(receipt.nonce, m.observedAt, m.current, m.next, m.effectiveAt);
    }

    function _metadata() private view returns (LayerZeroMessage.Metadata memory) {
        uint256 current = IScaledUIAmount(address(asset)).uiMultiplier();
        uint256 next = IPendingUIAmount(address(asset)).newUIMultiplier();
        uint256 effective = IPendingUIAmount(address(asset)).effectiveAt();
        if (effective <= block.timestamp) {
            next = current;
            effective = 0;
        }
        if (current == 0 || next == 0) revert InvalidMessage();
        return LayerZeroMessage.Metadata(
            _header(LayerZeroMessage.METADATA, address(asset)), block.timestamp, current, next, effective
        );
    }
}
