// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {LayerZeroConfigHarness} from "./Deployment.t.sol";
import {DeployLayerZero} from "../../script/DeployLayerZero.s.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockLayerZero, MockReceiveUln} from "./MockLayerZero.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LayerZeroHardwareWalletGovernanceTest is Test {
    address private constant HARDWARE = address(0xA11CE);
    address private constant OUTSIDER = address(0xB0B);

    function _parameters(LayerZeroConfigHarness harness, bool sourceSide)
        private
        returns (DeployLayerZero.Parameters memory p)
    {
        vm.serializeJson("lz-governance", vm.readFile("config/layerzero.deployment.example.json"));
        vm.serializeUint("lz-governance", "sendConfirmations", 15);
        string memory json = vm.serializeUint("lz-governance", "receiveConfirmations", 20);
        p = harness.parse(json);
        MockLayerZero core = new MockLayerZero(30416);
        p.endpoint.endpoint = address(core);
        p.endpoint.sendLibrary = address(core);
        p.endpoint.receiveLibrary = address(new MockReceiveUln(core));
        p.endpoint.dvnA = address(core);
        p.endpoint.dvnB = p.endpoint.receiveLibrary;
        p.endpoint.localEvmChain = block.chainid;
        p.endpoint.remoteEvmChain = block.chainid + 1;
        p.endpoint.guardian = HARDWARE;
        p.governance = HARDWARE;
        p.asset = address(new MockStockToken());
        p.treasury = address(0xFEE);
        p.sourceSide = sourceSide;
    }

    function _deploy(bool sourceSide)
        private
        returns (TimelockController governor, LayerZeroEndpoint endpoint)
    {
        LayerZeroConfigHarness harness = new LayerZeroConfigHarness();
        (address g, address e,) = harness.deploy(_parameters(harness, sourceSide));
        return (TimelockController(payable(g)), LayerZeroEndpoint(e));
    }

    function test_SharedEOARolesKeepTimelockOwnershipOnBothSides() public {
        assertEq(HARDWARE.code.length, 0);
        for (uint256 side; side < 2; ++side) {
            (TimelockController governor, LayerZeroEndpoint endpoint) = _deploy(side == 0);
            assertEq(endpoint.owner(), address(governor));
            assertEq(endpoint.guardian(), HARDWARE);
            assertEq(endpoint.pausedLanes(), 3);
            assertEq(governor.getMinDelay(), 2 days);
            assertTrue(governor.hasRole(governor.PROPOSER_ROLE(), HARDWARE));
            assertTrue(governor.hasRole(governor.EXECUTOR_ROLE(), HARDWARE));
            assertTrue(governor.hasRole(governor.CANCELLER_ROLE(), HARDWARE));
            assertTrue(governor.hasRole(governor.DEFAULT_ADMIN_ROLE(), address(governor)));
            assertFalse(governor.hasRole(governor.DEFAULT_ADMIN_ROLE(), HARDWARE));
            assertFalse(governor.hasRole(governor.DEFAULT_ADMIN_ROLE(), address(this)));
            assertFalse(governor.hasRole(governor.EXECUTOR_ROLE(), address(0)));
            vm.prank(HARDWARE);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HARDWARE));
            endpoint.setMaxTransfer(1);
        }
    }

    function test_DeploymentAssignsOneTimeActivationToHardwareWalletOnBothSides() public {
        LayerZeroConfigHarness harness = new LayerZeroConfigHarness();
        for (uint256 side; side < 2; ++side) {
            DeployLayerZero.Parameters memory p = _parameters(harness, side == 0);
            (, address deployed,) = harness.deploy(p);
            LayerZeroEndpoint endpoint = LayerZeroEndpoint(deployed);
            assertEq(endpoint.bootstrapper(), HARDWARE);
            vm.prank(OUTSIDER);
            vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
            endpoint.activate();
            vm.startPrank(HARDWARE);
            endpoint.bootstrapSetPeer(address(0xCAFE), side == 0 ? address(0xBEEF) : p.asset);
            endpoint.activate();
            assertEq(endpoint.pausedLanes(), 0);
            assertEq(endpoint.bootstrapper(), address(0));
            endpoint.pause(3);
            vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
            endpoint.activate();
            assertEq(endpoint.pausedLanes(), 3);
            vm.stopPrank();
        }
    }

    function test_SharedWalletPausesImmediatelyButResumeWaitsForTimelock() public {
        (TimelockController governor, LayerZeroEndpoint endpoint) = _deploy(true);
        bytes memory bind = abi.encodeCall(endpoint.setPeer, (address(0xCAFE), address(0xBEEF)));
        bytes memory resume = abi.encodeCall(endpoint.unpause, (uint8(3)));
        vm.startPrank(HARDWARE);
        governor.schedule(address(endpoint), 0, bind, bytes32(0), bytes32(uint256(1)), 2 days);
        governor.schedule(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(2)), 2 days);
        vm.expectRevert();
        governor.execute(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(2)));
        vm.warp(block.timestamp + 2 days);
        governor.execute(address(endpoint), 0, bind, bytes32(0), bytes32(uint256(1)));
        governor.execute(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(2)));
        assertEq(endpoint.pausedLanes(), 0);
        endpoint.pause(3);
        assertEq(endpoint.pausedLanes(), 3);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HARDWARE));
        endpoint.unpause(3);
        governor.schedule(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(3)), 2 days);
        vm.expectRevert();
        governor.execute(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(3)));
        vm.warp(block.timestamp + 2 days);
        governor.execute(address(endpoint), 0, resume, bytes32(0), bytes32(uint256(3)));
        assertEq(endpoint.pausedLanes(), 0);
        vm.stopPrank();
        vm.prank(OUTSIDER);
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedGuardian.selector);
        endpoint.pause(3);
    }

    function test_TreasuryChangeCannotBypassDelayWithSharedWallet() public {
        (TimelockController governor, LayerZeroEndpoint endpoint) = _deploy(true);
        LayerZeroSourceVault vault = LayerZeroSourceVault(address(endpoint));
        bytes memory change = abi.encodeCall(vault.setFeeRecipient, (OUTSIDER));
        vm.prank(OUTSIDER);
        vm.expectRevert();
        governor.schedule(address(vault), 0, change, bytes32(0), bytes32(0), 2 days);
        vm.startPrank(HARDWARE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HARDWARE));
        vault.setFeeRecipient(OUTSIDER);
        governor.schedule(address(vault), 0, change, bytes32(0), bytes32(0), 2 days);
        vm.expectRevert();
        governor.execute(address(vault), 0, change, bytes32(0), bytes32(0));
        assertEq(vault.feeRecipient(), address(0xFEE));
        vm.warp(block.timestamp + 2 days);
        governor.execute(address(vault), 0, change, bytes32(0), bytes32(0));
        assertEq(vault.feeRecipient(), OUTSIDER);
        vm.stopPrank();
    }

    function test_ZeroAuthoritiesAndShortDelayRejectedBeforeDeployLayerZeroment() public {
        LayerZeroConfigHarness harness = new LayerZeroConfigHarness();
        for (uint256 side; side < 2; ++side) {
            DeployLayerZero.Parameters memory p = _parameters(harness, side == 0);
            p.governance = address(0);
            vm.expectRevert("zero governance or guardian");
            harness.deploy(p);
            p.governance = HARDWARE;
            p.endpoint.guardian = address(0);
            vm.expectRevert("zero governance or guardian");
            harness.deploy(p);
            p.endpoint.guardian = HARDWARE;
            p.delay = 2 days - 1;
            vm.expectRevert("minimum two-day governance delay");
            harness.deploy(p);
        }
    }
}
