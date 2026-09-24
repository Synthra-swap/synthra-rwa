// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract GovernanceTest is Fixture {
    function test_TimelockHasNoDeployerBypassAndGuardianCannotResume() public {
        address[] memory members = new address[](1);
        members[0] = address(this);
        TimelockController timelock = new TimelockController(2 days, members, members, address(0));
        WormholeEndpoint.Config memory c = _config(address(sourceCore), DESTINATION);
        c.owner = address(timelock);
        SourceVault governed = new SourceVault(c, address(asset), TREASURY);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        bytes memory peerCall = abi.encodeCall(governed.setPeer, (address(bridge), address(wrapped)));
        vm.expectRevert();
        governed.setPeer(address(bridge), address(wrapped));
        timelock.schedule(address(governed), 0, peerCall, bytes32(0), bytes32(uint256(1)), 2 days);
        vm.expectRevert();
        timelock.execute(address(governed), 0, peerCall, bytes32(0), bytes32(uint256(1)));
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(governed), 0, peerCall, bytes32(0), bytes32(uint256(1)));
        bytes memory resume = abi.encodeCall(governed.unpause, (uint8(3)));
        timelock.schedule(address(governed), 0, resume, bytes32(0), bytes32(uint256(2)), 2 days);
        vm.prank(GUARDIAN);
        governed.pause(3);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        governed.unpause(3);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(governed), 0, resume, bytes32(0), bytes32(uint256(2)));
        assertEq(governed.pausedLanes(), 0);
    }
}
