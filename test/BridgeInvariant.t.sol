// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WrappedAsset} from "../src/WrappedAsset.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {MockWormholeCore} from "./mocks/MockWormholeCore.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// @dev Randomly interleaves both directions, delayed delivery, transfers and duplicate relay attempts.
contract BridgeHandler is Test {
    SourceVault public immutable vault;
    DestinationBridge public immutable bridge;
    MockStockToken public immutable asset;
    WrappedAsset public immutable wrapped;
    MockWormholeCore public immutable sourceCore;
    MockWormholeCore public immutable destinationCore;
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
        SourceVault vault_,
        DestinationBridge bridge_,
        MockStockToken asset_,
        MockWormholeCore sourceCore_,
        MockWormholeCore destinationCore_
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
        uint64 sequence = vault.deposit(amount, address(this));
        bytes memory encoded = sourceCore.published(address(vault), sequence);
        destinationCore.attest(encoded);
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
            vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
            bridge.completeDeposit(deposits[index]);
            return;
        }
        bridge.completeDeposit(deposits[index]);
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
        uint64 sequence = bridge.redeem(amount, address(this));
        bytes memory encoded = destinationCore.published(address(bridge), sequence);
        sourceCore.attest(encoded);
        redemptionAmounts[redemptions.length] = amount;
        redemptions.push(encoded);
        pendingRelease += amount;
    }

    function deliverRedemption(uint256 seed) external {
        vm.chainId(vault.deploymentChainId());
        if (redemptions.length == 0 || vault.pausedLanes() & 2 != 0) return;
        uint256 index = seed % redemptions.length;
        if (released[index]) {
            vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
            vault.completeRedemption(redemptions[index]);
            return;
        }
        vault.completeRedemption(redemptions[index]);
        released[index] = true;
        pendingRelease -= redemptionAmounts[index];
        originalReleased += redemptionAmounts[index];
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 2 days));
    }

    function setPause(bool sourceSide, uint8 lanes, bool paused) external {
        WormholeEndpoint endpoint =
            sourceSide ? WormholeEndpoint(address(vault)) : WormholeEndpoint(address(bridge));
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

    function _changeMaximum(WormholeEndpoint endpoint, uint256 next) private {
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
                bridge.completeDeposit(deposits[i]);
                minted[i] = true;
                pendingMint -= depositAmounts[i];
            }
        }
        vm.chainId(vault.deploymentChainId());
        for (uint256 i; i < redemptions.length; ++i) {
            if (!released[i]) {
                vault.completeRedemption(redemptions[i]);
                released[i] = true;
                pendingRelease -= redemptionAmounts[i];
                originalReleased += redemptionAmounts[i];
            }
        }
    }
}

contract BridgeInvariantTest is Fixture {
    BridgeHandler internal handler;

    function setUp() public override {
        vm.chainId(111);
        sourceCore = new MockWormholeCore(SOURCE);
        asset = new MockStockToken();
        vm.chainId(222);
        destinationCore = new MockWormholeCore(DESTINATION);
        // Dynamic per-transfer maxima without a shared quota.
        WormholeEndpoint.Config memory sourceConfig = _config(address(sourceCore), DESTINATION);
        WormholeEndpoint.Config memory destinationConfig = _config(address(destinationCore), SOURCE);
        sourceConfig.localEvmChain = 111;
        sourceConfig.remoteEvmChain = 222;
        destinationConfig.localEvmChain = 222;
        destinationConfig.remoteEvmChain = 111;
        sourceConfig.maxTransfer = TEST_MAX_TRANSFER / 100;
        destinationConfig.maxTransfer = TEST_MAX_TRANSFER / 100;
        vm.chainId(111);
        vault = new SourceVault(sourceConfig, address(asset), TREASURY);
        vm.chainId(222);
        bridge = new DestinationBridge(destinationConfig, address(asset), "Stock", "sSTK", 1 days);
        wrapped = bridge.wrappedAsset();
        bridge.setPeer(address(vault), address(asset));
        bridge.unpause(3);
        vm.chainId(111);
        vault.setPeer(address(bridge), address(wrapped));
        vault.unpause(3);
        handler = new BridgeHandler(vault, bridge, asset, sourceCore, destinationCore);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.deliverDeposit.selector;
        selectors[2] = handler.transferWrapped.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.deliverRedemption.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.setPause.selector;
        selectors[7] = handler.changeMaximum.selector;
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
