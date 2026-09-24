// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WrappedAsset} from "../src/WrappedAsset.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {MockWormholeCore} from "./mocks/MockWormholeCore.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

abstract contract Fixture is Test {
    uint16 internal constant SOURCE = 100;
    uint16 internal constant DESTINATION = 200;
    uint256 internal constant TEST_MAX_TRANSFER = 1_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant TREASURY = address(0xFEE);
    address internal constant GUARDIAN = address(0x900D);
    MockWormholeCore internal sourceCore;
    MockWormholeCore internal destinationCore;
    MockStockToken internal asset;
    SourceVault internal vault;
    DestinationBridge internal bridge;
    WrappedAsset internal wrapped;

    function setUp() public virtual {
        sourceCore = new MockWormholeCore(SOURCE);
        destinationCore = new MockWormholeCore(DESTINATION);
        asset = new MockStockToken();
        vault = new SourceVault(_config(address(sourceCore), DESTINATION), address(asset), TREASURY);
        bridge = new DestinationBridge(
            _config(address(destinationCore), SOURCE),
            address(asset),
            "Synthra Test Stock",
            "sTEST",
            _metadataMaxAge()
        );
        wrapped = bridge.wrappedAsset();
        vault.setPeer(address(bridge), address(bridge.wrappedAsset()));
        bridge.setPeer(address(vault), address(asset));
        vault.unpause(3);
        bridge.unpause(3);
        asset.mint(ALICE, 100 * TEST_MAX_TRANSFER);
        vm.prank(ALICE);
        asset.approve(address(vault), type(uint256).max);
        vm.deal(ALICE, 100 ether);
    }

    function _metadataMaxAge() internal pure virtual returns (uint256) {
        return 1 days;
    }

    function _config(address core, uint16 remote) internal view returns (WormholeEndpoint.Config memory c) {
        c = WormholeEndpoint.Config({
            core: core,
            localChain: MockWormholeCore(core).chainId(),
            remoteChain: remote,
            localEvmChain: block.chainid,
            remoteEvmChain: block.chainid,
            outboundConsistency: 1,
            inboundConsistency: 1,
            owner: address(this),
            guardian: GUARDIAN,
            maxTransfer: TEST_MAX_TRANSFER
        });
    }

    function _net(uint256 amount) internal pure returns (uint256) {
        return amount - amount / 200;
    }

    function _deposit(uint256 gross, address recipient) internal returns (bytes memory encoded) {
        uint256 fee = vault.messageFee();
        vm.prank(ALICE);
        uint64 seq = vault.deposit{value: fee}(gross, recipient);
        encoded = sourceCore.published(address(vault), seq);
        destinationCore.attest(encoded);
    }

    function _mint(uint256 gross) internal returns (bytes memory encoded) {
        encoded = _deposit(gross, ALICE);
        bridge.completeDeposit(encoded);
    }

    function _redeem(uint256 amount, address recipient) internal returns (bytes memory encoded) {
        uint256 fee = bridge.messageFee();
        vm.prank(ALICE);
        uint64 seq = bridge.redeem{value: fee}(amount, recipient);
        encoded = destinationCore.published(address(bridge), seq);
        sourceCore.attest(encoded);
    }

    function _metadata() internal returns (bytes memory encoded) {
        uint64 seq = vault.publishMetadata();
        encoded = sourceCore.published(address(vault), seq);
        destinationCore.attest(encoded);
    }
}
