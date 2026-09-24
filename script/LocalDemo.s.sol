// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {MockWormholeCore} from "../test/mocks/MockWormholeCore.sol";
import {MockStockToken} from "../test/mocks/MockStockToken.sol";

/// @notice In-memory demo only. No broadcast, RPC, keys, real assets or real guardian attestations.
contract LocalDemo is Script {
    function run() external {
        address user = address(0xA11CE);
        vm.startPrank(user);
        MockWormholeCore source = new MockWormholeCore(100);
        MockWormholeCore destination = new MockWormholeCore(200);
        MockStockToken asset = new MockStockToken();
        SourceVault vault =
            new SourceVault(_config(address(source), 200, user), address(asset), address(0xFEE));
        DestinationBridge bridge = new DestinationBridge(
            _config(address(destination), 100, user), address(asset), "Synthra Mock Stock", "sMOCK", 1 days
        );
        vault.setPeer(address(bridge), address(bridge.wrappedAsset()));
        bridge.setPeer(address(vault), address(asset));
        vault.unpause(3);
        bridge.unpause(3);
        asset.mint(user, 10 ether);
        asset.approve(address(vault), 10 ether);

        uint64 sequence = vault.deposit(10 ether, user);
        console2.log(string.concat("Deposit pending - raw reserves: ", vm.toString(vault.locked())));
        console2.log(
            string.concat(
                "Deposit pending - wrapped supply: ", vm.toString(bridge.wrappedAsset().totalSupply())
            )
        );
        bytes memory message = source.published(address(vault), sequence);
        destination.attest(message);
        bridge.completeDeposit(message);
        console2.log(
            string.concat(
                "Deposit delivered - wrapped supply: ", vm.toString(bridge.wrappedAsset().totalSupply())
            )
        );

        sequence = bridge.redeem(4 ether, user);
        console2.log(string.concat("Burn pending - raw reserves: ", vm.toString(vault.locked())));
        console2.log(
            string.concat("Burn pending - wrapped supply: ", vm.toString(bridge.wrappedAsset().totalSupply()))
        );
        message = destination.published(address(bridge), sequence);
        source.attest(message);
        vault.completeRedemption(message);
        console2.log(string.concat("Redemption delivered - reserves: ", vm.toString(vault.locked())));
        console2.log(
            string.concat("Redemption delivered - supply: ", vm.toString(bridge.wrappedAsset().totalSupply()))
        );
        console2.log(string.concat("Original tokens returned: ", vm.toString(asset.balanceOf(user))));
        require(
            vault.locked() == 5.95 ether && bridge.wrappedAsset().totalSupply() == 5.95 ether,
            "demo accounting"
        );
        require(asset.balanceOf(user) == 4 ether, "demo redemption");
        require(asset.balanceOf(address(0xFEE)) == 0.05 ether, "demo fee");
        console2.log(string.concat("Fee paid immediately: ", vm.toString(asset.balanceOf(address(0xFEE)))));
        vm.stopPrank();
    }

    function _config(address core, uint16 remote, address owner)
        internal
        view
        returns (WormholeEndpoint.Config memory)
    {
        return WormholeEndpoint.Config(
            core,
            MockWormholeCore(core).chainId(),
            remote,
            block.chainid,
            block.chainid,
            1,
            1,
            owner,
            owner,
            1_000 ether
        );
    }
}
