// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {WrappedAsset} from "../src/WrappedAsset.sol";
import {BridgeMessage} from "../src/BridgeMessage.sol";
import {IWormholeCore} from "../src/interfaces/IWormholeCore.sol";

contract EdgeCasesTest is Fixture {
    function testFuzz_InvalidEndpointConfiguration(uint8 field) public {
        field = uint8(bound(field, 0, 5));
        WormholeEndpoint.Config memory c = _config(address(sourceCore), DESTINATION);
        if (field == 0) c.core = BOB;
        if (field == 1) c.guardian = address(0);
        if (field == 2) c.localEvmChain = 0;
        if (field == 3) c.remoteEvmChain = 0;
        if (field == 4) c.remoteChain = SOURCE;
        if (field == 5) c.maxTransfer = 0;
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        new SourceVault(c, address(asset), TREASURY);
    }

    function test_GuardianRotationAndInvalidMasks() public {
        vault.setGuardian(BOB);
        vm.prank(GUARDIAN);
        vm.expectRevert(WormholeEndpoint.UnauthorizedGuardian.selector);
        vault.pause(3);
        vm.prank(BOB);
        vault.pause(3);
        vault.unpause(3);
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        vault.pause(0);
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        vault.unpause(4);
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        vault.setGuardian(address(0));
    }

    function test_BackgroundBackingDeficitBlocksNewDeposits() public {
        _mint(10 ether);
        asset.seize(address(vault), 1);
        vm.prank(ALICE);
        vm.expectRevert(SourceVault.InsufficientBacking.selector);
        vault.deposit(1 ether, ALICE);
    }

    function test_BadSourceMetadataAndMessageFees() public {
        asset.setMultiplier(0, 0, 0);
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        vault.publishMetadata();
        sourceCore.setMessageFee(1);
        vm.expectRevert(WormholeEndpoint.IncorrectMessageFee.selector);
        vault.publishMetadata();
    }

    function testFuzz_InvalidAuthenticatedMetadata(uint8 field) public {
        vm.warp(3 days);
        field = uint8(bound(field, 0, 5));
        IWormholeCore.VM memory m = abi.decode(_metadata(), (IWormholeCore.VM));
        BridgeMessage.Metadata memory data = abi.decode(m.payload, (BridgeMessage.Metadata));
        if (field == 0) data.observedAt = block.timestamp + 301;
        if (field == 1) data.current = 0;
        if (field == 2) data.next = 0;
        if (field == 3) data.effectiveAt = data.observedAt;
        if (field == 4) data.next = 2e18;
        if (field == 5) data.observedAt = block.timestamp - 1 days - 1;
        m.payload = abi.encode(data);
        bytes memory encoded = abi.encode(m);
        destinationCore.attest(encoded);
        vm.expectRevert(WrappedAsset.InvalidSnapshot.selector);
        bridge.completeMetadata(encoded);
    }

    function test_SupplyCanGrowInSameBlockWithoutTotalCap() public {
        for (uint256 i; i < 3; ++i) {
            _mint(TEST_MAX_TRANSFER);
        }
        assertEq(wrapped.totalSupply(), 3 * _net(TEST_MAX_TRANSFER));
        assertEq(vault.locked(), wrapped.totalSupply());
        assertGt(wrapped.totalSupply(), bridge.maxTransfer());
        // Growing supply does not increase the maximum on either endpoint.
        vm.prank(ALICE);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        vault.deposit(TEST_MAX_TRANSFER + 1, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        bridge.redeem(TEST_MAX_TRANSFER + 1, ALICE);
    }

    function test_RawSnapshotReadableWhileStaleAndFullPrecisionConversion() public {
        _mint(10 ether);
        asset.setMultiplier(4e18, 4e18, 0);
        bridge.completeMetadata(_metadata());
        assertEq(wrapped.totalSupplyUI(), 39.8 ether);
        assertEq(wrapped.toUIAmount(1e50), 4e50);
        assertEq(wrapped.fromUIAmount(4e50), 1e50);
        vm.warp(block.timestamp + 1 days + 1);
        (uint256 current, uint256 next, uint256 effective) = wrapped.snapshot();
        assertEq(current, 4e18);
        assertEq(next, 4e18);
        assertEq(effective, 0);
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.newUIMultiplier();
        vm.expectRevert(WrappedAsset.StaleMetadata.selector);
        wrapped.effectiveAt();
    }

    function test_PendingGettersAndInvalidConstructor() public {
        asset.setMultiplier(1e18, 2e18, block.timestamp + 1 hours);
        bridge.completeMetadata(_metadata());
        assertEq(wrapped.newUIMultiplier(), 2e18);
        assertEq(wrapped.effectiveAt(), block.timestamp + 1 hours);
        vm.expectRevert(WrappedAsset.InvalidSnapshot.selector);
        new WrappedAsset("Stock", "sSTK", SOURCE, address(asset), 0);
    }
}
