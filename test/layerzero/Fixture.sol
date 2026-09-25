// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroDestinationBridge} from "../../src/layerzero/LayerZeroDestinationBridge.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";
import {Origin, MessagingReceipt} from "../../src/layerzero/ILayerZero.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockLayerZero, MockReceiveUln} from "./MockLayerZero.sol";

abstract contract LayerZeroFixture is Test {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant TREASURY = address(0xFEE);
    address constant GUARDIAN = address(0x900D);
    MockLayerZero sourceCore;
    MockLayerZero destinationCore;
    MockReceiveUln sourceUln;
    MockReceiveUln destinationUln;
    MockStockToken asset;
    LayerZeroSourceVault vault;
    LayerZeroDestinationBridge bridge;
    LayerZeroWrappedAsset wrapped;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        sourceCore = new MockLayerZero(30416);
        destinationCore = new MockLayerZero(30417);
        sourceUln = new MockReceiveUln(sourceCore);
        destinationUln = new MockReceiveUln(destinationCore);
        vm.chainId(4663);
        asset = new MockStockToken();
        vault = new LayerZeroSourceVault(_config(true), address(asset), TREASURY);
        vm.chainId(5042);
        bridge =
            new LayerZeroDestinationBridge(_config(false), address(asset), "Synthra Stock", "sSTK", 30 days);
        wrapped = bridge.wrappedAsset();
        bridge.bootstrapSetPeer(address(vault), address(asset));
        bridge.activate();
        vm.chainId(4663);
        vault.bootstrapSetPeer(address(bridge), address(wrapped));
        vault.activate();
        asset.mint(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        asset.approve(address(vault), type(uint256).max);
        vm.deal(ALICE, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _config(bool source) internal view returns (LayerZeroEndpoint.Config memory c) {
        c.endpoint = source ? address(sourceCore) : address(destinationCore);
        c.localEid = source ? 30416 : 30417;
        c.remoteEid = source ? 30417 : 30416;
        c.localEvmChain = source ? 4663 : 5042;
        c.remoteEvmChain = source ? 5042 : 4663;
        c.sendLibrary = c.endpoint;
        c.receiveLibrary = source ? address(sourceUln) : address(destinationUln);
        c.dvnA = address(sourceCore);
        c.dvnB = address(destinationCore);
        c.sendConfirmations = 15;
        c.receiveConfirmations = 20;
        c.owner = address(this);
        c.guardian = GUARDIAN;
        c.bootstrapper = address(this);
        c.maxTransfer = 1000 ether;
    }

    function _attest(LayerZeroEndpoint receiver, MockReceiveUln uln, bytes memory encoded) internal {
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(encoded, (Origin, bytes32, bytes));
        uln.attest(receiver.packetHeader(o), keccak256(abi.encodePacked(guid, message)));
        uln.commitVerification(receiver.packetHeader(o), keccak256(abi.encodePacked(guid, message)));
    }

    function _complete(LayerZeroEndpoint receiver, bytes memory encoded) internal {
        vm.chainId(receiver.deploymentChainId());
        (Origin memory o, bytes32 guid, bytes memory message) = abi.decode(encoded, (Origin, bytes32, bytes));
        receiver.complete(o, guid, message);
    }

    function _deposit(uint256 amount, address recipient) internal returns (bytes memory encoded) {
        vm.chainId(4663);
        uint256 fee = vault.quoteDepositFee(amount, recipient);
        vm.prank(ALICE);
        MessagingReceipt memory r = vault.deposit{value: fee}(amount, recipient);
        encoded = sourceCore.published(address(vault), r.nonce);
        vm.chainId(5042);
        _attest(bridge, destinationUln, encoded);
    }

    function _mint(uint256 amount) internal returns (bytes memory encoded) {
        encoded = _deposit(amount, ALICE);
        _complete(bridge, encoded);
    }

    function _redeem(uint256 amount, address recipient) internal returns (bytes memory encoded) {
        vm.chainId(5042);
        uint256 fee = bridge.quoteRedeemFee(amount, recipient);
        vm.prank(ALICE);
        MessagingReceipt memory r = bridge.redeem{value: fee}(amount, recipient);
        encoded = destinationCore.published(address(bridge), r.nonce);
        vm.chainId(4663);
        _attest(vault, sourceUln, encoded);
    }

    function _metadata() internal returns (bytes memory encoded) {
        vm.chainId(4663);
        MessagingReceipt memory r = vault.publishMetadata{value: vault.quoteMetadataFee()}();
        encoded = sourceCore.published(address(vault), r.nonce);
        vm.chainId(5042);
        _attest(bridge, destinationUln, encoded);
    }
    receive() external payable {}
}
