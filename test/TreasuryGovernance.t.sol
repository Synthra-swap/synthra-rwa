// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TreasuryGovernanceTest is Fixture {
    event FeeRecipientChanged(address indexed previous, address indexed next);

    function _timelockOwnsVault() private returns (TimelockController timelock) {
        address[] memory members = new address[](1);
        members[0] = address(this);
        timelock = new TimelockController(2 days, members, members, address(0));
        vault.transferOwnership(address(timelock));
        bytes memory accept = abi.encodeCall(vault.acceptOwnership, ());
        timelock.schedule(address(vault), 0, accept, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(vault), 0, accept, bytes32(0), bytes32(0));
    }

    function test_UsersGuardianAndTreasuryCannotRedirectFees() public {
        address[3] memory callers = [ALICE, GUARDIAN, TREASURY];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vault.setFeeRecipient(BOB);
        }
        assertEq(vault.feeRecipient(), TREASURY);
    }

    function test_InvalidTreasuriesRejectedWithoutChangingRecipient() public {
        address[3] memory invalid = [address(0), address(vault), address(asset)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
            vault.setFeeRecipient(invalid[i]);
            assertEq(vault.feeRecipient(), TREASURY);
        }
    }

    function test_RotationAffectsFutureFeesOnlyAndPreservesPendingClaimAndBacking() public {
        bytes memory pending = _deposit(100 ether, ALICE);
        vault.pause(1);
        vm.expectEmit(true, true, false, true, address(vault));
        emit FeeRecipientChanged(TREASURY, BOB);
        vault.setFeeRecipient(BOB);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(asset.balanceOf(address(vault)), 99.5 ether);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(asset.balanceOf(BOB), 0);

        bridge.completeDeposit(pending);
        vault.unpause(1);
        _mint(100 ether);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(asset.balanceOf(BOB), 0.5 ether);
        assertEq(vault.locked(), 199 ether);
        assertEq(wrapped.totalSupply(), 199 ether);
        vault.completeRedemption(_redeem(199 ether, ALICE));
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(asset.balanceOf(BOB), 0.5 ether);
        assertEq(vault.FEE_BPS(), 50);
    }

    function test_BlockedReplacementRollsBackAndRotationRestoresDeposits() public {
        vault.setFeeRecipient(BOB);
        asset.setBlockedRecipient(BOB);
        uint256 balanceBefore = asset.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert("blocked recipient");
        vault.deposit(100 ether, ALICE);
        assertEq(asset.balanceOf(ALICE), balanceBefore);
        assertEq(vault.locked(), 0);
        assertEq(sourceCore.nextSequence(address(vault)), 0);
        vault.setFeeRecipient(TREASURY);
        _mint(100 ether);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(vault.locked(), 99.5 ether);
    }

    function test_TreasuryChangeRequiresMatureTimelockOperation() public {
        TimelockController timelock = _timelockOwnsVault();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setFeeRecipient(BOB);
        bytes memory change = abi.encodeCall(vault.setFeeRecipient, (BOB));
        timelock.schedule(address(vault), 0, change, bytes32(0), bytes32(0), 2 days);
        vm.expectRevert();
        timelock.execute(address(vault), 0, change, bytes32(0), bytes32(0));
        assertEq(vault.feeRecipient(), TREASURY);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(vault), 0, change, bytes32(0), bytes32(0));
        assertEq(vault.feeRecipient(), BOB);
        _mint(100 ether);
        assertEq(asset.balanceOf(BOB), 0.5 ether);
        assertEq(vault.locked(), 99.5 ether);
    }

    function attemptFeeChangeFromTokenCallback() external {
        require(msg.sender == address(asset), "test token only");
        vault.setFeeRecipient(BOB);
    }

    function test_TreasuryCannotChangeDuringDepositEvenThroughOwnerCallback() public {
        asset.setCallback(address(this), abi.encodeCall(this.attemptFeeChangeFromTokenCallback, ()));
        _mint(100 ether);
        assertFalse(asset.callbackSucceeded());
        assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(vault.feeRecipient(), TREASURY);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
        assertEq(asset.balanceOf(BOB), 0);
        assertEq(vault.locked(), 99.5 ether);
    }

    function test_GuardianPauseIsImmediateEvenWithTimelockOwner() public {
        _timelockOwnsVault();
        uint256 beforePause = block.timestamp;
        vm.prank(GUARDIAN);
        vault.pause(3);
        assertEq(block.timestamp, beforePause);
        assertEq(vault.pausedLanes(), 3);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WormholeEndpoint.LanePaused.selector, uint8(1)));
        vault.deposit(1 ether, ALICE);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        vault.unpause(3);
    }
}
