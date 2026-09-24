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
        vm.warp(block.timestamp + wrapped.metadataMaxAge() + 1);
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.balanceOfUI(ALICE);
        vault.completeRedemption(_redeem(9.95 ether, ALICE));
        assertEq(vault.locked(), 0);
    }

    function test_StaleMessageRequiresFreshPublication() public {
        bytes memory old = _metadata();
        vm.warp(block.timestamp + wrapped.metadataMaxAge() + 1);
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

/// @notice Run the same metadata/transfer regressions with the monthly deployment policy.
contract MonthlyMetadataTest is MetadataTest {
    function _metadataMaxAge() internal pure override returns (uint256) {
        return 30 days;
    }

    function test_ThirtyDayFreshnessBoundary() public {
        bridge.completeMetadata(_metadata());
        uint256 observed = wrapped.observedAt();
        assertEq(wrapped.metadataMaxAge(), 30 days);
        vm.warp(observed + 30 days - 1);
        assertTrue(wrapped.metadataFresh());
        vm.warp(observed + 30 days);
        assertEq(wrapped.uiMultiplier(), 1e18);
        vm.warp(observed + 30 days + 1);
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.uiMultiplier();
    }

    function test_AnyoneCanRenewUnchangedMetadataBeforeExpiry() public {
        bytes memory original = _metadata();
        bridge.completeMetadata(original);
        uint256 firstObserved = wrapped.observedAt();
        vm.warp(firstObserved + 20 days);
        vm.prank(BOB);
        bytes memory renewed = _metadata();
        vm.prank(ALICE);
        bridge.completeMetadata(renewed);
        assertEq(wrapped.observedAt(), firstObserved + 20 days);
        assertEq(wrapped.uiMultiplier(), 1e18);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeMetadata(original);
        assertEq(wrapped.observedAt(), firstObserved + 20 days);
        vm.warp(firstObserved + 30 days + 1);
        assertTrue(wrapped.metadataFresh());
        vm.warp(firstObserved + 50 days + 1);
        assertFalse(wrapped.metadataFresh());
    }

    function test_DelayedDeliveryDoesNotRestartThirtyDayLifetime() public {
        uint256 observed = block.timestamp;
        bytes memory delayed = _metadata();
        vm.warp(observed + 20 days);
        bridge.completeMetadata(delayed);
        assertEq(wrapped.observedAt(), observed);
        assertTrue(wrapped.metadataFresh());
        vm.warp(observed + 30 days + 1);
        assertFalse(wrapped.metadataFresh());
        bridge.completeMetadata(_metadata());
        assertTrue(wrapped.metadataFresh());
    }

    function test_MetadataLifetimeConstructorBounds() public {
        vm.expectRevert(WrappedAsset.InvalidSnapshot.selector);
        new WrappedAsset("Stock", "sSTK", SOURCE, address(asset), 30 days + 1);
        vm.expectRevert(WrappedAsset.InvalidSnapshot.selector);
        new WrappedAsset("Stock", "sSTK", SOURCE, address(asset), 0);
        WrappedAsset shortLived = new WrappedAsset("Stock", "sSTK", SOURCE, address(asset), 1);
        assertEq(shortLived.metadataMaxAge(), 1);
    }
}
