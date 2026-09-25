// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LayerZeroEndpoint} from "../src/layerzero/LayerZeroEndpoint.sol";
import {LayerZeroSourceVault} from "../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroDestinationBridge} from "../src/layerzero/LayerZeroDestinationBridge.sol";
import {ILayerZeroUln, Origin, MessagingReceipt, UlnConfig} from "../src/layerzero/ILayerZero.sol";
import {IScaledUIAmount} from "../src/interfaces/IScaledUIAmount.sol";

/// @notice Local forks: real issuer tokens, Endpoint and ULN libraries; balances and DVN attestations injected.
/// @dev Proves integration and quorum enforcement, not worker liveness or production finality.
contract LayerZeroLiveTest is Test {
    uint256 rhFork;
    uint256 arcFork;
    LayerZeroSourceVault vault;
    LayerZeroDestinationBridge bridge;
    address constant TREASURY = address(0xFEE);
    address constant RECEIVER = address(0xBEEF);

    function setUp() public {
        rhFork = vm.createSelectFork(
            vm.envOr("LZ_ROBINHOOD_RPC", string("https://rpc.mainnet.chain.robinhood.com"))
        );
        emit log_named_uint("Robinhood fork block", block.number);
        arcFork = vm.createSelectFork(vm.envOr("LZ_ARC_RPC", string("https://rpc.mainnet.arc.io")));
        emit log_named_uint("Arc fork block", block.number);
    }

    function _config(bool source) internal view returns (LayerZeroEndpoint.Config memory c) {
        string memory json = vm.readFile("config/layerzero.networks.example.json");
        string memory p = source ? ".robinhood." : ".arc.";
        c.endpoint = vm.parseJsonAddress(json, string.concat(p, "endpoint"));
        c.sendLibrary = vm.parseJsonAddress(json, string.concat(p, "sendLibrary"));
        c.receiveLibrary = vm.parseJsonAddress(json, string.concat(p, "receiveLibrary"));
        c.dvnA = vm.parseJsonAddress(json, string.concat(p, "dvnA"));
        c.dvnB = vm.parseJsonAddress(json, string.concat(p, "dvnB"));
        c.localEvmChain = source ? 4663 : 5042;
        c.remoteEvmChain = source ? 5042 : 4663;
        c.localEid = source ? 30416 : 30417;
        c.remoteEid = source ? 30417 : 30416;
        c.sendConfirmations = 15;
        c.receiveConfirmations = 15;
        c.owner = address(this);
        c.guardian = address(this);
        c.bootstrapper = address(this);
        c.maxTransfer = 1000 ether;
    }

    function _security(LayerZeroEndpoint app) internal view {
        UlnConfig memory s = ILayerZeroUln(app.sendLibrary()).getAppUlnConfig(address(app), app.remoteEid());
        UlnConfig memory r =
            ILayerZeroUln(app.receiveLibrary()).getAppUlnConfig(address(app), app.remoteEid());
        assertEq(s.confirmations, 15);
        assertEq(r.confirmations, 15);
        assertEq(s.requiredDVNCount, 2);
        assertEq(r.requiredDVNCount, 2);
        assertEq(s.optionalDVNCount, 255);
        assertEq(r.optionalDVNCount, 255);
        address low = app.dvnA() < app.dvnB() ? app.dvnA() : app.dvnB();
        address high = app.dvnA() < app.dvnB() ? app.dvnB() : app.dvnA();
        assertEq(s.requiredDVNs[0], low);
        assertEq(s.requiredDVNs[1], high);
        assertEq(r.requiredDVNs[0], low);
        assertEq(r.requiredDVNs[1], high);
    }

    function _message(address sender, MessagingReceipt memory receipt) internal returns (bytes memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == sender
                    && logs[i].topics[0] == keccak256("MessageSent(bytes32,uint64,bytes)")
            ) {
                assertEq(logs[i].topics[1], receipt.guid);
                assertEq(uint256(logs[i].topics[2]), receipt.nonce);
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("missing message");
    }

    function _deliver(
        LayerZeroEndpoint receiver,
        address sender,
        MessagingReceipt memory r,
        bytes memory message
    ) internal {
        Origin memory o = Origin(receiver.remoteEid(), bytes32(uint256(uint160(sender))), r.nonce);
        bytes memory header = receiver.packetHeader(o);
        bytes32 hash = keccak256(abi.encodePacked(r.guid, message));
        ILayerZeroUln uln = ILayerZeroUln(receiver.receiveLibrary());
        vm.expectRevert();
        receiver.complete(o, r.guid, message);
        vm.prank(receiver.dvnA());
        uln.verify(header, hash, 15);
        vm.expectRevert();
        receiver.complete(o, r.guid, message);
        vm.prank(receiver.dvnB());
        uln.verify(header, hash, 14);
        vm.expectRevert();
        receiver.complete(o, r.guid, message);
        vm.prank(receiver.dvnB());
        uln.verify(header, hash, 15);
        vm.expectRevert();
        receiver.complete(o, r.guid, abi.encodePacked(message, bytes1(0)));
        vm.prank(RECEIVER);
        receiver.complete(o, r.guid, message);
        assertTrue(receiver.consumedMessages(r.guid));
        vm.expectRevert(LayerZeroEndpoint.MessageAlreadyConsumed.selector);
        receiver.complete(o, r.guid, message);
    }

    function _exercise(uint256 index, string memory expected) internal {
        string memory json = vm.readFile("config/stock-assets.example.json");
        string memory p = string.concat(".assets[", vm.toString(index), "]");
        address token = vm.parseJsonAddress(json, string.concat(p, ".token"));
        vm.selectFork(rhFork);
        assertEq(IERC20Metadata(token).symbol(), expected);
        vault = new LayerZeroSourceVault(_config(true), token, TREASURY);
        _security(vault);
        deal(token, address(this), 100 ether);
        vm.deal(address(this), 100 ether);
        uint256 treasuryBefore = IERC20(token).balanceOf(TREASURY);
        uint256 multiplier = IScaledUIAmount(token).uiMultiplier();
        vm.selectFork(arcFork);
        vm.deal(address(this), 100 ether);
        bridge = new LayerZeroDestinationBridge(_config(false), token, "Fork stock", "sFORK", 30 days);
        bridge.bootstrapSetPeer(address(vault), token);
        bridge.activate();
        _security(bridge);
        address wrapped = address(bridge.wrappedAsset());
        vm.selectFork(rhFork);
        vault.bootstrapSetPeer(address(bridge), wrapped);
        vault.activate();
        IERC20(token).approve(address(vault), 100 ether);
        uint256 fee = vault.quoteDepositFee(100 ether, address(this));
        assertGt(fee, 0);
        vm.recordLogs();
        MessagingReceipt memory r = vault.deposit{value: fee}(100 ether, address(this));
        bytes memory message = _message(address(vault), r);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(IERC20(token).balanceOf(TREASURY) - treasuryBefore, 0.5 ether);
        vm.selectFork(arcFork);
        _deliver(bridge, address(vault), r, message);
        assertEq(bridge.wrappedAsset().balanceOf(address(this)), 99.5 ether);
        vm.selectFork(rhFork);
        fee = vault.quoteMetadataFee();
        vm.recordLogs();
        r = vault.publishMetadata{value: fee}();
        message = _message(address(vault), r);
        vm.selectFork(arcFork);
        _deliver(bridge, address(vault), r, message);
        assertEq(bridge.wrappedAsset().uiMultiplier(), multiplier);
        fee = bridge.quoteRedeemFee(99.5 ether, RECEIVER);
        assertGt(fee, 0);
        vm.recordLogs();
        r = bridge.redeem{value: fee}(99.5 ether, RECEIVER);
        message = _message(address(bridge), r);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
        vm.selectFork(rhFork);
        uint256 before = IERC20(token).balanceOf(RECEIVER);
        _deliver(vault, address(bridge), r, message);
        assertEq(IERC20(token).balanceOf(RECEIVER) - before, 99.5 ether);
        assertEq(vault.locked(), 0);
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
    }

    function _verifyOnly(LayerZeroEndpoint receiver, Origin memory o, bytes32 hash) internal {
        bytes memory header = receiver.packetHeader(o);
        ILayerZeroUln uln = ILayerZeroUln(receiver.receiveLibrary());
        vm.prank(receiver.dvnA());
        uln.verify(header, hash, 15);
        vm.prank(receiver.dvnB());
        uln.verify(header, hash, 15);
    }

    function test_VerifiedEarlierPacketNeedsCommitBeforeOutOfOrderDelivery() public {
        _ordering(false);
    }

    function test_CheckpointPreservesEarlierClaimOnRealEndpoint() public {
        _ordering(true);
    }

    function _ordering(bool checkpointFirst) private {
        _exercise(0, "NVDA");
        address token = address(vault.asset());
        deal(token, address(this), 100 ether);
        IERC20(token).approve(address(vault), 100 ether);
        uint256 fee = vault.quoteDepositFee(10 ether, address(this));
        vm.recordLogs();
        MessagingReceipt memory first = vault.deposit{value: fee}(10 ether, address(this));
        bytes memory a = _message(address(vault), first);
        vm.recordLogs();
        MessagingReceipt memory second = vault.deposit{value: fee}(10 ether, RECEIVER);
        bytes memory b = _message(address(vault), second);
        vm.selectFork(arcFork);
        Origin memory o = Origin(30416, bytes32(uint256(uint160(address(vault)))), first.nonce);
        _verifyOnly(bridge, o, keccak256(abi.encodePacked(first.guid, a)));
        o.nonce = second.nonce;
        _verifyOnly(bridge, o, keccak256(abi.encodePacked(second.guid, b)));
        vm.expectRevert(abi.encodeWithSignature("LZ_InvalidNonce(uint64)", first.nonce));
        bridge.complete(o, second.guid, b);
        if (checkpointFirst) {
            o.nonce = first.nonce;
            bridge.checkpoint(o, first.guid, a);
            assertEq(bridge.checkpointedPayloads(first.guid), keccak256(abi.encodePacked(first.guid, a)));
            assertFalse(bridge.consumedMessages(first.guid));
            o.nonce = second.nonce;
        }
        LayerZeroEndpoint.Verification[] memory prerequisites = new LayerZeroEndpoint.Verification[](1);
        prerequisites[0] =
            LayerZeroEndpoint.Verification(first.nonce, keccak256(abi.encodePacked(first.guid, a)));
        bridge.completeWithVerifications(o, second.guid, b, prerequisites);
        assertFalse(bridge.consumedMessages(first.guid));
        assertEq(bridge.wrappedAsset().balanceOf(RECEIVER), 9.95 ether);
        o.nonce = first.nonce;
        bridge.complete(o, first.guid, a);
    }

    function test_NVDA_RoundTripAndMetadata() public {
        _exercise(0, "NVDA");
    }

    function test_META_RoundTripAndMetadata() public {
        _exercise(1, "META");
    }

    function test_PLTR_RoundTripAndMetadata() public {
        _exercise(2, "PLTR");
    }

    function test_GOOGL_RoundTripAndMetadata() public {
        _exercise(3, "GOOGL");
    }

    function test_AAPL_RoundTripAndMetadata() public {
        _exercise(4, "AAPL");
    }

    function test_MSFT_RoundTripAndMetadata() public {
        _exercise(5, "MSFT");
    }

    function test_INTC_RoundTripAndMetadata() public {
        _exercise(6, "INTC");
    }

    function test_AMZN_RoundTripAndMetadata() public {
        _exercise(7, "AMZN");
    }

    function test_AMD_RoundTripAndMetadata() public {
        _exercise(8, "AMD");
    }

    function test_TSLA_RoundTripAndMetadata() public {
        _exercise(9, "TSLA");
    }

    function test_COIN_RoundTripAndMetadata() public {
        _exercise(10, "COIN");
    }

    function test_AVGO_RoundTripAndMetadata() public {
        _exercise(11, "AVGO");
    }
    receive() external payable {}
}
