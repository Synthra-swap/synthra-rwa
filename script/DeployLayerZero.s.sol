// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LayerZeroSourceVault} from "../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroDestinationBridge} from "../src/layerzero/LayerZeroDestinationBridge.sol";
import {LayerZeroEndpoint} from "../src/layerzero/LayerZeroEndpoint.sol";

/// @notice Deploys ONE side, initially paused. Does not configure peers or activate any lane.
/// @dev Signing supplied by Foundry keystore/hardware wallet; no private keys in JSON or source.
contract DeployLayerZero is Script {
    struct Parameters {
        LayerZeroEndpoint.Config endpoint;
        address governance;
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
            p.governance != address(0) && p.endpoint.guardian != address(0), "zero governance or guardian"
        );
        require(p.delay >= 2 days, "minimum two-day governance delay");
        address[] memory members = new address[](1);
        members[0] = p.governance;
        vm.startBroadcast();
        governor = address(new TimelockController(p.delay, members, members, address(0)));
        p.endpoint.owner = governor;
        p.endpoint.bootstrapper = p.governance;
        if (p.sourceSide) {
            endpoint = address(new LayerZeroSourceVault(p.endpoint, p.asset, p.treasury));
        } else {
            LayerZeroDestinationBridge bridge =
                new LayerZeroDestinationBridge(p.endpoint, p.asset, p.name, p.symbol, p.maxAge);
            endpoint = address(bridge);
            wrapped = address(bridge.wrappedAsset());
        }
        vm.stopBroadcast();
        require(LayerZeroEndpoint(endpoint).pausedLanes() == 3, "deployment must stay paused");
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
        p.endpoint.endpoint = vm.parseJsonAddress(json, ".endpoint");
        p.endpoint.localEid = _eid(vm.parseJsonUint(json, ".localEid"));
        p.endpoint.remoteEid = _eid(vm.parseJsonUint(json, ".remoteEid"));
        p.endpoint.localEvmChain = vm.parseJsonUint(json, ".evmChain");
        p.endpoint.remoteEvmChain = vm.parseJsonUint(json, ".remoteEvmChain");
        p.endpoint.sendLibrary = vm.parseJsonAddress(json, ".sendLibrary");
        p.endpoint.receiveLibrary = vm.parseJsonAddress(json, ".receiveLibrary");
        p.endpoint.dvnA = vm.parseJsonAddress(json, ".dvnA");
        p.endpoint.dvnB = vm.parseJsonAddress(json, ".dvnB");
        p.endpoint.sendConfirmations = _confirmations(vm.parseJsonUint(json, ".sendConfirmations"));
        p.endpoint.receiveConfirmations = _confirmations(vm.parseJsonUint(json, ".receiveConfirmations"));
        p.endpoint.guardian = vm.parseJsonAddress(json, ".guardian");
        p.endpoint.maxTransfer = vm.parseJsonUint(json, ".maxTransferRaw");
        require(
            vm.parseJsonUint(json, ".inboundMaxTransferRaw") == p.endpoint.maxTransfer,
            "initial inbound maximum mismatch"
        );
        p.governance = vm.parseJsonAddress(json, ".governance");
        p.treasury = vm.parseJsonAddress(json, ".treasury");
        p.asset = vm.parseJsonAddress(json, ".sourceAsset");
        p.delay = vm.parseJsonUint(json, ".governanceDelaySeconds");
        p.maxAge = vm.parseJsonUint(json, ".metadataMaxAgeSeconds");
        p.sourceSide = vm.parseJsonBool(json, ".sourceSide");
        p.name = vm.parseJsonString(json, ".name");
        p.symbol = vm.parseJsonString(json, ".symbol");
    }

    function _eid(uint256 value) private pure returns (uint32) {
        require(value != 0 && value <= type(uint32).max, "invalid EID");
        return uint32(value);
    }

    function _confirmations(uint256 value) private pure returns (uint64) {
        require(value != 0 && value < type(uint64).max, "explicit nonzero confirmations required");
        return uint64(value);
    }
}
