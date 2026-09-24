// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WrappedAsset} from "../src/WrappedAsset.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {BridgeMessage} from "../src/BridgeMessage.sol";
import {IWormholeCore} from "../src/interfaces/IWormholeCore.sol";

contract BridgeTest is Fixture {
    function testFuzz_RoundTripAndImmediateFee(uint256 gross) public {
        gross = bound(gross, 1, TEST_MAX_TRANSFER);
        uint256 before = asset.balanceOf(ALICE);
        _mint(gross);
        uint256 net = _net(gross);
        assertEq(vault.locked(), net);
        assertEq(asset.balanceOf(TREASURY), gross - net);
        assertEq(wrapped.balanceOf(ALICE), net);
        assertEq(asset.balanceOf(address(vault)), net);
        vault.completeRedemption(_redeem(net, ALICE));
        assertEq(asset.balanceOf(ALICE), before - (gross - net));
        assertEq(vault.locked(), 0);
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_FeeExample100Becomes995() public {
        _mint(100 ether);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(wrapped.balanceOf(ALICE), 99.5 ether);
        vault.completeRedemption(_redeem(99.5 ether, BOB));
        assertEq(asset.balanceOf(BOB), 99.5 ether);
    }

    function test_FeeRounding() public view {
        (uint256 net, uint256 fee) = vault.quoteDeposit(199);
        assertEq(net, 199);
        assertEq(fee, 0);
        (net, fee) = vault.quoteDeposit(200);
        assertEq(net, 199);
        assertEq(fee, 1);
    }

    function test_ThirdPartyRelayAndPermissionlessTransfer() public {
        bridge.completeDeposit(_deposit(100 ether, BOB));
        vm.prank(BOB);
        wrapped.transfer(ALICE, 30 ether);
        bytes memory burn = _redeem(30 ether, BOB);
        vm.prank(address(0xBAD));
        vault.completeRedemption(burn);
        assertEq(asset.balanceOf(BOB), 30 ether);
        assertEq(wrapped.balanceOf(BOB), 69.5 ether);
    }

    function test_PendingAndOutOfOrder() public {
        bytes memory first = _deposit(10 ether, ALICE);
        bytes memory second = _deposit(20 ether, ALICE);
        assertEq(vault.locked(), 29.85 ether);
        assertEq(wrapped.totalSupply(), 0);
        bridge.completeDeposit(second);
        bytes memory burn = _redeem(5 ether, ALICE);
        assertEq(vault.locked(), wrapped.totalSupply() + 9.95 ether + 5 ether);
        bridge.completeDeposit(first);
        vault.completeRedemption(burn);
        assertEq(vault.locked(), wrapped.totalSupply());
    }

    function test_ReplayIndependentOfHashAndSignatures() public {
        bytes memory encoded = _mint(10 ether);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(encoded);
        IWormholeCore.VM memory m = abi.decode(encoded, (IWormholeCore.VM));
        m.hash = bytes32(uint256(42));
        encoded = abi.encode(m);
        destinationCore.attest(encoded);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(encoded);
    }

    function test_BurnReplay() public {
        _mint(10 ether);
        bytes memory encoded = _redeem(4 ether, ALICE);
        vault.completeRedemption(encoded);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        vault.completeRedemption(encoded);
    }

    function test_UnattestedRejected() public {
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(hex"1234");
    }

    function testFuzz_InvalidAuthenticatedMessages(uint8 field) public {
        field = uint8(bound(field, 0, 14));
        IWormholeCore.VM memory m = abi.decode(_deposit(10 ether, ALICE), (IWormholeCore.VM));
        BridgeMessage.Transfer memory t = abi.decode(m.payload, (BridgeMessage.Transfer));
        bytes4 expected = WormholeEndpoint.InvalidMessage.selector;
        if (field == 0) {
            m.emitterChainId = 999;
            expected = WormholeEndpoint.WrongEmitter.selector;
        }
        if (field == 1) {
            m.emitterAddress = bytes32(uint256(123));
            expected = WormholeEndpoint.WrongEmitter.selector;
        }
        if (field == 2) {
            m.consistencyLevel = 99;
            expected = WormholeEndpoint.WrongConsistency.selector;
        }
        if (field == 3) t.header.domain = bytes32(0);
        if (field == 4) t.header.version = 2;
        if (field == 5) t.header.action = BridgeMessage.REDEEM;
        if (field == 6) t.header.destinationChain = SOURCE;
        if (field == 7) t.header.destinationBridge = address(vault);
        if (field == 8) t.header.originToken = BOB;
        if (field == 9) t.recipient = address(0);
        if (field == 10) t.amount = 0;
        if (field == 11) t.recipient = address(bridge);
        if (field == 12) t.header.sourceEvmChain = 999;
        if (field == 13) t.header.destinationEvmChain = 999;
        if (field == 14) t.recipient = address(wrapped);
        m.payload = abi.encode(t);
        bytes memory encoded = abi.encode(m);
        destinationCore.attest(encoded);
        vm.expectRevert(expected);
        bridge.completeDeposit(encoded);
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_TrailingPayloadRejected() public {
        IWormholeCore.VM memory m = abi.decode(_deposit(1 ether, ALICE), (IWormholeCore.VM));
        m.payload = bytes.concat(m.payload, hex"00");
        bytes memory encoded = abi.encode(m);
        destinationCore.attest(encoded);
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        bridge.completeDeposit(encoded);
    }

    function test_PendingDepositsAccumulateWithoutSharedQuota() public {
        _deposit(TEST_MAX_TRANSFER, ALICE);
        _deposit(TEST_MAX_TRANSFER, ALICE);
        assertEq(vault.locked(), 2 * _net(TEST_MAX_TRANSFER));
        assertGt(vault.locked(), vault.maxTransfer());
        assertEq(asset.balanceOf(address(vault)), vault.locked());
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_PauseNewDepositsPreservesExit() public {
        bytes memory encoded = _deposit(10 ether, ALICE);
        vault.pause(1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WormholeEndpoint.LanePaused.selector, uint8(1)));
        vault.deposit(1, ALICE);
        bridge.completeDeposit(encoded);
        vault.completeRedemption(_redeem(9.95 ether, ALICE));
        assertEq(vault.locked(), 0);
    }

    function test_EmergencyGuardianCanPauseButCannotResume() public {
        bytes memory encoded = _deposit(10 ether, ALICE);
        vm.prank(GUARDIAN);
        bridge.pause(2);
        vm.expectRevert(abi.encodeWithSelector(WormholeEndpoint.LanePaused.selector, uint8(2)));
        bridge.completeDeposit(encoded);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        bridge.unpause(2);
        bridge.unpause(2);
        bridge.completeDeposit(encoded);
    }

    function test_PausedReleaseCanRetry() public {
        _mint(10 ether);
        bytes memory encoded = _redeem(9.95 ether, ALICE);
        vault.pause(2);
        vm.expectRevert(abi.encodeWithSelector(WormholeEndpoint.LanePaused.selector, uint8(2)));
        vault.completeRedemption(encoded);
        vault.unpause(2);
        vault.completeRedemption(encoded);
    }

    function test_UnauthorizedAdministration() public {
        vm.startPrank(BOB);
        vm.expectRevert();
        vault.unpause(3);
        vm.expectRevert(WormholeEndpoint.UnauthorizedGuardian.selector);
        vault.pause(3);
        vm.expectRevert();
        vault.setGuardian(BOB);
        vm.stopPrank();
        vm.expectRevert(WormholeEndpoint.RenunciationDisabled.selector);
        vault.renounceOwnership();
        vm.expectRevert(WormholeEndpoint.PeerAlreadySet.selector);
        vault.setPeer(BOB, address(wrapped));
    }

    function test_OwnerCannotMintOrBurn() public {
        vm.expectRevert(WrappedAsset.OnlyBridge.selector);
        wrapped.bridgeMint(ALICE, 1);
        vm.expectRevert(WrappedAsset.OnlyBridge.selector);
        wrapped.bridgeBurn(ALICE, 1);
    }

    function test_ThirdPartyCannotBurn() public {
        _mint(10 ether);
        vm.prank(BOB);
        vm.expectRevert();
        bridge.redeem(1 ether, BOB);
        assertEq(wrapped.balanceOf(ALICE), 9.95 ether);
    }

    function test_DonationsAreNotMintable() public {
        vm.prank(ALICE);
        asset.transfer(address(vault), 5 ether);
        _mint(10 ether);
        assertEq(asset.balanceOf(address(vault)), 14.95 ether);
        assertEq(vault.locked(), 9.95 ether);
    }

    function test_TaxedDepositRollsBack() public {
        asset.setTaxed(true);
        vm.prank(ALICE);
        vm.expectRevert(SourceVault.UnsupportedTransfer.selector);
        vault.deposit(10 ether, ALICE);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(TREASURY), 0);
    }

    function test_FailedFeeTransferRollsBackEverything() public {
        asset.setBlockedRecipient(TREASURY);
        vm.prank(ALICE);
        vm.expectRevert("blocked recipient");
        vault.deposit(100 ether, ALICE);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(sourceCore.nextSequence(address(vault)), 0);
    }

    function test_ReentrancyGuardRejectsTokenCallback() public {
        asset.setCallback(address(vault), abi.encodeCall(vault.deposit, (1, ALICE)));
        _mint(10 ether);
        assertFalse(asset.callbackSucceeded());
        assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    function test_TaxedReleaseRetry() public {
        _mint(10 ether);
        bytes memory encoded = _redeem(9.95 ether, ALICE);
        asset.setTaxed(true);
        vm.expectRevert(SourceVault.UnsupportedTransfer.selector);
        vault.completeRedemption(encoded);
        asset.setTaxed(false);
        vault.completeRedemption(encoded);
    }

    function test_IssuerFreezeRetry() public {
        _mint(10 ether);
        bytes memory encoded = _redeem(9.95 ether, ALICE);
        asset.setFrozen(true);
        vm.expectRevert("issuer freeze");
        vault.completeRedemption(encoded);
        asset.setFrozen(false);
        vault.completeRedemption(encoded);
    }

    function test_BackingDeficitBlocksExitsUntilRestored() public {
        _mint(10 ether);
        bytes memory encoded = _redeem(1 ether, ALICE);
        asset.seize(address(vault), 1);
        vm.expectRevert(SourceVault.InsufficientBacking.selector);
        vault.completeRedemption(encoded);
        asset.mint(address(vault), 1);
        vault.completeRedemption(encoded);
    }

    function test_PublishFailureRollsBackFeeDepositAndBurn() public {
        sourceCore.setFailPublish(true);
        vm.prank(ALICE);
        vm.expectRevert("mock publish failed");
        vault.deposit(10 ether, ALICE);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(TREASURY), 0);
        sourceCore.setFailPublish(false);
        _mint(10 ether);
        destinationCore.setFailPublish(true);
        vm.prank(ALICE);
        vm.expectRevert("mock publish failed");
        bridge.redeem(9.95 ether, ALICE);
        assertEq(wrapped.balanceOf(ALICE), 9.95 ether);
    }

    function test_NativeMessageFeesExactAndSeparate() public {
        sourceCore.setMessageFee(0.01 ether);
        destinationCore.setMessageFee(0.02 ether);
        _mint(10 ether);
        vault.completeRedemption(_redeem(9.95 ether, ALICE));
        assertEq(address(sourceCore).balance, 0.01 ether);
        assertEq(address(destinationCore).balance, 0.02 ether);
        assertEq(address(vault).balance, 0);
        assertEq(address(bridge).balance, 0);
    }

    function test_IncorrectNativeFeesRejected() public {
        sourceCore.setMessageFee(1);
        vm.startPrank(ALICE);
        vm.expectRevert(WormholeEndpoint.IncorrectMessageFee.selector);
        vault.deposit(1 ether, ALICE);
        vm.expectRevert(WormholeEndpoint.IncorrectMessageFee.selector);
        vault.deposit{value: 2}(1 ether, ALICE);
        vm.stopPrank();
    }

    function test_ZeroAndInvalidRecipient() public {
        vm.startPrank(ALICE);
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        vault.deposit(0, ALICE);
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        vault.deposit(1, address(0));
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        vault.deposit(1, address(bridge));
        vm.expectRevert(WormholeEndpoint.InvalidMessage.selector);
        vault.deposit(1, address(wrapped));
        vm.stopPrank();
    }

    function test_ChainChangeRejected() public {
        bytes memory m = _deposit(1, ALICE);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(WormholeEndpoint.WrongEvmChain.selector);
        bridge.completeDeposit(m);
    }

    function test_DefaultPausedAndPeerRequired() public {
        SourceVault fresh =
            new SourceVault(_config(address(sourceCore), DESTINATION), address(asset), TREASURY);
        assertEq(fresh.pausedLanes(), 3);
        vm.expectRevert(WormholeEndpoint.PeerNotSet.selector);
        fresh.unpause(3);
    }

    function test_RapidRoundTripsNeedNoRefillOrWaiting() public {
        uint256 started = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            _mint(TEST_MAX_TRANSFER);
            vault.completeRedemption(_redeem(_net(TEST_MAX_TRANSFER), ALICE));
        }
        assertEq(block.timestamp, started);
        assertEq(vault.locked(), 0);
        assertEq(wrapped.totalSupply(), 0);
        assertEq(asset.balanceOf(TREASURY), 20 * (TEST_MAX_TRANSFER - _net(TEST_MAX_TRANSFER)));
    }

    function test_ManyUsersCanDepositAndRedeemInSameBlockWithoutSharedQuota() public {
        uint256 started = block.timestamp;
        for (uint256 i; i < 32; ++i) {
            address user = address(uint160(0x1000 + i));
            asset.mint(user, TEST_MAX_TRANSFER);
            vm.startPrank(user);
            asset.approve(address(vault), TEST_MAX_TRANSFER);
            uint64 sequence = vault.deposit(TEST_MAX_TRANSFER, user);
            vm.stopPrank();
            bytes memory deposit = sourceCore.published(address(vault), sequence);
            destinationCore.attest(deposit);
            bridge.completeDeposit(deposit);
            assertEq(wrapped.balanceOf(user), _net(TEST_MAX_TRANSFER));
            vm.prank(user);
            sequence = bridge.redeem(_net(TEST_MAX_TRANSFER), user);
            bytes memory redemption = destinationCore.published(address(bridge), sequence);
            sourceCore.attest(redemption);
            vault.completeRedemption(redemption);
            assertEq(asset.balanceOf(user), _net(TEST_MAX_TRANSFER));
            assertEq(wrapped.balanceOf(user), 0);
        }
        assertEq(block.timestamp, started);
        assertEq(vault.locked(), 0);
        assertEq(wrapped.totalSupply(), 0);
        assertEq(asset.balanceOf(TREASURY), 32 * (TEST_MAX_TRANSFER - _net(TEST_MAX_TRANSFER)));
    }

    function test_TransferMaximumChecked() public {
        vm.prank(ALICE);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        vault.deposit(TEST_MAX_TRANSFER + 1, ALICE);
    }

    function test_CoreDomainMismatchRejectedAtConstruction() public {
        WormholeEndpoint.Config memory c = _config(address(sourceCore), DESTINATION);
        c.localChain = 99;
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        new SourceVault(c, address(asset), TREASURY);
    }
}
