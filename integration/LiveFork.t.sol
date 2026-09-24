// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BridgeMessage} from "../src/BridgeMessage.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";
import {IWormholeCore} from "../src/interfaces/IWormholeCore.sol";
import {IScaledUIAmount, IPendingUIAmount} from "../src/interfaces/IScaledUIAmount.sol";
import {MockWormholeCore} from "../test/mocks/MockWormholeCore.sol";

interface IRealStock is IERC20 {
    function uid() external view returns (uint256);
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
    function pause() external;
    function unpause() external;
    function adminBurn(address from, uint256 amount) external;
}

/// @notice Local fork simulation only. Token balances are injected with deal, not issuer minting.
/// No signatures, broadcasts, or real bridging. Mock-attested round trip tests token compatibility only.
contract LiveForkTest is Test {
    address constant SOURCE_CORE = 0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB;
    address constant ARC_CORE = 0xC8aD24fC6063c41cB5C12a8e3851AafC3b3CF027;
    address constant TREASURY = address(0xFEE);
    address constant RECEIVER = address(0xBEEF);
    address constant NEXT_TREASURY = address(0xFEE2);
    uint256 constant ASSET_COUNT = 12;

    function _candidate(uint256 index)
        private
        view
        returns (address token, string memory symbol, uint256 uid)
    {
        string memory json = vm.readFile("config/stock-assets.example.json");
        string memory prefix = string.concat(".assets[", vm.toString(index), "]");
        token = vm.parseJsonAddress(json, string.concat(prefix, ".token"));
        symbol = vm.parseJsonString(json, string.concat(prefix, ".symbol"));
        uid = uint256(vm.parseJsonBytes32(json, string.concat(prefix, ".uid")));
    }

    function _exerciseCandidate(uint256 index, string memory expectedSymbol) private {
        (address token, string memory symbol, uint256 uid) = _candidate(index);
        assertEq(symbol, expectedSymbol, "candidate ordering changed");
        _exercise(token);
        assertEq(IERC20Metadata(token).symbol(), symbol, "official ticker must match");
        assertEq(IRealStock(token).uid(), uid, "official registry UID must match");
        emit log_named_string("Verified selected stock", symbol);
    }

    function _config(address core, bool source) private view returns (WormholeEndpoint.Config memory) {
        return WormholeEndpoint.Config(
            core,
            source ? 72 : 71,
            source ? 71 : 72,
            source ? 4663 : 5042,
            source ? 5042 : 4663,
            0,
            0,
            address(this),
            address(this),
            100 ether
        );
    }

    function _sourceFork() private {
        uint256 pin = vm.envOr("ROBINHOOD_REVIEW_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("ROBINHOOD_REVIEW_RPC"));
        else vm.createSelectFork(vm.envString("ROBINHOOD_REVIEW_RPC"), pin);
        assertEq(block.chainid, 4663);
        emit log_named_uint("Robinhood fork block (latest, not finalized proof)", block.number);
        assertEq(IWormholeCore(SOURCE_CORE).chainId(), 72);
        assertEq(IWormholeCore(SOURCE_CORE).evmChainId(), 4663);
    }

    function _exercise(address token) private {
        _sourceFork();
        IERC20 asset = IERC20(token);
        assertGt(token.code.length, 0);
        assertEq(IERC20Metadata(token).decimals(), 18);
        assertGt(IScaledUIAmount(token).uiMultiplier(), 0);
        deal(token, address(this), 300 ether);
        vm.deal(address(this), 1 ether);
        uint256 treasuryBefore = asset.balanceOf(TREASURY);
        _exerciseRealCore(token);
        _exerciseMockReturn(token);
        assertEq(asset.balanceOf(TREASURY) - treasuryBefore, 1 ether);
    }

    function _exerciseRealCore(address token) private {
        IERC20 asset = IERC20(token);
        uint256 treasuryBefore = asset.balanceOf(TREASURY);
        SourceVault vault = new SourceVault(_config(SOURCE_CORE, true), token, TREASURY);
        vault.setPeer(address(0x1234), address(0x5678));
        vault.unpause(3);
        asset.approve(address(vault), 100 ether);
        vm.recordLogs();
        vault.deposit{value: vault.messageFee()}(100 ether, RECEIVER);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(asset.balanceOf(address(vault)), 99.5 ether);
        assertEq(asset.balanceOf(TREASURY) - treasuryBefore, 0.5 ether);
        assertEq(asset.balanceOf(address(this)), 200 ether);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 publications;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == SOURCE_CORE
                    && entries[i].topics[0]
                        == keccak256("LogMessagePublished(address,uint64,uint32,bytes,uint8)")
            ) {
                publications++;
                (,, bytes memory payload, uint8 consistency) =
                    abi.decode(entries[i].data, (uint64, uint32, bytes, uint8));
                BridgeMessage.Transfer memory message = abi.decode(payload, (BridgeMessage.Transfer));
                assertEq(consistency, 0);
                assertEq(message.header.originToken, token);
                assertEq(message.header.destinationEvmChain, 5042);
                assertEq(message.recipient, RECEIVER);
                assertEq(message.amount, 99.5 ether);
            }
        }
        assertEq(publications, 1, "real Core must emit publication");
        vault.publishMetadata{value: vault.messageFee()}();

        uint256 nextTreasuryBefore = asset.balanceOf(NEXT_TREASURY);
        vault.setFeeRecipient(NEXT_TREASURY);
        assertEq(vault.locked(), 99.5 ether);
        asset.approve(address(vault), 100 ether);
        vault.deposit{value: vault.messageFee()}(100 ether, RECEIVER);
        assertEq(vault.locked(), 199 ether);
        assertEq(asset.balanceOf(address(vault)), 199 ether);
        assertEq(asset.balanceOf(TREASURY) - treasuryBefore, 0.5 ether);
        assertEq(asset.balanceOf(NEXT_TREASURY) - nextTreasuryBefore, 0.5 ether);
    }

    function _exerciseMockReturn(address token) private {
        IERC20 asset = IERC20(token);
        // Separate, explicitly mock-attested test of redemption using the real token bytecode/storage.
        MockWormholeCore source = new MockWormholeCore(72);
        SourceVault mockVault = new SourceVault(_config(address(source), true), token, TREASURY);
        vm.chainId(5042);
        MockWormholeCore destination = new MockWormholeCore(71);
        DestinationBridge bridge = new DestinationBridge(
            _config(address(destination), false), token, "Review fixture", "REVIEW", 1 days
        );
        bridge.setPeer(address(mockVault), token);
        bridge.unpause(3);
        vm.chainId(4663);
        mockVault.setPeer(address(bridge), address(bridge.wrappedAsset()));
        mockVault.unpause(3);
        asset.approve(address(mockVault), 100 ether);
        uint64 sequence = mockVault.deposit(100 ether, RECEIVER);
        bytes memory vaa = source.published(address(mockVault), sequence);
        destination.attest(vaa);
        vm.chainId(5042);
        bridge.setMaxTransfer(50 ether);
        assertEq(bridge.inboundMaxTransfer(), 100 ether);
        bridge.completeDeposit(vaa);
        bridge.setMaxTransfer(100 ether);
        _exerciseMetadata(token, mockVault, bridge, source, destination);
        vm.prank(RECEIVER);
        sequence = bridge.redeem(99.5 ether, RECEIVER);
        vaa = destination.published(address(bridge), sequence);
        source.attest(vaa);
        vm.chainId(4663);
        uint256 receiverBefore = asset.balanceOf(RECEIVER);
        mockVault.setMaxTransfer(50 ether);
        assertEq(mockVault.inboundMaxTransfer(), 100 ether);
        mockVault.completeRedemption(vaa);
        assertEq(asset.balanceOf(RECEIVER) - receiverBefore, 99.5 ether);
        assertEq(mockVault.locked(), 0);
        assertEq(asset.balanceOf(address(mockVault)), 0);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
    }

    function _exerciseMetadata(
        address token,
        SourceVault mockVault,
        DestinationBridge bridge,
        MockWormholeCore source,
        MockWormholeCore destination
    ) private {
        vm.chainId(4663);
        uint256 multiplier = IScaledUIAmount(token).uiMultiplier();
        uint256 nextMultiplier = IPendingUIAmount(token).newUIMultiplier();
        uint256 effective = IPendingUIAmount(token).effectiveAt();
        if (effective <= block.timestamp) {
            nextMultiplier = multiplier;
            effective = 0;
        }
        uint64 sequence = mockVault.publishMetadata();
        bytes memory metadataVaa = source.published(address(mockVault), sequence);
        destination.attest(metadataVaa);
        vm.chainId(5042);
        assertTrue(bridge.completeMetadata(metadataVaa));
        assertEq(bridge.wrappedAsset().uiMultiplier(), multiplier);
        assertEq(bridge.wrappedAsset().newUIMultiplier(), nextMultiplier);
        assertEq(bridge.wrappedAsset().effectiveAt(), effective);
    }

    // Test-only role responses simulate issuer interventions; actual role holders are not impersonated.
    function _fundedClaim(address token)
        private
        returns (SourceVault vault, IRealStock stock, address registry, bytes memory vaa)
    {
        vm.clearMockedCalls();
        _sourceFork();
        stock = IRealStock(token);
        registry = stock.ACCESS_CONTROLLED_REGISTRY();
        MockWormholeCore core = new MockWormholeCore(72);
        vault = new SourceVault(_config(address(core), true), address(stock), TREASURY);
        vault.setPeer(address(0x1234), address(0x5678));
        vault.unpause(3);
        deal(address(stock), address(this), 200 ether);
        stock.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, RECEIVER);
        IWormholeCore.VM memory message;
        message.emitterChainId = 71;
        message.emitterAddress = bytes32(uint256(uint160(address(0x1234))));
        message.sequence = 123;
        message.consistencyLevel = 0;
        message.payload = abi.encode(
            BridgeMessage.Transfer(
                BridgeMessage.Header(
                    BridgeMessage.DOMAIN,
                    1,
                    BridgeMessage.REDEEM,
                    5042,
                    4663,
                    72,
                    address(vault),
                    address(stock)
                ),
                RECEIVER,
                99.5 ether
            )
        );
        vaa = abi.encode(message);
        core.attest(vaa);
    }

    function _eachCandidate(function(address) internal scenario) private {
        for (uint256 i; i < ASSET_COUNT; ++i) {
            (address token, string memory symbol,) = _candidate(i);
            emit log_named_string("Issuer scenario stock", symbol);
            scenario(token);
        }
        vm.clearMockedCalls();
    }

    function testFork_AllTwelveBlockedTreasuryRollbackAndRotationRecovery() public {
        _eachCandidate(_blockedTreasury);
    }

    function _blockedTreasury(address token) private {
        (SourceVault vault, IRealStock stock, address registry,) = _fundedClaim(token);
        vm.mockCall(registry, abi.encodeWithSignature("isBlocked(address)", TREASURY), abi.encode(true));
        uint256 feeBefore = stock.balanceOf(TREASURY);
        vm.expectRevert(abi.encodeWithSignature("Blocked(address)", TREASURY));
        vault.deposit(10 ether, RECEIVER);
        assertEq(stock.balanceOf(address(this)), 100 ether);
        assertEq(stock.balanceOf(address(vault)), 99.5 ether);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(stock.balanceOf(TREASURY), feeBefore);
        uint256 nextBefore = stock.balanceOf(NEXT_TREASURY);
        vault.setFeeRecipient(NEXT_TREASURY);
        vault.deposit(10 ether, RECEIVER);
        assertEq(stock.balanceOf(TREASURY), feeBefore);
        assertEq(stock.balanceOf(NEXT_TREASURY) - nextBefore, 0.05 ether);
        assertEq(vault.locked(), 109.45 ether);
    }

    function testFork_AllTwelveBlockedRecipientsPreserveRedemption() public {
        _eachCandidate(_blockedRecipient);
    }

    function _blockedRecipient(address token) private {
        (SourceVault vault, IRealStock stock, address registry, bytes memory vaa) = _fundedClaim(token);
        vm.mockCall(registry, abi.encodeWithSignature("isBlocked(address)", RECEIVER), abi.encode(true));
        vm.expectRevert(abi.encodeWithSignature("Blocked(address)", RECEIVER));
        vault.completeRedemption(vaa);
        assertEq(vault.locked(), 99.5 ether);
        vm.clearMockedCalls();
        uint256 beforeBalance = stock.balanceOf(RECEIVER);
        vault.completeRedemption(vaa);
        assertEq(stock.balanceOf(RECEIVER) - beforeBalance, 99.5 ether);
        assertEq(vault.locked(), 0);
    }

    function testFork_AllTwelveIssuerPausesPreserveClaimForRetry() public {
        _eachCandidate(_issuerPause);
    }

    function _issuerPause(address token) private {
        (SourceVault vault, IRealStock stock, address registry, bytes memory vaa) = _fundedClaim(token);
        vm.mockCall(
            registry,
            abi.encodeWithSignature(
                "hasRole(bytes32,address)", keccak256("TOKEN_PAUSER_ROLE"), address(this)
            ),
            abi.encode(true)
        );
        stock.pause();
        vm.expectRevert(bytes4(keccak256("IsPaused()")));
        vault.completeRedemption(vaa);
        assertEq(vault.locked(), 99.5 ether);
        stock.unpause();
        vault.completeRedemption(vaa);
        assertEq(vault.locked(), 0);
    }

    function testFork_AllTwelveIssuerBurnsFailClosedUntilRecapitalized() public {
        _eachCandidate(_issuerBurn);
    }

    function _issuerBurn(address token) private {
        (SourceVault vault, IRealStock stock, address registry, bytes memory vaa) = _fundedClaim(token);
        vm.mockCall(
            registry,
            abi.encodeWithSignature(
                "hasRole(bytes32,address)", keccak256("ADMIN_BURNER_ROLE"), address(this)
            ),
            abi.encode(true)
        );
        stock.adminBurn(address(vault), 1 ether);
        assertEq(stock.balanceOf(address(vault)), 98.5 ether);
        assertEq(vault.locked(), 99.5 ether);
        vm.expectRevert(SourceVault.InsufficientBacking.selector);
        vault.completeRedemption(vaa);
        vm.expectRevert(SourceVault.InsufficientBacking.selector);
        vault.deposit(10 ether, RECEIVER);
        // A voluntary, test-funded recapitalization; the protocol has no automatic recovery guarantee.
        stock.transfer(address(vault), 1 ether);
        vault.completeRedemption(vaa);
        assertEq(vault.locked(), 0);
        assertEq(stock.balanceOf(address(vault)), 0);
    }

    function testFork_AAPLDepositFeeMetadataAndMockAttestedReturn() public {
        _exerciseCandidate(4, "AAPL");
    }

    function testFork_NVDAdepositFeeMetadataAndMockAttestedReturn() public {
        _exerciseCandidate(0, "NVDA");
    }

    function testFork_TSLADepositFeeMetadataAndMockAttestedReturn() public {
        _exerciseCandidate(9, "TSLA");
    }

    function testFork_META() public {
        _exerciseCandidate(1, "META");
    }

    function testFork_PLTR() public {
        _exerciseCandidate(2, "PLTR");
    }

    function testFork_GOOGL() public {
        _exerciseCandidate(3, "GOOGL");
    }

    function testFork_MSFT() public {
        _exerciseCandidate(5, "MSFT");
    }

    function testFork_INTC() public {
        _exerciseCandidate(6, "INTC");
    }

    function testFork_AMZN() public {
        _exerciseCandidate(7, "AMZN");
    }

    function testFork_AMD() public {
        _exerciseCandidate(8, "AMD");
    }

    function testFork_COIN() public {
        _exerciseCandidate(10, "COIN");
    }

    function testFork_AVGO() public {
        _exerciseCandidate(11, "AVGO");
    }

    function testFork_SPYDepositFeeMetadataAndMockAttestedReturn() public {
        _exercise(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C);
    }

    function testFork_RealGuardianVAAValidButForeignMessageRejectedAndTamperingInvalid() public {
        bytes memory vaa = vm.parseJsonBytes(vm.readFile("config/research-vaa.example.json"), ".vaaHex");
        _sourceFork();
        (, bool sourceValid,) = IWormholeCore(SOURCE_CORE).parseAndVerifyVM(vaa);
        assertTrue(sourceValid, "real source Core must validate signatures");
        uint256 pin = vm.envOr("ARC_REVIEW_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("ARC_REVIEW_RPC"));
        else vm.createSelectFork(vm.envString("ARC_REVIEW_RPC"), pin);
        emit log_named_uint("Arc signed VAA fork block", block.number);
        (IWormholeCore.VM memory message, bool valid,) = IWormholeCore(ARC_CORE).parseAndVerifyVM(vaa);
        assertTrue(valid, "real destination Core must validate signatures");
        assertEq(message.emitterChainId, 72);
        assertEq(message.guardianSetIndex, 7);
        assertEq(message.consistencyLevel, 202); // Historical NTT message; does not prove our level-0 policy.
        DestinationBridge bridge = new DestinationBridge(
            _config(ARC_CORE, false), address(0xA55E7), "Review fixture", "REVIEW", 1 days
        );
        bridge.setPeer(address(0x1234), address(0xA55E7));
        bridge.unpause(3);
        vm.expectRevert(WormholeEndpoint.WrongEmitter.selector);
        bridge.completeDeposit(vaa);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
        vaa[vaa.length - 1] = bytes1(uint8(vaa[vaa.length - 1]) ^ 1);
        (, valid,) = IWormholeCore(ARC_CORE).parseAndVerifyVM(vaa);
        assertFalse(valid, "tampered body must invalidate signatures");
    }

    function testFork_ArcCoreIdentityAndUnsignedVAARejected() public {
        uint256 pin = vm.envOr("ARC_REVIEW_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("ARC_REVIEW_RPC"));
        else vm.createSelectFork(vm.envString("ARC_REVIEW_RPC"), pin);
        assertEq(block.chainid, 5042);
        emit log_named_uint("Arc fork block", block.number);
        assertEq(IWormholeCore(ARC_CORE).chainId(), 71);
        assertEq(IWormholeCore(ARC_CORE).evmChainId(), 5042);
        DestinationBridge bridge = new DestinationBridge(
            _config(ARC_CORE, false), address(0xA55E7), "Review fixture", "REVIEW", 1 days
        );
        bridge.setPeer(address(0x1234), address(0xA55E7));
        bridge.unpause(3);
        vm.expectRevert();
        bridge.completeDeposit(hex"010000000700");
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
    }
}
