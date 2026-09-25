// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LayerZeroFixture} from "./Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroDestinationBridge} from "../../src/layerzero/LayerZeroDestinationBridge.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {Origin, MessagingReceipt} from "../../src/layerzero/ILayerZero.sol";
import {MockReceiveUln} from "./MockLayerZero.sol";
import {MockLayerZero} from "./MockLayerZero.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";

/// @dev Randomly interleaves both directions, delayed delivery, transfers and duplicate relay attempts.
contract LayerZeroBridgeHandler is Test {
    LayerZeroSourceVault public immutable vault;
    LayerZeroDestinationBridge public immutable bridge;
    MockStockToken public immutable asset;
    LayerZeroWrappedAsset public immutable wrapped;
    MockLayerZero public immutable sourceCore;
    MockLayerZero public immutable destinationCore;
    bytes[] internal deposits;
    bytes[] internal redemptions;
    mapping(uint256 => bool) internal minted;
    mapping(uint256 => bool) internal released;
    mapping(uint256 => uint256) internal depositAmounts;
    mapping(uint256 => uint256) internal redemptionAmounts;
    uint256 public paidFees;
    uint256 public grossDeposited;
    uint256 public originalReleased;
    uint256 public pendingMint;
    uint256 public pendingRelease;
    address internal constant SECOND_HOLDER = address(0xBEEF);

    constructor(
        LayerZeroSourceVault vault_,
        LayerZeroDestinationBridge bridge_,
        MockStockToken asset_,
        MockLayerZero sourceCore_,
        MockLayerZero destinationCore_
    ) {
        vault = vault_;
        bridge = bridge_;
        asset = asset_;
        wrapped = bridge_.wrappedAsset();
        sourceCore = sourceCore_;
        destinationCore = destinationCore_;
        asset.approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 seed) external {
        vm.chainId(vault.deploymentChainId());
        uint256 available = vault.maxTransfer();
        if (vault.pausedLanes() & 1 != 0 || available == 0) return;
        uint256 amount = bound(seed, 1, available);
        asset.mint(address(this), amount);
        uint64 sequence = vault.deposit(amount, address(this)).nonce;
        bytes memory encoded = sourceCore.published(address(vault), sequence);
        _attest(bridge, encoded);
        // Independent reference arithmetic; do not call the implementation under test.
        uint256 fee = amount / 200;
        uint256 net = amount - fee;
        grossDeposited += amount;
        paidFees += fee;
        depositAmounts[deposits.length] = net;
        deposits.push(encoded);
        pendingMint += net;
    }

    function deliverDeposit(uint256 seed) external {
        vm.chainId(bridge.deploymentChainId());
        if (deposits.length == 0 || bridge.pausedLanes() & 2 != 0) return;
        uint256 index = seed % deposits.length;
        if (minted[index]) {
            vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
            _complete(bridge, deposits[index]);
            return;
        }
        _complete(bridge, deposits[index]);
        minted[index] = true;
        pendingMint -= depositAmounts[index];
    }

    function transferWrapped(uint256 seed) external {
        vm.chainId(bridge.deploymentChainId());
        uint256 balance = wrapped.balanceOf(address(this));
        if (balance == 0) return;
        wrapped.transfer(SECOND_HOLDER, bound(seed, 1, balance));
    }

    function redeem(uint256 seed, bool secondHolder) external {
        vm.chainId(bridge.deploymentChainId());
        address holder = secondHolder ? SECOND_HOLDER : address(this);
        uint256 balance = _min(wrapped.balanceOf(holder), bridge.maxTransfer());
        if (bridge.pausedLanes() & 1 != 0) return;
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        vm.prank(holder);
        uint64 sequence = bridge.redeem(amount, address(this)).nonce;
        bytes memory encoded = destinationCore.published(address(bridge), sequence);
        _attest(vault, encoded);
        redemptionAmounts[redemptions.length] = amount;
        redemptions.push(encoded);
        pendingRelease += amount;
    }

    function deliverRedemption(uint256 seed) external {
        vm.chainId(vault.deploymentChainId());
        if (redemptions.length == 0 || vault.pausedLanes() & 2 != 0) return;
        uint256 index = seed % redemptions.length;
        if (released[index]) {
            vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
            _complete(vault, redemptions[index]);
            return;
        }
        _complete(vault, redemptions[index]);
        released[index] = true;
        pendingRelease -= redemptionAmounts[index];
        originalReleased += redemptionAmounts[index];
    }

    function _attest(LayerZeroEndpoint receiver, bytes memory packet) private {
        vm.chainId(receiver.deploymentChainId());
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        MockReceiveUln uln = MockReceiveUln(receiver.receiveLibrary());
        bytes memory header = receiver.packetHeader(o);
        bytes32 hash = keccak256(abi.encodePacked(guid, message));
        uln.attest(header, hash);
        uln.commitVerification(header, hash);
    }

    function _complete(LayerZeroEndpoint receiver, bytes memory packet) private {
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        receiver.complete(o, guid, message);
    }

    function checkpointPending(uint256 seed, bool sourceSide) external {
        if (sourceSide ? redemptions.length == 0 : deposits.length == 0) return;
        uint256 index = seed % (sourceSide ? redemptions.length : deposits.length);
        if (sourceSide ? released[index] : minted[index]) return;
        bytes memory packet = sourceSide ? redemptions[index] : deposits[index];
        LayerZeroEndpoint receiver =
            sourceSide ? LayerZeroEndpoint(address(vault)) : LayerZeroEndpoint(address(bridge));
        vm.chainId(receiver.deploymentChainId());
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        receiver.checkpoint(o, guid, message);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 2 days));
    }

    function setPause(bool sourceSide, uint8 lanes, bool paused) external {
        LayerZeroEndpoint endpoint =
            sourceSide ? LayerZeroEndpoint(address(vault)) : LayerZeroEndpoint(address(bridge));
        vm.chainId(endpoint.deploymentChainId());
        lanes = uint8(bound(lanes, 1, 3));
        vm.prank(endpoint.owner());
        if (paused) endpoint.pause(lanes);
        else endpoint.unpause(lanes);
    }

    function changeMaximum(uint256 seed) external {
        uint256 next = bound(seed, 1, 1000 ether);
        _changeMaximum(vault, next);
        _changeMaximum(bridge, next);
    }

    function _changeMaximum(LayerZeroEndpoint endpoint, uint256 next) private {
        vm.chainId(endpoint.deploymentChainId());
        vm.startPrank(endpoint.owner());
        if (next > endpoint.inboundMaxTransfer()) endpoint.prepareInboundMaxTransfer(next);
        endpoint.setMaxTransfer(next);
        vm.stopPrank();
    }

    function drainPending() external {
        vm.chainId(vault.deploymentChainId());
        vm.prank(vault.owner());
        vault.unpause(3);
        vm.chainId(bridge.deploymentChainId());
        vm.prank(bridge.owner());
        bridge.unpause(3);
        for (uint256 i; i < deposits.length; ++i) {
            if (!minted[i]) {
                _complete(bridge, deposits[i]);
                minted[i] = true;
                pendingMint -= depositAmounts[i];
            }
        }
        vm.chainId(vault.deploymentChainId());
        for (uint256 i; i < redemptions.length; ++i) {
            if (!released[i]) {
                _complete(vault, redemptions[i]);
                released[i] = true;
                pendingRelease -= redemptionAmounts[i];
                originalReleased += redemptionAmounts[i];
            }
        }
    }
}

contract LayerZeroBridgeInvariantTest is LayerZeroFixture {
    LayerZeroBridgeHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LayerZeroBridgeHandler(vault, bridge, asset, sourceCore, destinationCore);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.deliverDeposit.selector;
        selectors[2] = handler.transferWrapped.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.deliverRedemption.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.setPause.selector;
        selectors[7] = handler.changeMaximum.selector;
        selectors[8] = handler.checkpointPending.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ReservesCoverSupplyAndEveryPendingClaim() public view {
        assertEq(asset.balanceOf(address(vault)), vault.locked());
        assertEq(vault.locked(), wrapped.totalSupply() + handler.pendingMint() + handler.pendingRelease());
        assertEq(asset.balanceOf(TREASURY), handler.paidFees());
        assertEq(handler.grossDeposited(), vault.locked() + handler.originalReleased() + handler.paidFees());
        assertEq(vault.maxTransfer(), bridge.maxTransfer());
        assertEq(vault.inboundMaxTransfer(), bridge.inboundMaxTransfer());
        assertLe(vault.maxTransfer(), vault.inboundMaxTransfer());
    }

    function afterInvariant() public {
        handler.drainPending();
        assertEq(handler.pendingMint(), 0);
        assertEq(handler.pendingRelease(), 0);
        assertEq(vault.locked(), wrapped.totalSupply());
    }
}
