// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";

/// @notice Deploys ONE side, initially paused. Does not configure peers or activate any lane.
/// @dev Signing supplied by Foundry keystore/hardware wallet; no private keys in JSON or source.
contract Deploy is Script {
    struct Parameters {
        WormholeEndpoint.Config endpoint;
        // Legacy field name: accepts a governance EOA or contract, not only a Safe.
        address governanceSafe;
        address treasury;
        address asset;
        uint256 delay;
        uint256 maxAge;
        bool sourceSide;
        string name;
        string symbol;
    }

    function run() external returns (address governor, address endpoint, address wrapped) {
        string memory json = vm.readFile(vm.envString("DEPLOY_CONFIG"));
        return _deploy(_read(json));
    }

    function _deploy(Parameters memory p)
        internal
        returns (address governor, address endpoint, address wrapped)
    {
        require(p.endpoint.localEvmChain == block.chainid, "wrong EVM chain");
        require(p.endpoint.remoteEvmChain != block.chainid, "same EVM domains");
        require(
            p.governanceSafe != address(0) && p.endpoint.guardian != address(0), "zero governance or guardian"
        );
        require(p.delay >= 2 days, "minimum two-day governance delay");
        address[] memory members = new address[](1);
        members[0] = p.governanceSafe;
        vm.startBroadcast();
        governor = address(new TimelockController(p.delay, members, members, address(0)));
        p.endpoint.owner = governor;
        if (p.sourceSide) {
            endpoint = address(new SourceVault(p.endpoint, p.asset, p.treasury));
        } else {
            DestinationBridge bridge = new DestinationBridge(p.endpoint, p.asset, p.name, p.symbol, p.maxAge);
            endpoint = address(bridge);
            wrapped = address(bridge.wrappedAsset());
        }
        vm.stopBroadcast();
        require(WormholeEndpoint(endpoint).pausedLanes() == 3, "deployment must stay paused");
        console2.log(string.concat("Timelock: ", vm.toString(governor)));
        console2.log(string.concat("Endpoint: ", vm.toString(endpoint)));
        console2.log(string.concat("Wrapped: ", vm.toString(wrapped)));
    }

    function _read(string memory json) internal view returns (Parameters memory p) {
        require(!vm.keyExistsJson(json, ".capRaw"), "obsolete capRaw field");
        require(
            !vm.keyExistsJson(json, ".rateCapacityRaw") && !vm.keyExistsJson(json, ".refillSeconds"),
            "obsolete rate-limit fields"
        );
        p.endpoint.core = vm.parseJsonAddress(json, ".core");
        uint256 local = vm.parseJsonUint(json, ".wormholeChain");
        uint256 remote = vm.parseJsonUint(json, ".remoteWormholeChain");
        uint256 outLevel = vm.parseJsonUint(json, ".outboundConsistency");
        uint256 inLevel = vm.parseJsonUint(json, ".inboundConsistency");
        require(
            local <= type(uint16).max && remote <= type(uint16).max && outLevel <= 255 && inLevel <= 255,
            "narrowing overflow"
        );
        p.endpoint.localChain = uint16(local);
        p.endpoint.remoteChain = uint16(remote);
        p.endpoint.localEvmChain = vm.parseJsonUint(json, ".evmChain");
        p.endpoint.remoteEvmChain = vm.parseJsonUint(json, ".remoteEvmChain");
        p.endpoint.outboundConsistency = uint8(outLevel);
        p.endpoint.inboundConsistency = uint8(inLevel);
        p.endpoint.guardian = vm.parseJsonAddress(json, ".guardian");
        p.endpoint.maxTransfer = vm.parseJsonUint(json, ".maxTransferRaw");
        require(
            vm.parseJsonUint(json, ".inboundMaxTransferRaw") == p.endpoint.maxTransfer,
            "initial inbound maximum mismatch"
        );
        p.governanceSafe = vm.parseJsonAddress(json, ".governanceSafe");
        p.treasury = vm.parseJsonAddress(json, ".treasury");
        p.asset = vm.parseJsonAddress(json, ".sourceAsset");
        p.delay = vm.parseJsonUint(json, ".governanceDelaySeconds");
        p.maxAge = vm.parseJsonUint(json, ".metadataMaxAgeSeconds");
        p.sourceSide = vm.parseJsonBool(json, ".sourceSide");
        p.name = vm.parseJsonString(json, ".name");
        p.symbol = vm.parseJsonString(json, ".symbol");
    }
}
