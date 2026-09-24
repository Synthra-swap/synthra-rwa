// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {BridgeMessage} from "../src/BridgeMessage.sol";
import {IWormholeCore} from "../src/interfaces/IWormholeCore.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Independent adversarial cases and executable evidence of residual trust assumptions.
contract InternalAuditTest is Fixture {
    function test_FeeRecipientMayAlsoBeDepositorWithoutChangingBacking() public {
        vault = new SourceVault(_config(address(sourceCore), DESTINATION), address(asset), ALICE);
        bridge = new DestinationBridge(
            _config(address(destinationCore), SOURCE), address(asset), "Stock", "sSTK", 1 days
        );
        wrapped = bridge.wrappedAsset();
        vault.setPeer(address(bridge), address(wrapped));
        bridge.setPeer(address(vault), address(asset));
        vault.unpause(3);
        bridge.unpause(3);
        vm.prank(ALICE);
        asset.approve(address(vault), type(uint256).max);
        uint256 before = asset.balanceOf(ALICE);
        _mint(100 ether);
        assertEq(before - asset.balanceOf(ALICE), 99.5 ether);
        assertEq(asset.balanceOf(address(vault)), wrapped.totalSupply());
    }

    function test_RoundTripBeyondFormerTotalCapWithOutOfOrderDelivery() public {
        uint256 originalBalance = asset.balanceOf(ALICE);
        bytes memory first = _deposit(TEST_MAX_TRANSFER, ALICE);
        bytes memory second = _deposit(TEST_MAX_TRANSFER, ALICE);
        uint256 net = _net(TEST_MAX_TRANSFER);
        assertEq(vault.locked(), 2 * net);
        assertGt(vault.locked(), vault.maxTransfer());
        bridge.completeDeposit(second);
        bridge.completeDeposit(first);
        assertEq(wrapped.totalSupply(), 2 * net);
        bytes memory firstReturn = _redeem(net, ALICE);
        bytes memory secondReturn = _redeem(net, ALICE);
        vault.completeRedemption(secondReturn);
        vault.completeRedemption(firstReturn);
        assertEq(vault.locked(), 0);
        assertEq(wrapped.totalSupply(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(ALICE), originalBalance - 2 * (TEST_MAX_TRANSFER - net));
    }

    function test_ForgedExcessRedemptionCannotSpendDonatedSurplus() public {
        _mint(10 ether);
        vm.prank(ALICE);
        asset.transfer(address(vault), 100 ether);
        IWormholeCore.VM memory m = abi.decode(_redeem(1 ether, ALICE), (IWormholeCore.VM));
        BridgeMessage.Transfer memory t = abi.decode(m.payload, (BridgeMessage.Transfer));
        t.amount = 20 ether;
        m.payload = abi.encode(t);
        bytes memory forged = abi.encode(m);
        sourceCore.attest(forged); // Simulate authenticated but impossible input, not a real quorum exploit.
        vm.expectRevert(SourceVault.InsufficientBacking.selector);
        vault.completeRedemption(forged);
        assertEq(vault.locked(), 9.95 ether);
        assertEq(asset.balanceOf(address(vault)), 109.95 ether);
    }

    function testFuzz_DirtyAbiWordsRejectedAndClaimStillDeliverable(uint8 field) public {
        field = uint8(bound(field, 0, 2));
        bytes memory valid = _deposit(1 ether, ALICE);
        IWormholeCore.VM memory m = abi.decode(valid, (IWormholeCore.VM));
        bytes memory payload = m.payload;
        // ABI decoder must reject non-zero high bits for uint8, uint16 and address.
        uint256 offset = field == 0 ? 32 : field == 1 ? 160 : 256;
        assembly {
            let pointer := add(add(payload, 32), offset)
            mstore(pointer, or(mload(pointer), shl(255, 1)))
        }
        bytes memory dirty = abi.encode(m);
        destinationCore.attest(dirty);
        vm.expectRevert();
        bridge.completeDeposit(dirty);
        bridge.completeDeposit(valid);
        assertEq(wrapped.totalSupply(), 0.995 ether);
    }

    function test_WrongEntryPointDoesNotConsumeTransferOrMetadata() public {
        bytes memory deposit = _deposit(1 ether, ALICE);
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        bridge.completeMetadata(deposit);
        bridge.completeDeposit(deposit);
        bytes memory metadata = _metadata();
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        bridge.completeDeposit(metadata);
        bridge.completeMetadata(metadata);
        assertEq(wrapped.totalSupply(), 0.995 ether);
    }

    function test_ImmediateFeeRemainsPaidDuringDelayedDestinationExecution() public {
        bytes memory deposit = _deposit(100 ether, ALICE);
        bridge.pause(2);
        vm.expectRevert(abi.encodeWithSelector(WormholeEndpoint.LanePaused.selector, uint8(2)));
        bridge.completeDeposit(deposit);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(wrapped.totalSupply(), 0);
        bridge.unpause(2);
        bridge.completeDeposit(deposit);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
    }

    function test_RawTransfersRemainAvailableWithAllBridgeLanesPausedAndStaleMetadata() public {
        _mint(10 ether);
        bridge.completeMetadata(_metadata());
        vault.pause(3);
        bridge.pause(3);
        vm.warp(block.timestamp + 2 days);
        assertFalse(wrapped.metadataFresh());
        vm.prank(ALICE);
        wrapped.transfer(BOB, 9.95 ether);
        assertEq(wrapped.balanceOf(BOB), 9.95 ether);
    }

    function test_ReleaseCallbackCannotReenterOrSpendSameClaimTwice() public {
        _mint(10 ether);
        bytes memory burn = _redeem(9.95 ether, ALICE);
        asset.setCallback(address(vault), abi.encodeCall(vault.completeRedemption, (burn)));
        vault.completeRedemption(burn);
        assertFalse(asset.callbackSucceeded());
        assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(vault.locked(), 0);
    }

    function test_ExpiredScheduleIsNormalizedOnSourcePublication() public {
        asset.setMultiplier(1e18, 4e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        bridge.completeMetadata(_metadata());
        assertEq(wrapped.uiMultiplier(), 4e18);
        assertEq(wrapped.newUIMultiplier(), 4e18);
        assertEq(wrapped.effectiveAt(), 0);
    }

    function test_IncompatibleRemoteMaximumRequiresGovernanceCorrectionNotJustWaiting() public {
        WormholeEndpoint.Config memory c = _config(address(destinationCore), SOURCE);
        c.maxTransfer = 1 ether;
        DestinationBridge smaller = new DestinationBridge(c, address(asset), "Stock", "sSTK", 1 days);
        SourceVault fresh =
            new SourceVault(_config(address(sourceCore), DESTINATION), address(asset), TREASURY);
        smaller.setPeer(address(fresh), address(asset));
        fresh.setPeer(address(smaller), address(smaller.wrappedAsset()));
        smaller.unpause(3);
        fresh.unpause(3);
        vm.startPrank(ALICE);
        asset.approve(address(fresh), type(uint256).max);
        uint64 sequence = fresh.deposit(10 ether, ALICE);
        vm.stopPrank();
        bytes memory encoded = sourceCore.published(address(fresh), sequence);
        destinationCore.attest(encoded);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        smaller.completeDeposit(encoded);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        smaller.completeDeposit(encoded);
        assertEq(fresh.locked(), 9.95 ether);
        assertEq(smaller.wrappedAsset().totalSupply(), 0);
        smaller.prepareInboundMaxTransfer(10 ether);
        smaller.setMaxTransfer(10 ether);
        smaller.completeDeposit(encoded);
        assertEq(smaller.wrappedAsset().totalSupply(), fresh.locked());
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        smaller.completeDeposit(encoded);
    }

    function _governed() private returns (TimelockController timelock, SourceVault governed) {
        address[] memory members = new address[](1);
        members[0] = address(this);
        timelock = new TimelockController(2 days, members, members, address(0));
        WormholeEndpoint.Config memory c = _config(address(sourceCore), DESTINATION);
        c.owner = address(timelock);
        governed = new SourceVault(c, address(asset), TREASURY);
        bytes memory payload = abi.encodeCall(governed.setPeer, (address(bridge), address(wrapped)));
        timelock.schedule(address(governed), 0, payload, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(governed), 0, payload, bytes32(0), bytes32(0));
    }

    function test_GovernanceCanReduceInitialTimelockDelayToZero() public {
        (TimelockController timelock, SourceVault governed) = _governed();
        bytes memory change = abi.encodeCall(timelock.updateDelay, (0));
        timelock.schedule(address(timelock), 0, change, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(timelock), 0, change, bytes32(0), bytes32(0));
        assertEq(timelock.getMinDelay(), 0);
        bytes memory resume = abi.encodeCall(governed.unpause, (uint8(3)));
        timelock.schedule(address(governed), 0, resume, bytes32(0), bytes32(0), 0);
        timelock.execute(address(governed), 0, resume, bytes32(0), bytes32(0));
        assertEq(governed.pausedLanes(), 0);
    }

    function test_AlreadyReadyUnpauseDoesNotWaitAfterANewEmergencyPause() public {
        (TimelockController timelock, SourceVault governed) = _governed();
        bytes memory resume = abi.encodeCall(governed.unpause, (uint8(3)));
        timelock.schedule(address(governed), 0, resume, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(GUARDIAN);
        governed.pause(3);
        timelock.execute(address(governed), 0, resume, bytes32(0), bytes32(0));
        assertEq(governed.pausedLanes(), 0);
    }

    function test_DelayedOwnershipMigrationCanRemoveTimelockEntirely() public {
        (TimelockController timelock, SourceVault governed) = _governed();
        bytes memory migration = abi.encodeCall(governed.transferOwnership, (BOB));
        timelock.schedule(address(governed), 0, migration, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(governed), 0, migration, bytes32(0), bytes32(0));
        vm.startPrank(BOB);
        governed.acceptOwnership();
        governed.unpause(3);
        vm.stopPrank();
        assertEq(governed.owner(), BOB);
        assertEq(governed.pausedLanes(), 0);
    }
}
