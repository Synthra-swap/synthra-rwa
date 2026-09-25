// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LayerZeroFixture} from "./Fixture.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {Origin, MessagingReceipt} from "../../src/layerzero/ILayerZero.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";

contract LayerZeroVerificationTest is LayerZeroFixture {
    struct Packet {
        Origin origin;
        bytes32 guid;
        bytes message;
    }

    function _pending(bool metadata) private returns (Packet memory p) {
        vm.chainId(4663);
        MessagingReceipt memory r;
        if (metadata) {
            r = vault.publishMetadata();
        } else {
            vm.prank(ALICE);
            r = vault.deposit(10 ether, ALICE);
        }
        (p.origin, p.guid, p.message) =
            abi.decode(sourceCore.published(address(vault), r.nonce), (Origin, bytes32, bytes));
        vm.chainId(5042);
    }

    function _attestOnly(Packet memory p) private {
        destinationUln.attest(bridge.packetHeader(p.origin), keccak256(abi.encodePacked(p.guid, p.message)));
    }

    function _proof(Packet memory p) private pure returns (LayerZeroEndpoint.Verification[] memory a) {
        a = new LayerZeroEndpoint.Verification[](1);
        a[0] = LayerZeroEndpoint.Verification(p.origin.nonce, keccak256(abi.encodePacked(p.guid, p.message)));
    }

    function test_CheckpointPreservesBlockedRedemptionAndAllowsLaterClaims() public {
        _mint(100 ether);
        bytes memory a = _redeem(1 ether, BOB);
        bytes memory b = _redeem(2 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(a, (Origin, bytes32, bytes));
        asset.setBlockedRecipient(BOB);
        vm.expectRevert("blocked recipient");
        vault.complete(o, guid, message);
        vault.checkpoint(o, guid, message);
        bytes32 hash = keccak256(abi.encodePacked(guid, message));
        assertEq(vault.checkpointedPayloads(guid), hash);
        assertFalse(vault.consumedMessages(guid));
        assertEq(sourceCore.inboundPayloadHash(address(vault), o.srcEid, o.sender, o.nonce), bytes32(0));
        _complete(vault, b);
        vm.expectRevert("blocked recipient");
        vault.complete(o, guid, message);
        assertEq(vault.checkpointedPayloads(guid), hash);
        asset.setBlockedRecipient(address(0));
        vm.prank(address(0xCAFE));
        vault.complete(o, guid, message);
        assertEq(asset.balanceOf(BOB), 1 ether);
        assertEq(vault.checkpointedPayloads(guid), bytes32(0));
        assertTrue(vault.consumedMessages(guid));
        vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
        vault.executeCheckpointed(o, guid, message);
    }

    function test_CheckpointAuthenticatesPayloadAndCannotSkipUnverifiedMessages() public {
        Packet memory first = _pending(false);
        Packet memory second = _pending(false);
        _attestOnly(second);
        vm.expectRevert("missing attestations");
        bridge.checkpoint(first.origin, first.guid, first.message);
        vm.expectRevert("nonce gap");
        bridge.checkpoint(second.origin, second.guid, second.message);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.executeCheckpointed(first.origin, first.guid, first.message);
        _attestOnly(first);
        bridge.checkpoint(first.origin, first.guid, first.message);
        bridge.checkpoint(first.origin, first.guid, first.message);
        assertEq(wrapped.totalSupply(), 0);
        bytes memory bad = abi.encodePacked(first.message, bytes1(0));
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.checkpoint(first.origin, first.guid, bad);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.executeCheckpointed(first.origin, first.guid, bad);
        bridge.checkpoint(second.origin, second.guid, second.message);
        bridge.complete(second.origin, second.guid, second.message);
        bridge.complete(first.origin, first.guid, first.message);
        assertEq(wrapped.totalSupply(), 19.9 ether);
    }

    function test_CheckpointDuringPausePreservesClaimAndBatchRaceSafety() public {
        Packet memory first = _pending(false);
        _attestOnly(first);
        bridge.pause(2);
        bridge.checkpoint(first.origin, first.guid, first.message);
        vm.expectRevert(abi.encodeWithSelector(LayerZeroEndpoint.LanePaused.selector, uint8(2)));
        bridge.executeCheckpointed(first.origin, first.guid, first.message);
        bridge.unpause(2);
        Packet memory second = _pending(false);
        _attestOnly(second);
        bridge.completeWithVerifications(second.origin, second.guid, second.message, _proof(first));
        bridge.complete(first.origin, first.guid, first.message);
        assertEq(wrapped.totalSupply(), 19.9 ether);
    }

    function test_TokenCallbackCannotCheckpointDuringAssetExecution() public {
        _mint(10 ether);
        bytes memory first = _redeem(1 ether, ALICE);
        bytes memory second = _redeem(1 ether, BOB);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(second, (Origin, bytes32, bytes));
        asset.setCallback(address(vault), abi.encodeCall(vault.checkpoint, (o, guid, message)));
        _complete(vault, first);
        assertFalse(asset.callbackSucceeded());
        assertEq(vault.checkpointedPayloads(guid), bytes32(0));
        asset.setCallback(address(0), "");
        _complete(vault, second);
    }

    function test_BatchCommitAllowsLaterDepositWithoutExecutingExpiredMetadata() public {
        Packet memory first = _pending(true);
        _attestOnly(first);
        vm.warp(block.timestamp + 31 days);
        Packet memory second = _pending(false);
        _attestOnly(second);
        vm.expectRevert("nonce gap");
        bridge.complete(second.origin, second.guid, second.message);
        bridge.completeWithVerifications(second.origin, second.guid, second.message, _proof(first));
        assertEq(wrapped.balanceOf(ALICE), 9.95 ether);
        assertFalse(bridge.consumedMessages(first.guid));
        assertTrue(bridge.consumedMessages(second.guid));
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        bridge.complete(first.origin, first.guid, first.message);
    }

    function test_UnattestedPredecessorCannotBeSkippedAndBatchRollsBack() public {
        Packet memory first = _pending(false);
        Packet memory second = _pending(false);
        _attestOnly(second);
        vm.expectRevert("missing attestations");
        bridge.completeWithVerifications(second.origin, second.guid, second.message, _proof(first));
        assertEq(wrapped.totalSupply(), 0);
        _attestOnly(first);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.completeWithVerifications(second.origin, bytes32(uint256(1)), second.message, _proof(first));
        assertEq(
            destinationCore.inboundPayloadHash(
                address(bridge), first.origin.srcEid, first.origin.sender, first.origin.nonce
            ),
            bytes32(0)
        );
        bridge.completeWithVerifications(second.origin, second.guid, second.message, _proof(first));
        bridge.complete(first.origin, first.guid, first.message);
        assertEq(wrapped.totalSupply(), 19.9 ether);
    }

    function test_CommitWhilePausedDoesNotMintAndSurvivesDeliveryFailure() public {
        Packet memory p = _pending(false);
        _attestOnly(p);
        bridge.pause(2);
        vm.prank(BOB);
        bridge.commitVerifications(_proof(p));
        assertEq(wrapped.totalSupply(), 0);
        assertFalse(bridge.consumedMessages(p.guid));
        vm.expectRevert(abi.encodeWithSelector(LayerZeroEndpoint.LanePaused.selector, uint8(2)));
        bridge.completeWithVerifications(p.origin, p.guid, p.message, _proof(p));
        bridge.unpause(2);
        bridge.complete(p.origin, p.guid, p.message);
    }

    function test_AlreadyCommittedOrConsumedPrerequisitesAreRaceSafe() public {
        Packet memory first = _pending(false);
        _attestOnly(first);
        LayerZeroEndpoint.Verification[] memory a = _proof(first);
        bridge.commitVerifications(a);
        bridge.commitVerifications(a);
        bridge.complete(first.origin, first.guid, first.message);
        Packet memory second = _pending(false);
        _attestOnly(second);
        bridge.completeWithVerifications(second.origin, second.guid, second.message, a);
        assertEq(wrapped.totalSupply(), 19.9 ether);
        vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeWithVerifications(second.origin, second.guid, second.message, a);
    }

    function test_BadProofsCannotCommitAndEmptyBatchIsHarmless() public {
        Packet memory p = _pending(false);
        _attestOnly(p);
        LayerZeroEndpoint.Verification[] memory a = _proof(p);
        a[0].payloadHash = bytes32(uint256(1));
        vm.expectRevert("missing attestations");
        bridge.commitVerifications(a);
        a[0].payloadHash = bytes32(0);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.commitVerifications(a);
        a[0].payloadHash = bytes32(type(uint256).max);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.commitVerifications(a);
        a = _proof(p);
        a[0].nonce = 0;
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.commitVerifications(a);
        a = new LayerZeroEndpoint.Verification[](0);
        bridge.completeWithVerifications(p.origin, p.guid, p.message, a);
        vm.chainId(999);
        vm.expectRevert(LayerZeroEndpoint.WrongEvmChain.selector);
        bridge.commitVerifications(a);
    }
}
