// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// @notice Tests expansion and pair isolation with synthetic tokens, not real issuer compatibility.
contract AssetExpansionTest is Fixture {
    struct Pair {
        MockStockToken token;
        SourceVault source;
        DestinationBridge destination;
    }

    function _newPair() private returns (Pair memory p) {
        p.token = new MockStockToken();
        p.source = new SourceVault(_config(address(sourceCore), DESTINATION), address(p.token), TREASURY);
        p.destination = new DestinationBridge(
            _config(address(destinationCore), SOURCE), address(p.token), "Test asset", "TEST", 1 days
        );
        p.source.setPeer(address(p.destination), address(p.destination.wrappedAsset()));
        p.destination.setPeer(address(p.source), address(p.token));
        p.source.unpause(3);
        p.destination.unpause(3);
        p.token.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        p.token.approve(address(p.source), type(uint256).max);
    }

    function _depositPair(Pair memory p, uint256 gross) private returns (bytes memory vaa) {
        vm.prank(ALICE);
        uint64 sequence = p.source.deposit(gross, ALICE);
        vaa = sourceCore.published(address(p.source), sequence);
        destinationCore.attest(vaa);
    }

    function test_AddThirteenthAssetPreservesExistingTwelvePairs() public {
        Pair[] memory pairs = new Pair[](12);
        for (uint256 i; i < pairs.length; ++i) {
            pairs[i] = _newPair();
            pairs[i].destination.completeDeposit(_depositPair(pairs[i], (i + 1) * 1 ether));
        }

        Pair memory added = _newPair();
        added.destination.completeDeposit(_depositPair(added, 20 ether));
        vm.prank(ALICE);
        uint64 sequence = added.destination.redeem(19.9 ether, ALICE);
        bytes memory redemption = destinationCore.published(address(added.destination), sequence);
        sourceCore.attest(redemption);
        added.source.completeRedemption(redemption);
        assertEq(added.source.locked(), 0);
        assertEq(added.destination.wrappedAsset().totalSupply(), 0);
        assertEq(added.token.balanceOf(ALICE), 99.9 ether);

        for (uint256 i; i < pairs.length; ++i) {
            uint256 gross = (i + 1) * 1 ether;
            uint256 net = gross - gross / 200;
            assertEq(pairs[i].source.locked(), net);
            assertEq(pairs[i].token.balanceOf(address(pairs[i].source)), net);
            assertEq(pairs[i].token.balanceOf(TREASURY), gross / 200);
            assertEq(pairs[i].destination.wrappedAsset().balanceOf(ALICE), net);
            assertEq(pairs[i].source.peer(), address(pairs[i].destination));
            assertEq(pairs[i].destination.peer(), address(pairs[i].source));
        }
    }

    function test_OneAssetMessageCannotMintAnotherAndPairPauseIsIsolated() public {
        Pair memory first = _newPair();
        Pair memory second = _newPair();
        bytes memory firstVaa = _depositPair(first, 10 ether);
        vm.expectRevert(WormholeEndpoint.WrongEmitter.selector);
        second.destination.completeDeposit(firstVaa);
        assertEq(second.destination.wrappedAsset().totalSupply(), 0);

        vm.prank(GUARDIAN);
        first.destination.pause(2);
        bytes memory secondVaa = _depositPair(second, 20 ether);
        second.destination.completeDeposit(secondVaa);
        assertEq(second.destination.wrappedAsset().balanceOf(ALICE), 19.9 ether);
        assertEq(first.destination.wrappedAsset().totalSupply(), 0);

        first.destination.unpause(2);
        first.destination.completeDeposit(firstVaa);
        assertEq(first.destination.wrappedAsset().balanceOf(ALICE), 9.95 ether);
        assertEq(second.destination.wrappedAsset().balanceOf(ALICE), 19.9 ether);
    }
}
