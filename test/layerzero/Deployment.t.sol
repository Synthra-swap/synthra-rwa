// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {DeployLayerZero} from "../../script/DeployLayerZero.s.sol";
import {LayerZeroFixture} from "./Fixture.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";

contract LayerZeroConfigHarness is DeployLayerZero {
    function deploy(Parameters memory p) external returns (address, address, address) {
        return _deploy(p);
    }

    function parse(string memory json) external view returns (Parameters memory) {
        return _read(json);
    }
}

contract LayerZeroDeploymentTest is LayerZeroFixture {
    function test_TemplateCannotSilentlySelectProductionFinality() public {
        LayerZeroConfigHarness harness = new LayerZeroConfigHarness();
        string memory json = vm.readFile("config/layerzero.deployment.example.json");
        vm.expectRevert("explicit nonzero confirmations required");
        harness.parse(json);
    }

    function test_ParserRejectsNarrowingAndPreservesAmounts() public {
        LayerZeroConfigHarness harness = new LayerZeroConfigHarness();
        vm.serializeJson("lz", vm.readFile("config/layerzero.deployment.example.json"));
        vm.serializeUint("lz", "sendConfirmations", 15);
        string memory json = vm.serializeUint("lz", "receiveConfirmations", 20);
        DeployLayerZero.Parameters memory p = harness.parse(json);
        assertEq(p.endpoint.maxTransfer, 10 ether);
        assertEq(p.endpoint.sendConfirmations, 15);
        assertEq(p.endpoint.receiveConfirmations, 20);
        json = vm.serializeUint("lz", "localEid", uint256(type(uint32).max) + 1);
        vm.expectRevert("invalid EID");
        harness.parse(json);
        vm.serializeUint("lz", "localEid", 30416);
        json = vm.serializeUint("lz", "receiveConfirmations", type(uint64).max);
        vm.expectRevert("explicit nonzero confirmations required");
        harness.parse(json);
    }

    function test_InitialActivationImmediateAndPermanentlyClosesBootstrap() public {
        LayerZeroSourceVault fresh = new LayerZeroSourceVault(_config(true), address(asset), TREASURY);
        assertEq(fresh.pausedLanes(), 3);
        vm.expectRevert(LayerZeroEndpoint.PeerNotSet.selector);
        fresh.activate();
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
        fresh.bootstrapSetPeer(address(bridge), address(wrapped));
        fresh.bootstrapSetPeer(address(bridge), address(wrapped));
        fresh.activate();
        assertEq(fresh.pausedLanes(), 0);
        fresh.pause(3);
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
        fresh.activate();
    }

    function test_PartialUnpauseOwnershipNominationAndDisableCloseBootstrap() public {
        for (uint256 i; i < 3; ++i) {
            LayerZeroSourceVault fresh = new LayerZeroSourceVault(_config(true), address(asset), TREASURY);
            fresh.bootstrapSetPeer(address(bridge), address(wrapped));
            if (i == 0) fresh.unpause(1);
            if (i == 1) fresh.transferOwnership(BOB);
            if (i == 2) fresh.disableBootstrap();
            assertEq(fresh.bootstrapper(), address(0));
            vm.expectRevert(LayerZeroEndpoint.UnauthorizedBootstrapper.selector);
            fresh.activate();
        }
    }
}
