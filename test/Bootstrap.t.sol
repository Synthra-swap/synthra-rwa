// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {ConfigHarness} from "./DeploymentConfig.t.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockWormholeCore} from "./mocks/MockWormholeCore.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract BootstrapTest is Test {
    address constant HARDWARE = address(0xA11CE);
    address constant GUARDIAN = address(0x900D);
    address constant REMOTE = address(0xCAFE);

    function _deploy(bool source)
        private
        returns (TimelockController governor, WormholeEndpoint endpoint, address token)
    {
        ConfigHarness harness = new ConfigHarness();
        Deploy.Parameters memory p = harness.parse(vm.readFile("config/deployment.example.json"));
        p.endpoint.core = address(new MockWormholeCore(100));
        p.endpoint.localChain = 100;
        p.endpoint.remoteChain = 200;
        p.endpoint.localEvmChain = block.chainid;
        p.endpoint.remoteEvmChain = block.chainid + 1;
        p.endpoint.guardian = GUARDIAN;
        p.governanceSafe = HARDWARE;
        token = address(new MockStockToken());
        p.asset = token;
        p.treasury = address(0xFEE);
        p.sourceSide = source;
        (address g, address e,) = harness.deploy(p);
        return (TimelockController(payable(g)), WormholeEndpoint(e), token);
    }

    function test_InitialBindingAndActivationImmediateOnBothSides() public {
        uint256 initialTime = block.timestamp;
        for (uint256 i; i < 2; ++i) {
            (TimelockController g, WormholeEndpoint e, address token) = _deploy(i == 0);
            assertEq(e.owner(), address(g));
            assertEq(g.getMinDelay(), 2 days);
            assertEq(e.bootstrapper(), HARDWARE);
            vm.startPrank(HARDWARE);
            e.bootstrapSetPeer(REMOTE, token);
            assertEq(e.pausedLanes(), 3, "binding must not activate either lane");
            e.activate();
            vm.stopPrank();
            assertEq(e.peer(), REMOTE);
            assertEq(e.remoteToken(), token);
            assertEq(e.bootstrapper(), address(0));
            assertEq(e.pausedLanes(), 0);
            assertEq(e.owner(), address(g));
            assertEq(g.getMinDelay(), 2 days);
            assertEq(block.timestamp, initialTime, "no timelock wait for initial setup");
        }
    }

    function test_GuardianDeployerAndOutsiderCannotUseFastSetup() public {
        for (uint256 i; i < 2; ++i) {
            (, WormholeEndpoint e, address token) = _deploy(i == 0);
            address[3] memory callers = [GUARDIAN, address(this), address(0xBAD)];
            for (uint256 j; j < callers.length; ++j) {
                vm.startPrank(callers[j]);
                vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
                e.bootstrapSetPeer(REMOTE, token);
                vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
                e.activate();
                vm.stopPrank();
            }
            assertEq(e.peer(), address(0));
            assertEq(e.pausedLanes(), 3);
        }
    }

    function test_NoActivationBeforeBindingAndInvalidBindingDoesNotConsumeAuthority() public {
        (, WormholeEndpoint e, address token) = _deploy(true);
        vm.startPrank(HARDWARE);
        vm.expectRevert(WormholeEndpoint.PeerNotSet.selector);
        e.activate();
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        e.bootstrapSetPeer(address(0), token);
        assertEq(e.bootstrapper(), HARDWARE);
        assertEq(e.pausedLanes(), 3);
        e.bootstrapSetPeer(REMOTE, token);
        vm.expectRevert(WormholeEndpoint.PeerAlreadySet.selector);
        e.bootstrapSetPeer(address(0xBAD), token);
        e.activate();
        vm.stopPrank();
    }

    function test_DestinationRequiresCorrectOriginalToken() public {
        (, WormholeEndpoint e,) = _deploy(false);
        vm.prank(HARDWARE);
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        e.bootstrapSetPeer(REMOTE, address(0xBAD));
        assertEq(e.peer(), address(0));
        assertEq(e.bootstrapper(), HARDWARE);
    }

    function test_PauseAfterInitialActivationCannotBeBypassedAndResumeRemainsDelayed() public {
        for (uint256 i; i < 2; ++i) {
            (TimelockController g, WormholeEndpoint e, address token) = _deploy(i == 0);
            vm.startPrank(HARDWARE);
            e.bootstrapSetPeer(REMOTE, token);
            e.activate();
            vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
            e.activate();
            vm.stopPrank();
            vm.prank(GUARDIAN);
            e.pause(3);
            vm.startPrank(HARDWARE);
            vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
            e.activate();
            vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
            e.bootstrapSetPeer(address(0xBAD), token);
            vm.expectRevert();
            e.unpause(3);
            bytes memory call = abi.encodeCall(e.unpause, (uint8(3)));
            g.schedule(address(e), 0, call, bytes32(0), bytes32(0), 2 days);
            vm.expectRevert();
            g.execute(address(e), 0, call, bytes32(0), bytes32(0));
            vm.warp(block.timestamp + 2 days);
            g.execute(address(e), 0, call, bytes32(0), bytes32(0));
            vm.stopPrank();
            assertEq(e.pausedLanes(), 0);
            assertEq(e.bootstrapper(), address(0));
        }
    }

    function test_OrdinaryPartialUnpauseAlsoPermanentlyClosesBootstrap() public {
        for (uint8 lane = 1; lane <= 3; ++lane) {
            (TimelockController g, WormholeEndpoint e, address token) = _deploy(true);
            vm.prank(HARDWARE);
            e.bootstrapSetPeer(REMOTE, token);
            vm.prank(address(g));
            e.unpause(lane);
            assertEq(e.bootstrapper(), address(0));
            vm.prank(GUARDIAN);
            e.pause(3);
            vm.prank(HARDWARE);
            vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
            e.activate();
        }
    }

    function test_BootstrapNeverAuthorizesFeeLimitGuardianOrOwnershipChanges() public {
        (, WormholeEndpoint e,) = _deploy(true);
        vm.startPrank(HARDWARE);
        vm.expectRevert();
        e.setMaxTransfer(1);
        vm.expectRevert();
        e.prepareInboundMaxTransfer(100 ether);
        vm.expectRevert();
        e.setGuardian(HARDWARE);
        vm.expectRevert();
        e.transferOwnership(HARDWARE);
        vm.expectRevert();
        e.disableBootstrap();
        vm.expectRevert();
        SourceVault(address(e)).setFeeRecipient(HARDWARE);
        vm.stopPrank();
        assertEq(e.bootstrapper(), HARDWARE);
    }

    function test_OwnershipNominationRevokesOldSetupAuthorityEvenIfCancelled() public {
        (TimelockController g, WormholeEndpoint e, address token) = _deploy(true);
        vm.prank(address(g));
        e.transferOwnership(address(0xABCD));
        assertEq(e.bootstrapper(), address(0));
        vm.prank(address(g));
        e.transferOwnership(address(0));
        assertEq(e.pendingOwner(), address(0));
        vm.prank(HARDWARE);
        vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
        e.bootstrapSetPeer(REMOTE, token);
    }

    function test_GovernanceCanCloseBootstrapWithoutActivating() public {
        (TimelockController g, WormholeEndpoint e, address token) = _deploy(true);
        vm.prank(address(g));
        e.disableBootstrap();
        assertEq(e.bootstrapper(), address(0));
        assertEq(e.pausedLanes(), 3);
        vm.prank(address(g));
        e.setPeer(REMOTE, token);
        vm.prank(HARDWARE);
        vm.expectRevert(WormholeEndpoint.UnauthorizedBootstrapper.selector);
        e.activate();
        vm.prank(address(g));
        e.unpause(3);
        assertEq(e.pausedLanes(), 0);
    }

    function test_InvalidUnpauseAndWrongChainLeaveBootstrapIntact() public {
        (TimelockController g, WormholeEndpoint e, address token) = _deploy(true);
        vm.prank(HARDWARE);
        e.bootstrapSetPeer(REMOTE, token);
        vm.prank(address(g));
        vm.expectRevert(WormholeEndpoint.InvalidConfiguration.selector);
        e.unpause(4);
        vm.chainId(block.chainid + 1);
        vm.prank(HARDWARE);
        vm.expectRevert(WormholeEndpoint.WrongEvmChain.selector);
        e.activate();
        assertEq(e.bootstrapper(), HARDWARE);
        assertEq(e.pausedLanes(), 3);
    }
}
