// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IScaledUIAmount, IPendingUIAmount} from "./interfaces/IScaledUIAmount.sol";

/// @notice Permissionless raw-unit ERC20; cross-chain UI snapshots never affect balances, allowances or backing.
contract WrappedAsset is ERC20, ERC165, IScaledUIAmount, IPendingUIAmount {
    address public immutable bridge;
    uint16 public immutable originWormholeChain;
    address public immutable originToken;
    uint256 public immutable metadataMaxAge;
    uint256 public constant MAX_CLOCK_SKEW = 5 minutes;
    bool public hasSnapshot;
    uint64 public snapshotSequence;
    uint256 public observedAt;
    uint256 private currentMultiplier;
    uint256 private pendingMultiplier;
    uint256 private pendingEffectiveAt;
    error OnlyBridge();
    error StaleMetadata();
    error InvalidSnapshot();
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event UIMultiplierUpdateCancelled(uint256 cancelledMultiplier, uint256 cancelledEffectiveAt);
    event SnapshotApplied(
        uint64 indexed sequence, uint256 observedAt, uint256 current, uint256 next, uint256 effectiveAt
    );
    event SnapshotIgnored(uint64 indexed sequence);

    constructor(
        string memory name_,
        string memory symbol_,
        uint16 sourceChain,
        address sourceToken,
        uint256 maxAge
    ) ERC20(name_, symbol_) {
        if (
            maxAge == 0 || maxAge > 30 days || sourceToken == address(0) || sourceChain == 0
                || bytes(name_).length == 0 || bytes(symbol_).length == 0
        ) revert InvalidSnapshot();
        bridge = msg.sender;
        originWormholeChain = sourceChain;
        originToken = sourceToken;
        metadataMaxAge = maxAge;
    }
    modifier onlyBridge() {
        if (msg.sender != bridge) revert OnlyBridge();
        _;
    }

    function bridgeMint(address recipient, uint256 amount) external onlyBridge {
        _mint(recipient, amount);
    }

    function bridgeBurn(address holder, uint256 amount) external onlyBridge {
        _burn(holder, amount);
    }

    function applySnapshot(
        uint64 sequence,
        uint256 observed,
        uint256 current,
        uint256 next,
        uint256 effective
    ) external onlyBridge returns (bool) {
        if (hasSnapshot && sequence <= snapshotSequence) {
            emit SnapshotIgnored(sequence);
            return false;
        }
        if (
            current == 0 || next == 0 || observed > block.timestamp + MAX_CLOCK_SKEW
                || block.timestamp > observed + metadataMaxAge || (hasSnapshot && observed < observedAt)
                || (effective == 0 && next != current) || (effective != 0 && effective <= observed)
        ) revert InvalidSnapshot();
        uint256 old = _effectiveMultiplier();
        if (
            hasSnapshot && pendingEffectiveAt > block.timestamp
                && (pendingEffectiveAt != effective || pendingMultiplier != next)
        ) {
            emit UIMultiplierUpdateCancelled(pendingMultiplier, pendingEffectiveAt);
        }
        hasSnapshot = true;
        snapshotSequence = sequence;
        observedAt = observed;
        currentMultiplier = current;
        pendingMultiplier = next;
        pendingEffectiveAt = effective;
        emit UIMultiplierUpdated(old, current, observed);
        if (effective != 0) emit UIMultiplierUpdated(current, next, effective);
        emit SnapshotApplied(sequence, observed, current, next, effective);
        return true;
    }

    function metadataFresh() public view returns (bool) {
        return hasSnapshot && block.timestamp <= observedAt + metadataMaxAge;
    }

    function _requireFresh() private view {
        if (!metadataFresh()) revert StaleMetadata();
    }

    function _effectiveMultiplier() private view returns (uint256) {
        return pendingEffectiveAt != 0 && block.timestamp >= pendingEffectiveAt
            ? pendingMultiplier
            : currentMultiplier;
    }

    function uiMultiplier() public view override returns (uint256) {
        _requireFresh();
        return _effectiveMultiplier();
    }

    function newUIMultiplier() external view override returns (uint256) {
        _requireFresh();
        return pendingMultiplier;
    }

    function effectiveAt() external view override returns (uint256) {
        _requireFresh();
        return pendingEffectiveAt;
    }

    /// @notice Raw snapshot for monitoring even when UI accessors fail closed due to staleness.
    function snapshot() external view returns (uint256 current, uint256 next, uint256 effective) {
        return (currentMultiplier, pendingMultiplier, pendingEffectiveAt);
    }

    function toUIAmount(uint256 raw) public view returns (uint256) {
        return Math.mulDiv(raw, uiMultiplier(), 1e18);
    }

    function fromUIAmount(uint256 ui) external view returns (uint256) {
        return Math.mulDiv(ui, 1e18, uiMultiplier());
    }

    function balanceOfUI(address holder) external view returns (uint256) {
        return toUIAmount(balanceOf(holder));
    }

    function totalSupplyUI() external view returns (uint256) {
        return toUIAmount(totalSupply());
    }

    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return
            id == 0x01ffc9a7 || id == 0xa60bf13d || id == 0x4bd27648 || id == 0x57854fc3 || id == 0xd890fd71;
    }
}
