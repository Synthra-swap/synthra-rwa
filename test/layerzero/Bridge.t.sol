// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LayerZeroFixture} from "./Fixture.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";
import {LayerZeroMessage as Message} from "../../src/layerzero/LayerZeroMessage.sol";
import {Origin, MessagingReceipt, UlnConfig} from "../../src/layerzero/ILayerZero.sol";

contract RefundCallback {
    LayerZeroSourceVault immutable vault;
    bool public attempted;
    bool public reentered;

    constructor(LayerZeroSourceVault v) {
        vault = v;
    }

    function deposit() external payable {
        vault.asset().approve(address(vault), type(uint256).max);
        vault.deposit{value: msg.value}(1 ether, address(this));
    }

    receive() external payable {
        attempted = true;
        (reentered,) = address(vault).call(abi.encodeCall(vault.deposit, (1, address(this))));
    }
}

contract LayerZeroBridgeTest is LayerZeroFixture {
    function testFuzz_RoundTripConservesBacking(uint256 raw) public {
        uint256 gross = bound(raw, 1, 1000 ether);
        uint256 fee = gross / 200;
        _mint(gross);
        assertEq(wrapped.balanceOf(ALICE), gross - fee);
        assertEq(vault.locked(), gross - fee);
        assertEq(asset.balanceOf(TREASURY), fee);
        bytes memory redemption = _redeem(gross - fee, BOB);
        assertEq(wrapped.totalSupply(), 0);
        _complete(vault, redemption);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(BOB), gross - fee);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_ConfigurationPinsBothLibrariesAndTwoRequiredDVNs() public view {
        UlnConfig memory s =
            abi.decode(sourceCore.configs(address(vault), vault.sendLibrary(), 30417, 2), (UlnConfig));
        UlnConfig memory r =
            abi.decode(sourceCore.configs(address(vault), vault.receiveLibrary(), 30417, 2), (UlnConfig));
        assertEq(s.confirmations, 15);
        assertEq(r.confirmations, 20);
        assertEq(s.requiredDVNCount, 2);
        assertEq(r.requiredDVNCount, 2);
        assertEq(s.optionalDVNCount, 255);
        assertEq(r.optionalDVNCount, 255);
        assertLt(uint160(s.requiredDVNs[0]), uint160(s.requiredDVNs[1]));
        (uint32 size, address executor) =
            abi.decode(sourceCore.configs(address(vault), vault.sendLibrary(), 30417, 1), (uint32, address));
        assertEq(size, 384);
        assertEq(executor, address(vault));
        assertEq(vault.getFee(30417, address(vault), 384, hex"0003"), 0);
        assertEq(vault.assignJob(30417, address(vault), 384, hex"0003"), 0);
    }

    function test_PermissionlessDeliveryAndReplayRejected() public {
        bytes memory packet = _deposit(10 ether, BOB);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.prank(address(0xCAFE));
        bridge.complete(o, guid, message);
        assertEq(wrapped.balanceOf(BOB), 9.95 ether);
        vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
        bridge.complete(o, guid, message);
    }

    function test_NoAttestationCannotMint() public {
        vm.prank(ALICE);
        MessagingReceipt memory r = vault.deposit(10 ether, ALICE);
        bytes memory packet = sourceCore.published(address(vault), r.nonce);
        vm.chainId(5042);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.expectRevert("missing attestations");
        bridge.complete(o, guid, message);
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_OnlyEndpointCanInvokeReceiver() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.expectRevert(LayerZeroEndpoint.OnlyEndpoint.selector);
        bridge.lzReceive(o, guid, message, ALICE, "");
    }

    function test_TamperedPayloadCannotUseOriginalAttestation() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        Message.Transfer memory t = abi.decode(message, (Message.Transfer));
        t.recipient = BOB;
        vm.expectRevert("missing attestations");
        bridge.complete(o, guid, abi.encode(t));
        bridge.complete(o, guid, message);
        assertEq(wrapped.balanceOf(BOB), 0);
    }

    function testFuzz_AuthenticatedInvalidHeaderRejected(uint8 seed) public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        Message.Transfer memory t = abi.decode(message, (Message.Transfer));
        uint8 mutation = seed % 11;
        if (mutation == 0) t.header.domain = keccak256("synthra.rwa.bridge.v1");
        if (mutation == 1) t.header.version = 2;
        if (mutation == 2) t.header.action = Message.REDEEM;
        if (mutation == 3) t.header.sourceEvmChain++;
        if (mutation == 4) t.header.destinationEvmChain++;
        if (mutation == 5) t.header.destinationChain++;
        if (mutation == 6) t.header.destinationBridge = BOB;
        if (mutation == 7) t.header.originToken = BOB;
        if (mutation == 8) t.recipient = address(0);
        if (mutation == 9) t.recipient = address(wrapped);
        if (mutation == 10) t.amount = 0;
        message = abi.encode(t);
        destinationUln.attest(bridge.packetHeader(o), keccak256(abi.encodePacked(guid, message)));
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.complete(o, guid, message);
        assertFalse(bridge.consumedMessages(guid));
    }

    function test_WrongPeerEidGuidNonceAndChainRejected() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        o.srcEid++;
        vm.expectRevert(LayerZeroEndpoint.WrongEmitter.selector);
        bridge.complete(o, guid, message);
        o.srcEid--;
        o.sender = bytes32(uint256(123));
        vm.expectRevert(LayerZeroEndpoint.WrongEmitter.selector);
        bridge.complete(o, guid, message);
        o.sender = bytes32(uint256(uint160(address(vault))));
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.complete(o, bytes32(uint256(42)), message);
        o.nonce = 0;
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        bridge.complete(o, guid, message);
        vm.chainId(999);
        vm.expectRevert(LayerZeroEndpoint.WrongEvmChain.selector);
        bridge.complete(o, guid, message);
    }

    function test_PausedClaimResumesWithoutRepublishing() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        bridge.pause(2);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.expectRevert(abi.encodeWithSelector(LayerZeroEndpoint.LanePaused.selector, 2));
        bridge.complete(o, guid, message);
        assertFalse(bridge.consumedMessages(guid));
        bridge.unpause(2);
        bridge.complete(o, guid, message);
        assertEq(wrapped.totalSupply(), 9.95 ether);
    }

    function test_AlreadyCommittedMessageCanComplete() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        assertEq(
            destinationCore.inboundPayloadHash(address(bridge), o.srcEid, o.sender, o.nonce),
            keccak256(abi.encodePacked(guid, message))
        );
        bridge.complete(o, guid, message);
        assertEq(wrapped.totalSupply(), 9.95 ether);
    }

    function test_DirectEndpointExecutionAndReplayThroughWrapper() public {
        bytes memory packet = _deposit(10 ether, ALICE);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        assertEq(
            destinationCore.inboundPayloadHash(address(bridge), o.srcEid, o.sender, o.nonce),
            keccak256(abi.encodePacked(guid, message))
        );
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        destinationCore.lzReceive{value: 1}(o, address(bridge), guid, message, "");
        destinationCore.lzReceive(o, address(bridge), guid, message, "");
        vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
        bridge.complete(o, guid, message);
    }

    function test_OutgoingLimitDecreasePreservesPendingClaims() public {
        bytes memory packet = _deposit(1000 ether, ALICE);
        bridge.setMaxTransfer(1 ether);
        _complete(bridge, packet);
        assertEq(wrapped.balanceOf(ALICE), 995 ether);
        assertEq(bridge.inboundMaxTransfer(), 1000 ether);
        vm.expectRevert(LayerZeroEndpoint.TransferTooLarge.selector);
        bridge.quoteRedeemFee(2 ether, ALICE);
        bridge.prepareInboundMaxTransfer(2000 ether);
        bridge.setMaxTransfer(2000 ether);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        bridge.prepareInboundMaxTransfer(1000 ether);
    }

    function test_NoAggregateCapOrRefill() public {
        for (uint256 i; i < 4; ++i) {
            _mint(1000 ether);
        }
        assertEq(vault.locked(), 3980 ether);
        assertEq(wrapped.totalSupply(), 3980 ether);
    }

    function test_FeeFailureRollsBackDepositAndBurn() public {
        sourceCore.setFee(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(bytes("fee"));
        vault.deposit(100 ether, ALICE);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(TREASURY), 0);
        _mint(100 ether);
        destinationCore.setFee(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(bytes("fee"));
        bridge.redeem(1 ether, ALICE);
        assertEq(wrapped.balanceOf(ALICE), 99.5 ether);
    }

    function test_NativeFeeRefundGoesToCallerAndTreasuryRotationOnlyAffectsFutureFees() public {
        sourceCore.setFee(0.001 ether);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        vault.deposit{value: 0.01 ether}(100 ether, ALICE);
        assertEq(before - ALICE.balance, 0.001 ether);
        assertEq(address(vault).balance, 0);
        vault.setFeeRecipient(BOB);
        vm.prank(ALICE);
        vault.deposit{value: 0.001 ether}(100 ether, ALICE);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(asset.balanceOf(BOB), 0.5 ether);
        assertEq(vault.locked(), 199 ether);
    }

    function test_TaxedFrozenAndUnderbackedAssetsFailAtomically() public {
        asset.setTaxed(true);
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroSourceVault.UnsupportedTransfer.selector);
        vault.deposit(10 ether, ALICE);
        assertEq(vault.locked(), 0);
        asset.setTaxed(false);
        _mint(10 ether);
        bytes memory packet = _redeem(1 ether, BOB);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        asset.setFrozen(true);
        vm.expectRevert("issuer freeze");
        vault.complete(o, guid, message);
        assertFalse(vault.consumedMessages(guid));
        assertEq(vault.locked(), 9.95 ether);
        asset.setFrozen(false);
        asset.setTaxed(true);
        vm.expectRevert(LayerZeroSourceVault.UnsupportedTransfer.selector);
        vault.complete(o, guid, message);
        asset.setTaxed(false);
        vault.complete(o, guid, message);
        asset.seize(address(vault), 1);
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroSourceVault.InsufficientBacking.selector);
        vault.deposit(10 ether, ALICE);
    }

    function test_NativeRefundCannotReenterAccounting() public {
        RefundCallback caller = new RefundCallback(vault);
        asset.mint(address(caller), 2 ether);
        sourceCore.setFee(1);
        caller.deposit{value: 2}();
        assertTrue(caller.attempted());
        assertFalse(caller.reentered());
        assertEq(vault.locked(), 0.995 ether);
        assertEq(asset.balanceOf(TREASURY), 0.005 ether);
        assertEq(address(caller).balance, 1);
    }

    function test_AssetCallbackCannotReenterDeposit() public {
        asset.setCallback(address(vault), abi.encodeCall(vault.deposit, (1, ALICE)));
        _mint(10 ether);
        assertFalse(asset.callbackSucceeded());
        assertEq(vault.locked(), 9.95 ether);
    }

    function test_AssetCallbackCannotCompleteAnotherClaim() public {
        _mint(10 ether);
        bytes memory first = _redeem(1 ether, BOB);
        bytes memory second = _redeem(1 ether, BOB);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(second, (Origin, bytes32, bytes));
        asset.setCallback(address(vault), abi.encodeCall(vault.complete, (o, guid, message)));
        _complete(vault, first);
        assertFalse(asset.callbackSucceeded());
        assertFalse(vault.consumedMessages(guid));
        asset.setCallback(address(0), "");
        _complete(vault, second);
        assertEq(asset.balanceOf(BOB), 2 ether);
    }

    function test_MetadataOutOfOrderSplitAndStaleDoesNotBlockTokens() public {
        bytes memory oldPacket = _metadata();
        asset.setMultiplier(2 ether, 3 ether, block.timestamp + 1 days);
        bytes memory freshPacket = _metadata();
        _complete(bridge, freshPacket);
        _complete(bridge, oldPacket);
        assertEq(wrapped.uiMultiplier(), 2 ether);
        vm.warp(block.timestamp + 2 days);
        assertEq(wrapped.uiMultiplier(), 3 ether);
        vm.warp(block.timestamp + 30 days);
        assertFalse(wrapped.metadataFresh());
        vm.expectRevert(LayerZeroWrappedAsset.StaleMetadata.selector);
        wrapped.uiMultiplier();
        _mint(10 ether);
        vm.prank(ALICE);
        wrapped.transfer(BOB, 1 ether);
        _complete(vault, _redeem(1 ether, ALICE));
        _complete(bridge, _metadata());
        assertTrue(wrapped.metadataFresh());
        assertEq(wrapped.uiMultiplier(), 3 ether);
    }

    function test_StaleUndeliveredMetadataDoesNotBlockLaterDeposit() public {
        bytes memory packet = _metadata();
        vm.warp(block.timestamp + 31 days);
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(packet, (Origin, bytes32, bytes));
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        bridge.complete(o, guid, message);
        _mint(10 ether);
        _complete(bridge, _metadata());
        _complete(bridge, packet); // Older sequence now ignored, without overwriting the fresh snapshot.
        assertEq(wrapped.totalSupply(), 9.95 ether);
    }

    function test_BootstrapCannotReopenAndGuardianCannotResumeOrChangeFees() public {
        assertEq(vault.bootstrapper(), address(0));
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
        vault.activate();
        vm.expectRevert(LayerZeroEndpoint.PeerAlreadySet.selector);
        vault.setPeer(BOB, ALICE);
        vm.prank(GUARDIAN);
        vault.pause(3);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        vault.unpause(3);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        vault.setFeeRecipient(BOB);
        vault.unpause(3);
        vm.expectRevert(LayerZeroEndpoint.RenunciationDisabled.selector);
        vault.renounceOwnership();
    }

    function test_ConstructorRejectsInheritedOrNilConfirmations() public {
        LayerZeroEndpoint.Config memory c = _config(true);
        c.sendConfirmations = 0;
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(asset), TREASURY);
        c.sendConfirmations = type(uint64).max;
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(asset), TREASURY);
        c.sendConfirmations = 15;
        c.receiveConfirmations = type(uint64).max;
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(asset), TREASURY);
    }
}
