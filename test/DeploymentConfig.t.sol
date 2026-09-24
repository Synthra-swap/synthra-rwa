// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockWormholeCore} from "./mocks/MockWormholeCore.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract ConfigHarness is Deploy {
    function deploy(Parameters memory p) external returns (address, address, address) {
        return _deploy(p);
    }

    function parse(string memory json) external view returns (Parameters memory) {
        return _read(json);
    }
}

contract DeploymentConfigTest is Test {
    function test_DecimalStringsPreserveRawTokenPrecision() public {
        ConfigHarness harness = new ConfigHarness();
        Deploy.Parameters memory p = harness.parse(vm.readFile("config/deployment.example.json"));
        assertEq(p.endpoint.maxTransfer, 10 ether);
        assertEq(p.delay, 2 days);
        assertEq(p.maxAge, 30 days);
        assertTrue(p.sourceSide);
    }

    function test_ObsoleteCapConfigRejectedBeforeDeployment() public {
        ConfigHarness harness = new ConfigHarness();
        vm.expectRevert("obsolete capRaw field");
        harness.parse('{"capRaw":"1000"}');
    }

    function test_ObsoleteRateConfigRejectedBeforeDeployment() public {
        ConfigHarness harness = new ConfigHarness();
        vm.expectRevert("obsolete rate-limit fields");
        harness.parse('{"rateCapacityRaw":"1000"}');
        vm.expectRevert("obsolete rate-limit fields");
        harness.parse('{"refillSeconds":3600}');
    }

    function test_NewDeploymentRejectsHistoricalCeilingDifferentFromInitialMaximum() public {
        ConfigHarness harness = new ConfigHarness();
        vm.serializeJson("limits", vm.readFile("config/deployment.example.json"));
        string memory changed = vm.serializeUint("limits", "inboundMaxTransferRaw", 20 ether);
        vm.expectRevert("initial inbound maximum mismatch");
        harness.parse(changed);
    }

    function test_ValidDeploymentCreatesTimelockOwnedPausedEndpoints() public {
        ConfigHarness harness = new ConfigHarness();
        MockWormholeCore core = new MockWormholeCore(100);
        MockStockToken token = new MockStockToken();
        Deploy.Parameters memory p = harness.parse(vm.readFile("config/deployment.example.json"));
        p.endpoint.core = address(core);
        p.endpoint.localChain = 100;
        p.endpoint.remoteChain = 200;
        p.endpoint.localEvmChain = block.chainid;
        p.endpoint.remoteEvmChain = block.chainid + 1;
        p.endpoint.guardian = address(token);
        p.governanceSafe = address(this);
        p.asset = address(token);
        p.treasury = address(0xFEE);
        (address governor, address endpoint, address wrapped) = harness.deploy(p);
        assertEq(WormholeEndpoint(endpoint).owner(), governor);
        assertEq(WormholeEndpoint(endpoint).peer(), address(0));
        assertEq(WormholeEndpoint(endpoint).pausedLanes(), 3);
        assertEq(SourceVault(endpoint).feeRecipient(), p.treasury);
        assertEq(WormholeEndpoint(endpoint).maxTransfer(), p.endpoint.maxTransfer);
        assertEq(WormholeEndpoint(endpoint).inboundMaxTransfer(), p.endpoint.maxTransfer);
        assertEq(wrapped, address(0));
        p.sourceSide = false;
        (governor, endpoint, wrapped) = harness.deploy(p);
        assertEq(WormholeEndpoint(endpoint).owner(), governor);
        assertEq(WormholeEndpoint(endpoint).pausedLanes(), 3);
        assertEq(address(DestinationBridge(endpoint).wrappedAsset()), wrapped);
        assertEq(DestinationBridge(endpoint).wrappedAsset().metadataMaxAge(), 30 days);
    }

    function test_PlaceholderDeploymentFailsBeforeBroadcast() public {
        Deploy deployer = new Deploy();
        vm.setEnv("DEPLOY_CONFIG", "config/deployment.example.json");
        vm.expectRevert("wrong EVM chain");
        deployer.run();
    }
}
