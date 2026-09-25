// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LayerZeroFixture} from "./Fixture.sol";
import {LayerZeroEndpoint} from "../../src/layerzero/LayerZeroEndpoint.sol";
import {LayerZeroSourceVault} from "../../src/layerzero/LayerZeroSourceVault.sol";
import {LayerZeroDestinationBridge} from "../../src/layerzero/LayerZeroDestinationBridge.sol";
import {LayerZeroMessage as Message} from "../../src/layerzero/LayerZeroMessage.sol";
import {LayerZeroWrappedAsset} from "../../src/layerzero/LayerZeroWrappedAsset.sol";
import {Origin} from "../../src/layerzero/ILayerZero.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SixDecimals is MockStockToken {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ExtraDebit is ERC20 {
    constructor() ERC20("Extra debit test token", "EXTRA") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
    address public charged;

    function setCharged(address account) external {
        charged = account;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == charged && to != address(0)) _burn(from, 1);
    }
}

contract LayerZeroSecurityTest is LayerZeroFixture {
    function test_TaxedSubFeeDepositCannotCreateUnbackedLiability() public {
        asset.setTaxed(true);
        (uint256 net, uint256 fee) = vault.quoteDeposit(199);
        assertEq(net, 199);
        assertEq(fee, 0);
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroSourceVault.UnsupportedTransfer.selector);
        vault.deposit(199, ALICE);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_ExtraSenderDebitRollsBackGrossDepositAndFee() public {
        ExtraDebit token = new ExtraDebit();
        LayerZeroSourceVault fresh = new LayerZeroSourceVault(_config(true), address(token), TREASURY);
        fresh.setPeer(address(bridge), address(wrapped));
        fresh.activate();
        token.setCharged(address(fresh));
        token.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(address(fresh), 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroSourceVault.UnsupportedTransfer.selector);
        fresh.deposit(100 ether, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(fresh.locked(), 0);
    }

    function test_ZeroCurrentAndPendingSnapshotCannotBecomeFresh() public {
        _complete(bridge, _metadata());
        vm.prank(address(bridge));
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        wrapped.applySnapshot(2, block.timestamp, 0, 0, 0);
        vm.prank(address(bridge));
        vm.expectRevert(LayerZeroWrappedAsset.InvalidSnapshot.selector);
        wrapped.applySnapshot(2, block.timestamp, 1 ether, 0, block.timestamp + 1);
        assertEq(wrapped.uiMultiplier(), 1 ether);
    }

    function test_ConstructorRejectsEveryInvalidEndpointConfiguration() public {
        for (uint256 i; i < 20; ++i) {
            LayerZeroEndpoint.Config memory c = _config(true);
            if (i == 0) c.endpoint = ALICE;
            if (i == 1) c.sendLibrary = ALICE;
            if (i == 2) c.receiveLibrary = ALICE;
            if (i == 3) c.sendLibrary = c.receiveLibrary;
            if (i == 4) c.dvnA = ALICE;
            if (i == 5) c.dvnB = ALICE;
            if (i == 6) c.dvnA = c.dvnB;
            if (i == 7) c.guardian = address(0);
            if (i == 8) c.localEvmChain++;
            if (i == 9) c.remoteEvmChain = 0;
            if (i == 10) c.remoteEvmChain = c.localEvmChain;
            if (i == 11) c.localEid = 0;
            if (i == 12) c.remoteEid = 0;
            if (i == 13) c.remoteEid = c.localEid;
            if (i == 14) c.maxTransfer = 0;
            if (i == 15) c.sendConfirmations = 0;
            if (i == 16) c.receiveConfirmations = 0;
            if (i == 17) c.sendConfirmations = type(uint64).max;
            if (i == 18) c.receiveConfirmations = type(uint64).max;
            if (i == 19) c.localEid = 999;
            vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
            new LayerZeroSourceVault(c, address(asset), TREASURY);
        }
        LayerZeroEndpoint.Config memory noOwner = _config(true);
        noOwner.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LayerZeroSourceVault(noOwner, address(asset), TREASURY);
    }

    function test_InvalidAssetAndTreasuryConfigurationsFail() public {
        LayerZeroEndpoint.Config memory c = _config(true);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, ALICE, TREASURY);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(asset), address(0));
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(asset), address(asset));
        SixDecimals six = new SixDecimals();
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroSourceVault(c, address(six), TREASURY);
        vm.chainId(5042);
        c = _config(false);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        new LayerZeroDestinationBridge(c, address(0), "Stock", "STK", 30 days);
    }

    function test_PeersPathInitializationAndLaneBounds() public {
        LayerZeroSourceVault fresh = new LayerZeroSourceVault(_config(true), address(asset), TREASURY);
        Origin memory o = Origin(30417, bytes32(uint256(uint160(address(bridge)))), 1);
        assertFalse(fresh.allowInitializePath(o));
        vm.expectRevert(LayerZeroEndpoint.PeerNotSet.selector);
        fresh.quoteMetadataFee();
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        fresh.setPeer(address(0), BOB);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        fresh.setPeer(BOB, address(0));
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        fresh.setPeer(BOB, BOB);
        fresh.setPeer(address(bridge), address(wrapped));
        assertTrue(fresh.allowInitializePath(o));
        assertEq(fresh.nextNonce(30417, o.sender), 0);
        o.srcEid++;
        assertFalse(fresh.allowInitializePath(o));
        o.srcEid--;
        o.sender = bytes32(uint256(1));
        assertFalse(fresh.allowInitializePath(o));
        vm.chainId(5042);
        assertFalse(fresh.allowInitializePath(o));
        LayerZeroDestinationBridge dest =
            new LayerZeroDestinationBridge(_config(false), address(asset), "Stock", "STK", 30 days);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        dest.setPeer(ALICE, BOB);
        vm.chainId(4663);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        vault.pause(0);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        vault.unpause(4);
        vm.prank(ALICE);
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedGuardian.selector);
        vault.pause(1);
    }

    function test_GuardianRotationAndAdministrativeAuthority() public {
        vm.prank(ALICE);
        vm.expectRevert();
        vault.setGuardian(BOB);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        vault.setGuardian(address(0));
        vault.setGuardian(BOB);
        vm.prank(GUARDIAN);
        vm.expectRevert(LayerZeroEndpoint.UnauthorizedGuardian.selector);
        vault.pause(1);
        vm.prank(BOB);
        vault.pause(1);
        vault.unpause(1);
        vm.prank(ALICE);
        vm.expectRevert();
        vault.setMaxTransfer(1);
        vm.prank(ALICE);
        vm.expectRevert();
        vault.prepareInboundMaxTransfer(2000 ether);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        vault.setMaxTransfer(0);
        vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
        vault.setMaxTransfer(1001 ether);
        address[3] memory invalid = [address(0), address(vault), address(asset)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(LayerZeroEndpoint.InvalidConfiguration.selector);
            vault.setFeeRecipient(invalid[i]);
        }
    }

    function test_InvalidOutgoingAmountsRecipientsAndPausedPublication() public {
        address[3] memory invalid = [address(0), address(bridge), address(wrapped)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
            vault.quoteDepositFee(1, invalid[i]);
        }
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        vault.quoteDepositFee(0, ALICE);
        vm.expectRevert(LayerZeroEndpoint.TransferTooLarge.selector);
        vault.quoteDepositFee(1001 ether, ALICE);
        vault.pause(1);
        vm.expectRevert(abi.encodeWithSelector(LayerZeroEndpoint.LanePaused.selector, uint8(1)));
        vault.publishMetadata();
        vm.expectRevert(abi.encodeWithSelector(LayerZeroEndpoint.LanePaused.selector, uint8(1)));
        vault.deposit(1, ALICE);
    }

    function _badClaim(bytes memory encoded, uint8 mutation, bool redemption) private {
        (Origin memory o, bytes32 guid, bytes memory payload) = abi.decode(encoded, (Origin, bytes32, bytes));
        Message.Transfer memory t = abi.decode(payload, (Message.Transfer));
        LayerZeroEndpoint receiver =
            redemption ? LayerZeroEndpoint(address(vault)) : LayerZeroEndpoint(address(bridge));
        if (mutation == 0) t.recipient = address(receiver);
        if (mutation == 1) t.amount = 1001 ether;
        if (mutation == 2) t.header.action = 99;
        if (mutation == 3) t.recipient = address(asset);
        if (mutation == 4) t.amount = 100 ether;
        bytes memory bad = abi.encode(t);
        if (mutation == 5) bad = abi.encodePacked(bad, bytes1(0));
        if (mutation == 6) bad = hex"0001";
        if (redemption) sourceUln.attest(receiver.packetHeader(o), keccak256(abi.encodePacked(guid, bad)));
        else destinationUln.attest(receiver.packetHeader(o), keccak256(abi.encodePacked(guid, bad)));
        vm.expectRevert();
        receiver.complete(o, guid, bad);
        assertFalse(receiver.consumedMessages(guid));
        receiver.complete(o, guid, payload);
    }

    function testFuzz_MalformedAuthenticatedDepositCannotConsumeValidClaim(uint8 seed) public {
        uint8 m = seed % 5;
        if (m > 2) m += 2;
        _badClaim(_deposit(10 ether, ALICE), m, false);
    }

    function testFuzz_MalformedOrUnbackedRedemptionCannotSpendDonatedSurplus(uint8 seed) public {
        _mint(10 ether);
        bytes memory encoded = _redeem(1 ether, ALICE);
        asset.mint(address(vault), 1000 ether);
        _badClaim(encoded, seed % 7, true);
        assertEq(vault.locked(), 8.95 ether);
    }

    function test_ZeroMultipliersAndBlockedTreasuryCannotCommitDepositOrMetadata() public {
        asset.setMultiplier(0, 1, 0);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        vault.publishMetadata();
        asset.setMultiplier(1, 0, block.timestamp + 1);
        vm.expectRevert(LayerZeroEndpoint.InvalidMessage.selector);
        vault.quoteMetadataFee();
        asset.setBlockedRecipient(TREASURY);
        vm.prank(ALICE);
        vm.expectRevert("blocked recipient");
        vault.deposit(100 ether, ALICE);
        assertEq(vault.locked(), 0);
        assertEq(sourceCore.nonce(address(vault)), 0);
    }

    function ownerCallback(uint8 action) external {
        require(msg.sender == address(asset));
        if (action == 0) vault.setFeeRecipient(BOB);
        if (action == 1) vault.setMaxTransfer(1);
        if (action == 2) vault.prepareInboundMaxTransfer(2000 ether);
    }

    function test_ReentrancyThroughOwnerCannotAlterFeesOrLimits() public {
        for (uint8 i; i < 3; ++i) {
            asset.setCallback(address(this), abi.encodeCall(this.ownerCallback, (i)));
            _mint(10 ether);
            assertFalse(asset.callbackSucceeded());
            assertEq(bytes4(asset.callbackResult()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        }
        assertEq(vault.feeRecipient(), TREASURY);
        assertEq(vault.maxTransfer(), 1000 ether);
        assertEq(vault.inboundMaxTransfer(), 1000 ether);
    }

    function test_FeeRecipientCanBeDepositorAndDonationsNeverMint() public {
        vault.setFeeRecipient(ALICE);
        uint256 before = asset.balanceOf(ALICE);
        _mint(100 ether);
        assertEq(before - asset.balanceOf(ALICE), 99.5 ether);
        asset.mint(address(vault), 10 ether);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(wrapped.totalSupply(), 99.5 ether);
        _complete(vault, _redeem(99.5 ether, BOB));
        assertEq(asset.balanceOf(address(vault)), 10 ether);
        assertEq(vault.locked(), 0);
    }

    function test_HugeRawUIConversionUsesFullPrecision() public {
        _complete(bridge, _metadata());
        assertEq(wrapped.toUIAmount(type(uint256).max), type(uint256).max);
        assertEq(wrapped.fromUIAmount(type(uint256).max), type(uint256).max);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert();
        wrapped.toUIAmount(1);
    }
}
