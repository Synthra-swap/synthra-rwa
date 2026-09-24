// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {BridgeMessage} from "../src/BridgeMessage.sol";
import {IWormholeCore} from "../src/interfaces/IWormholeCore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract TransferLimitGovernanceTest is Fixture {
    event TransferLimitChanged(uint256 previous, uint256 next, uint256 inboundMaximum);
    event InboundTransferLimitRaised(uint256 previous, uint256 next);

    function setUp() public override {
        super.setUp();
        WormholeEndpoint.Config memory c = _config(address(sourceCore), DESTINATION);
        c.maxTransfer = 100 ether;
        vault = new SourceVault(c, address(asset), TREASURY);
        c = _config(address(destinationCore), SOURCE);
        c.maxTransfer = 100 ether;
        bridge = new DestinationBridge(c, address(asset), "Stock", "sSTK", 1 days);
        wrapped = bridge.wrappedAsset();
        vault.setPeer(address(bridge), address(wrapped));
        bridge.setPeer(address(vault), address(asset));
        vault.unpause(3);
        bridge.unpause(3);
        vm.prank(ALICE);
        asset.approve(address(vault), type(uint256).max);
    }

    function _changeBoth(uint256 next) private {
        if (next > vault.inboundMaxTransfer()) vault.prepareInboundMaxTransfer(next);
        if (next > bridge.inboundMaxTransfer()) bridge.prepareInboundMaxTransfer(next);
        vault.setMaxTransfer(next);
        bridge.setMaxTransfer(next);
    }

    function test_UsersGuardianAndTreasuryCannotChangeEitherMaximum() public {
        address[3] memory callers = [ALICE, GUARDIAN, TREASURY];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.setMaxTransfer(50 ether);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            bridge.setMaxTransfer(50 ether);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.prepareInboundMaxTransfer(200 ether);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            bridge.prepareInboundMaxTransfer(200 ether);
        }
    }

    function test_ZeroAndUnpreparedMaximumRejected() public {
        uint256[3] memory invalid = [uint256(0), 100 ether + 1, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
            vault.setMaxTransfer(invalid[i]);
        }
        assertEq(vault.maxTransfer(), 100 ether);
        assertEq(vault.inboundMaxTransfer(), 100 ether);
    }

    function test_IncomingCeilingCannotBeLoweredOrZeroed() public {
        vault.prepareInboundMaxTransfer(200 ether);
        uint256[4] memory invalid = [uint256(0), 1, 100 ether, 200 ether];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
            vault.prepareInboundMaxTransfer(invalid[i]);
        }
        assertEq(vault.inboundMaxTransfer(), 200 ether);
        assertEq(vault.maxTransfer(), 100 ether);
    }

    function test_ChangesNeedNoPauseAndNeverChangeLaneState() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit InboundTransferLimitRaised(100 ether, 200 ether);
        vault.prepareInboundMaxTransfer(200 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit TransferLimitChanged(100 ether, 200 ether, 200 ether);
        vault.setMaxTransfer(200 ether);
        assertEq(vault.pausedLanes(), 0);
        for (uint8 mask = 1; mask <= 3; ++mask) {
            vault.pause(mask);
            uint8 before = vault.pausedLanes();
            vault.setMaxTransfer(100 ether);
            assertEq(vault.pausedLanes(), before);
        }
    }

    function test_BothChangesRequireMatureTimelockWithoutPausingService() public {
        address[] memory members = new address[](1);
        members[0] = address(this);
        TimelockController timelock = new TimelockController(2 days, members, members, address(0));
        vault.transferOwnership(address(timelock));
        bytes memory accept = abi.encodeCall(vault.acceptOwnership, ());
        timelock.schedule(address(vault), 0, accept, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(vault), 0, accept, bytes32(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setMaxTransfer(50 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.prepareInboundMaxTransfer(200 ether);
        address[] memory targets = new address[](2);
        targets[0] = address(vault);
        targets[1] = address(vault);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(vault.prepareInboundMaxTransfer, (200 ether));
        calls[1] = abi.encodeCall(vault.setMaxTransfer, (200 ether));
        timelock.scheduleBatch(targets, values, calls, bytes32(0), bytes32(uint256(1)), 2 days);
        vm.expectRevert();
        timelock.executeBatch(targets, values, calls, bytes32(0), bytes32(uint256(1)));
        _mint(100 ether);
        assertEq(vault.maxTransfer(), 100 ether);
        vm.warp(block.timestamp + 2 days);
        timelock.executeBatch(targets, values, calls, bytes32(0), bytes32(uint256(1)));
        assertEq(vault.maxTransfer(), 200 ether);
        assertEq(vault.inboundMaxTransfer(), 200 ether);
        assertEq(vault.pausedLanes(), 0);
    }

    function test_RepeatedTransfersAndMaximumChangesHaveNoQuota() public {
        uint256 started = block.timestamp;
        for (uint256 i; i < 20; ++i) {
            _mint(100 ether);
        }
        _changeBoth(50 ether);
        for (uint256 i; i < 20; ++i) {
            _mint(50 ether);
        }
        assertEq(vault.locked(), 2985 ether);
        assertEq(wrapped.totalSupply(), vault.locked());
        assertEq(block.timestamp, started);
        assertEq(vault.pausedLanes(), 0);
    }

    function test_LoweringPreservesPendingDepositsBurnsAndReplayProtection() public {
        bytes memory pendingDeposit = _deposit(100 ether, ALICE);
        _mint(100 ether);
        bytes memory pendingReturn = _redeem(50 ether, ALICE);
        _changeBoth(10 ether);
        bridge.completeDeposit(pendingDeposit);
        vault.completeRedemption(pendingReturn);
        assertEq(vault.locked(), 149 ether);
        assertEq(wrapped.totalSupply(), 149 ether);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(pendingDeposit);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        vault.completeRedemption(pendingReturn);
        vm.prank(ALICE);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        vault.deposit(10 ether + 1, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        bridge.redeem(10 ether + 1, ALICE);
        vault.completeRedemption(_redeem(10 ether, ALICE));
        assertEq(vault.locked(), 139 ether);
        assertEq(vault.inboundMaxTransfer(), 100 ether);
    }

    function test_PrepareBothReceiversBeforeActivatingLargerRequestsWithoutPause() public {
        vault.prepareInboundMaxTransfer(500 ether);
        bridge.prepareInboundMaxTransfer(500 ether);
        assertEq(vault.maxTransfer(), 100 ether);
        assertEq(bridge.maxTransfer(), 100 ether);
        _mint(100 ether);
        vault.completeRedemption(_redeem(99.5 ether, ALICE));
        vault.setMaxTransfer(500 ether);
        _mint(500 ether); // Peer can receive immediately, even before raising its outgoing maximum.
        bridge.setMaxTransfer(500 ether);
        vault.completeRedemption(_redeem(497.5 ether, ALICE));
        assertEq(vault.locked(), 0);
        assertEq(wrapped.totalSupply(), 0);
        assertEq(vault.pausedLanes(), 0);
        assertEq(bridge.pausedLanes(), 0);
    }

    function test_LegacyCeilingStillRejectsLargerAuthenticatedMessage() public {
        _changeBoth(200 ether);
        _changeBoth(10 ether);
        IWormholeCore.VM memory m = abi.decode(_deposit(1 ether, ALICE), (IWormholeCore.VM));
        BridgeMessage.Transfer memory data = abi.decode(m.payload, (BridgeMessage.Transfer));
        data.amount = 200 ether + 1;
        m.payload = abi.encode(data);
        bytes memory encoded = abi.encode(m);
        destinationCore.attest(encoded);
        vm.expectRevert(WormholeEndpoint.TransferTooLarge.selector);
        bridge.completeDeposit(encoded);
        assertEq(bridge.inboundMaxTransfer(), 200 ether);
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_AllPendingLegacyMessagesCompleteWithoutWaitingAfterDecrease() public {
        uint256 started = block.timestamp;
        bytes[] memory pending = new bytes[](20);
        for (uint256 i; i < 20; ++i) {
            pending[i] = _deposit(100 ether, ALICE);
        }
        _changeBoth(10 ether);
        for (uint256 i; i < 20; ++i) {
            bridge.completeDeposit(pending[i]);
        }
        assertEq(wrapped.totalSupply(), 1990 ether);
        assertEq(vault.locked(), wrapped.totalSupply());
        assertEq(block.timestamp, started);
    }

    function attemptMaximumChangeFromTokenCallback() external {
        require(msg.sender == address(asset), "test token only");
        vault.setMaxTransfer(50 ether);
    }

    function attemptIncomingPreparationFromTokenCallback() external {
        require(msg.sender == address(asset), "test token only");
        vault.prepareInboundMaxTransfer(200 ether);
    }

    function test_MaximumCannotChangeThroughOwnerCallbackDuringDeposit() public {
        asset.setCallback(address(this), abi.encodeCall(this.attemptMaximumChangeFromTokenCallback, ()));
        _mint(100 ether);
        assertFalse(asset.callbackSucceeded());
        assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(vault.maxTransfer(), 100 ether);
    }

    function test_IncomingCeilingCannotChangeThroughOwnerCallbackDuringDeposit() public {
        asset.setCallback(address(this), abi.encodeCall(this.attemptIncomingPreparationFromTokenCallback, ()));
        _mint(100 ether);
        assertFalse(asset.callbackSucceeded());
        assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(vault.inboundMaxTransfer(), 100 ether);
    }

    function test_NoFormerCapacityOrUint128CeilingOnConfiguredMaximum() public {
        _changeBoth(type(uint256).max);
        assertEq(vault.maxTransfer(), type(uint256).max);
        assertEq(vault.inboundMaxTransfer(), type(uint256).max);
        _changeBoth(100 ether);
        _mint(100 ether);
        vault.completeRedemption(_redeem(99.5 ether, ALICE));
        assertEq(vault.locked(), 0);
    }

    function testFuzz_InboundCeilingNeverDecreasesAcrossChanges(uint256 first, uint256 second) public {
        first = bound(first, 1, type(uint256).max);
        second = bound(second, 1, type(uint256).max);
        _changeBoth(first);
        _changeBoth(second);
        uint256 expected = first > 100 ether ? first : 100 ether;
        if (second > expected) expected = second;
        assertEq(vault.maxTransfer(), second);
        assertEq(bridge.maxTransfer(), second);
        assertEq(vault.inboundMaxTransfer(), expected);
        assertEq(bridge.inboundMaxTransfer(), expected);
    }
}
