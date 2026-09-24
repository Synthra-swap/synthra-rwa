// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {VerifiedCoreHarness} from "./mocks/VerifiedCoreHarness.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {SourceVault} from "../src/SourceVault.sol";
import {DestinationBridge} from "../src/DestinationBridge.sol";
import {WormholeEndpoint} from "../src/WormholeEndpoint.sol";

contract SignedVAATest is Test {
    VerifiedCoreHarness internal source;
    VerifiedCoreHarness internal destination;
    MockStockToken internal asset;
    SourceVault internal vault;
    DestinationBridge internal bridge;
    address internal constant TREASURY = address(0xFEE);
    address[] internal guardians;

    function setUp() public {
        vm.warp(100_000);
        for (uint256 i; i < 4; ++i) {
            guardians.push(vm.addr(100 + i));
        }
        vm.chainId(111);
        source = new VerifiedCoreHarness(100, guardians);
        asset = new MockStockToken();
        vault = new SourceVault(_config(address(source), 100, 200, 111, 222), address(asset), TREASURY);
        vm.chainId(222);
        destination = new VerifiedCoreHarness(200, guardians);
        bridge = new DestinationBridge(
            _config(address(destination), 200, 100, 222, 111), address(asset), "Stock", "sSTK", 1 days
        );
        bridge.setPeer(address(vault), address(asset));
        bridge.unpause(3);
        vm.chainId(111);
        vault.setPeer(address(bridge), address(bridge.wrappedAsset()));
        vault.unpause(3);
        asset.mint(address(this), 1000 ether);
        asset.approve(address(vault), type(uint256).max);
    }

    function _config(address core, uint16 local, uint16 remote, uint256 evm, uint256 remoteEvm)
        private
        view
        returns (WormholeEndpoint.Config memory)
    {
        return WormholeEndpoint.Config(
            core, local, remote, evm, remoteEvm, 1, 1, address(this), address(this), 1000 ether
        );
    }

    function _signed(
        uint16 chain,
        address emitter,
        uint64 sequence,
        bytes memory payload,
        uint8 count,
        uint32 set,
        bool badSigner
    ) private view returns (bytes memory) {
        bytes memory body = abi.encodePacked(
            uint32(block.timestamp),
            uint32(0),
            chain,
            bytes32(uint256(uint160(emitter))),
            sequence,
            uint8(1),
            payload
        );
        bytes32 digest = keccak256(abi.encodePacked(keccak256(body)));
        bytes memory signatures;
        for (uint8 i; i < count; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(badSigner && i == 0 ? 999 : 100 + uint256(i), digest);
            signatures = bytes.concat(signatures, abi.encodePacked(i, r, s, v - 27));
        }
        return bytes.concat(abi.encodePacked(uint8(1), set, count), signatures, body);
    }

    function _depositVAA(uint8 count, uint32 set, bool badSigner) private returns (bytes memory encoded) {
        vm.chainId(111);
        uint64 seq = vault.deposit(100 ether, address(this));
        encoded = _signed(
            100, address(vault), seq, source.publishedPayload(address(vault), seq), count, set, badSigner
        );
        vm.chainId(222);
    }

    function test_RealBinaryVaaRoundTripAcrossDifferentEvmDomains() public {
        bridge.completeDeposit(_depositVAA(3, 0, false));
        assertEq(bridge.wrappedAsset().balanceOf(address(this)), 99.5 ether);
        uint64 seq = bridge.redeem(99.5 ether, address(this));
        bytes memory encoded = _signed(
            200, address(bridge), seq, destination.publishedPayload(address(bridge), seq), 3, 0, false
        );
        vm.chainId(111);
        vault.completeRedemption(encoded);
        assertEq(vault.locked(), 0);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
    }

    function test_InsufficientQuorumRejected() public {
        bytes memory encoded = _depositVAA(2, 0, false);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(encoded);
    }

    function test_WrongGuardianSignatureRejected() public {
        bytes memory encoded = _depositVAA(3, 0, true);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(encoded);
    }

    function test_TamperedSignedPayloadRejected() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        encoded[encoded.length - 1] = bytes1(uint8(encoded[encoded.length - 1]) ^ 1);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(encoded);
    }

    function test_UnknownGuardianSetRejected() public {
        bytes memory encoded = _depositVAA(3, 10, false);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(encoded);
    }

    function test_ExpiredGuardianSetRejected() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        destination.rotate(guardians, uint32(block.timestamp - 1));
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(encoded);
    }

    function test_AlternativeQuorumCannotReplaySameSequence() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        bridge.completeDeposit(encoded);
        encoded = _signed(100, address(vault), 0, source.publishedPayload(address(vault), 0), 4, 0, false);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(encoded);
    }

    function test_TruncatedVAARejected() public {
        vm.chainId(222);
        vm.expectRevert();
        bridge.completeDeposit(hex"010000000003");
    }

    function test_DuplicateGuardianCannotCountTwiceTowardQuorum() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        for (uint256 i; i < 66; ++i) {
            encoded[72 + i] = encoded[6 + i];
        }
        vm.expectRevert("signature indices must be ascending");
        bridge.completeDeposit(encoded);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
    }

    function test_OutOfBoundsGuardianIndexRejected() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        encoded[138] = bytes1(uint8(4));
        vm.expectRevert("guardian index out of bounds");
        bridge.completeDeposit(encoded);
    }

    function test_UnsupportedVaaVersionRejected() public {
        bytes memory encoded = _depositVAA(3, 0, false);
        encoded[0] = bytes1(uint8(2));
        vm.expectRevert("VM version incompatible");
        bridge.completeDeposit(encoded);
    }

    function testFuzz_AnyTruncatedSignedVaaCannotMint(uint256 length) public {
        bytes memory encoded = _depositVAA(3, 0, false);
        length = bound(length, 0, encoded.length - 1);
        assembly { mstore(encoded, length) }
        vm.expectRevert();
        bridge.completeDeposit(encoded);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
    }

    function _resignSameBody(bytes memory old, uint32 guardianSet) private pure returns (bytes memory) {
        return _resignSameBody(old, guardianSet, 100);
    }

    function _resignSameBody(bytes memory old, uint32 guardianSet, uint256 firstKey)
        private
        pure
        returns (bytes memory)
    {
        uint256 bodyOffset = 6 + uint256(uint8(old[5])) * 66;
        bytes memory body = new bytes(old.length - bodyOffset);
        for (uint256 i; i < body.length; ++i) {
            body[i] = old[bodyOffset + i];
        }
        bytes32 digest = keccak256(abi.encodePacked(keccak256(body)));
        bytes memory signatures;
        for (uint8 i; i < 3; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(firstKey + uint256(i), digest);
            signatures = bytes.concat(signatures, abi.encodePacked(i, r, s, v - 27));
        }
        return bytes.concat(abi.encodePacked(uint8(1), guardianSet, uint8(3)), signatures, body);
    }

    function test_ExpiredAttestationNeedsResigningAndReSigningCannotDoubleMint() public {
        bytes memory old = _depositVAA(3, 0, false);
        destination.rotate(guardians, uint32(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(old);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
        // Models availability of a fresh quorum, not a guarantee of an external re-signing service.
        bridge.completeDeposit(_resignSameBody(old, 1));
        assertEq(bridge.wrappedAsset().totalSupply(), 99.5 ether);
        destination.rotate(guardians, uint32(block.timestamp + 1 days));
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(_resignSameBody(old, 2));
    }

    function _replacementGuardians() private pure returns (address[] memory next) {
        next = new address[](4);
        for (uint256 i; i < next.length; ++i) {
            next[i] = vm.addr(200 + i);
        }
    }

    function test_NewGuardianKeysRecoverPendingMintWithoutReplay() public {
        bytes memory old = _depositVAA(3, 0, false);
        destination.rotate(_replacementGuardians(), uint32(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(old);
        // Merely changing the set index or signing with obsolete keys must not authorize a mint.
        bytes memory obsoleteKeys = _resignSameBody(old, 1);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        bridge.completeDeposit(obsoleteKeys);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
        assertEq(vault.locked(), 99.5 ether);

        bytes memory recovered = _resignSameBody(old, 1, 200);
        bridge.completeDeposit(recovered);
        assertEq(bridge.wrappedAsset().balanceOf(address(this)), 99.5 ether);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        bridge.completeDeposit(recovered);
        assertEq(bridge.wrappedAsset().totalSupply(), 99.5 ether);
    }

    function test_NewGuardianKeysRecoverPendingReleaseWithoutDoublePayment() public {
        bridge.completeDeposit(_depositVAA(3, 0, false));
        uint64 seq = bridge.redeem(99.5 ether, address(this));
        bytes memory old = _signed(
            200, address(bridge), seq, destination.publishedPayload(address(bridge), seq), 3, 0, false
        );
        vm.chainId(111);
        source.rotate(_replacementGuardians(), uint32(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        uint256 recipientBefore = asset.balanceOf(address(this));

        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        vault.completeRedemption(old);
        bytes memory obsoleteKeys = _resignSameBody(old, 1);
        vm.expectRevert(WormholeEndpoint.InvalidVAA.selector);
        vault.completeRedemption(obsoleteKeys);
        assertEq(vault.locked(), 99.5 ether);
        assertEq(bridge.wrappedAsset().totalSupply(), 0);
        assertEq(asset.balanceOf(address(this)), recipientBefore);

        bytes memory recovered = _resignSameBody(old, 1, 200);
        vault.completeRedemption(recovered);
        assertEq(asset.balanceOf(address(this)), recipientBefore + 99.5 ether);
        assertEq(vault.locked(), 0);
        vm.expectRevert(WormholeEndpoint.MessageAlreadyConsumed.selector);
        vault.completeRedemption(recovered);
        assertEq(asset.balanceOf(address(this)), recipientBefore + 99.5 ether);
        assertEq(asset.balanceOf(TREASURY), 0.5 ether);
    }
}
