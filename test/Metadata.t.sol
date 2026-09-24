// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Fixture} from "./Fixture.sol";
import {WrappedAsset} from "../src/WrappedAsset.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";

contract MetadataTest is Fixture {
    function test_UninitializedMetadataDoesNotMisrepresentShares() public {
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.uiMultiplier();
        _mint(100 ether);
        assertEq(wrapped.balanceOf(ALICE), 99.5 ether);
    }

    function test_ScheduledSplitDoesNotChangeRawBacking() public {
        _mint(100 ether);
        asset.setMultiplier(1e18, 4e18, block.timestamp + 1 hours);
        bridge.completeMetadata(_metadata());
        assertEq(wrapped.uiMultiplier(), 1e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(wrapped.uiMultiplier(), 4e18);
        assertEq(wrapped.balanceOfUI(ALICE), 398 ether);
        assertEq(wrapped.totalSupply(), 99.5 ether);
        assertEq(vault.locked(), 99.5 ether);
    }

    function test_OutOfOrderSnapshotsCannotOverwriteNewerState() public {
        bytes memory first = _metadata();
        asset.setMultiplier(2e18, 2e18, 0);
        bytes memory second = _metadata();
        assertTrue(bridge.completeMetadata(second));
        assertFalse(bridge.completeMetadata(first));
        assertEq(wrapped.uiMultiplier(), 2e18);
    }

    function test_ScheduledActionCanBeCancelledByNewSnapshot() public {
        asset.setMultiplier(1e18, 4e18, block.timestamp + 1 hours);
        bridge.completeMetadata(_metadata());
        asset.setMultiplier(1e18, 1e18, 0);
        bridge.completeMetadata(_metadata());
        vm.warp(block.timestamp + 1 hours);
        assertEq(wrapped.uiMultiplier(), 1e18);
    }

    function test_ExpiredMetadataFailsClosedButRawRedemptionRemainsAvailable() public {
        _mint(10 ether);
        bridge.completeMetadata(_metadata());
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.balanceOfUI(ALICE);
        vault.completeRedemption(_redeem(9.95 ether, ALICE));
        assertEq(vault.locked(), 0);
    }

    function test_StaleMessageRequiresFreshPublication() public {
        bytes memory old = _metadata();
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(WrappedAsset.InvalidSnapshot.selector);
        bridge.completeMetadata(old);
        bridge.completeMetadata(_metadata());
        assertTrue(wrapped.metadataFresh());
    }

    function test_MetadataReplayAndUnauthorizedUpdatesRejected() public {
        bytes memory encoded = _metadata();
        bridge.completeMetadata(encoded);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeMetadata(encoded);
        vm.expectRevert(WrappedAsset.OnlyBridge.selector);
        wrapped.applySnapshot(999, block.timestamp, 2e18, 2e18, 0);
    }

    function test_InterfacesAndConversion() public {
        bridge.completeMetadata(_metadata());
        assertTrue(wrapped.supportsInterface(0xa60bf13d));
        assertTrue(wrapped.supportsInterface(0x4bd27648));
        assertFalse(wrapped.supportsInterface(0xffffffff));
        assertEq(wrapped.toUIAmount(100), 100);
        assertEq(wrapped.fromUIAmount(100), 100);
    }
}
