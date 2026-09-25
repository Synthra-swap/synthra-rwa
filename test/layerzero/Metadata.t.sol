// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LayerZeroFixture} from "./Fixture.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";
import {Origin} from "../../src/layerzero/ILayerZero.sol";

contract LayerZeroMetadataTest is LayerZeroFixture {
    function test_SplitConversionsAndCancellationPreserveRawBacking() public {
        _mint(100 ether);
        asset.setMultiplier(1 ether, 4 ether, block.timestamp + 1 hours);
        _complete(bridge, _metadata());
        assertEq(wrapped.newUIMultiplier(), 4 ether);
        assertEq(wrapped.effectiveAt(), block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertEq(wrapped.balanceOfUI(ALICE), 398 ether);
        assertEq(wrapped.totalSupplyUI(), 398 ether);
        assertEq(wrapped.fromUIAmount(398 ether), 99.5 ether);
        assertEq(vault.locked(), 99.5 ether);
        asset.setMultiplier(4 ether, 2 ether, block.timestamp + 1 hours);
        _complete(bridge, _metadata());
        asset.setMultiplier(4 ether, 4 ether, 0);
        _complete(bridge, _metadata());
        vm.warp(block.timestamp + 1 hours);
        assertEq(wrapped.uiMultiplier(), 4 ether);
        (uint256 current, uint256 next, uint256 effective) = wrapped.snapshot();
        assertEq(current, 4 ether);
        assertEq(next, 4 ether);
        assertEq(effective, 0);
    }

    function test_ThirtyDayBoundaryMeasuredFromSourceAndPermissionlessEarlyRefresh() public {
        uint256 observed = block.timestamp;
        bytes memory packet = _metadata();
        vm.warp(observed + 20 days);
        _complete(bridge, packet);
        assertEq(wrapped.observedAt(), observed);
        vm.warp(observed + 30 days);
        assertTrue(wrapped.metadataFresh());
        vm.warp(observed + 30 days + 1);
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(LayerZeroWrappedAsset.StaleMetadata.selector);
        wrapped.totalSupplyUI();
        _complete(bridge, _metadata());
        assertTrue(wrapped.metadataFresh());
        vm.warp(block.timestamp + 10 days);
        vm.chainId(4663);
        uint256 fee = vault.quoteMetadataFee();
        vm.prank(BOB);
        vault.publishMetadata{value: fee}();
        assertEq(sourceCore.nonce(address(vault)), 3);
    }

    function test_FutureSnapshotRespectsExactClockSkewBoundary() public {
        uint256 observed = block.timestamp;
        bytes memory packet = _metadata();
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.warp(observed - 301);
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        bridge.complete(o, guid, message);
        vm.warp(observed - 300);
        bridge.complete(o, guid, message);
        assertTrue(wrapped.metadataFresh());
    }

    function testFuzz_InvalidSnapshotsRejected(uint8 seed) public {
        _complete(bridge, _metadata());
        uint256 observed = block.timestamp;
        uint256 current = 1 ether;
        uint256 next = 1 ether;
        uint256 effective;
        uint8 mutation = seed % 7;
        if (mutation == 0) current = 0;
        if (mutation == 1) next = 0;
        if (mutation == 2) observed += 301;
        if (mutation == 3) observed -= 31 days;
        if (mutation == 4) observed--;
        if (mutation == 5) next = 2 ether;
        if (mutation == 6) effective = observed;
        vm.prank(address(bridge));
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        wrapped.applySnapshot(2, observed, current, next, effective);
        assertEq(wrapped.snapshotSequence(), 1);
    }

    function test_WrappedPermissionsOriginAndInterfaces() public {
        assertEq(wrapped.originEid(), 30416);
        assertEq(wrapped.originToken(), address(asset));
        assertEq(wrapped.bridge(), address(bridge));
        assertEq(wrapped.decimals(), 18);
        assertTrue(wrapped.supportsInterface(0xa60bf13d));
        assertTrue(wrapped.supportsInterface(0x4bd27648));
        assertTrue(wrapped.supportsInterface(0x01ffc9a7));
        assertFalse(wrapped.supportsInterface(0xffffffff));
        vm.expectRevert(LayerZeroWrappedAsset.OnlyBridge.selector);
        wrapped.bridgeMint(ALICE, 1 ether);
        vm.expectRevert(LayerZeroWrappedAsset.OnlyBridge.selector);
        wrapped.bridgeBurn(ALICE, 1 ether);
        vm.expectRevert(LayerZeroWrappedAsset.OnlyBridge.selector);
        wrapped.applySnapshot(1, block.timestamp, 1, 1, 0);
        _mint(10 ether);
        bridge.pause(3);
        vm.prank(ALICE);
        wrapped.approve(BOB, 1 ether);
        vm.prank(BOB);
        wrapped.transferFrom(ALICE, BOB, 1 ether);
        assertEq(wrapped.balanceOf(BOB), 1 ether);
        assertEq(wrapped.allowance(ALICE, BOB), 0);
    }

    function testFuzz_WrappedConstructorBounds(uint8 seed) public {
        uint256 age = 30 days;
        uint32 eid = 30416;
        address token = address(asset);
        string memory name = "Stock";
        string memory symbol = "sSTK";
        uint8 mutation = seed % 6;
        if (mutation == 0) age = 0;
        if (mutation == 1) age++;
        if (mutation == 2) eid = 0;
        if (mutation == 3) token = address(0);
        if (mutation == 4) name = "";
        if (mutation == 5) symbol = "";
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        new LayerZeroWrappedAsset(name, symbol, eid, token, age);
    }
}
