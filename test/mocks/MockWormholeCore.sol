// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IWormholeCore} from "../../src/interfaces/IWormholeCore.sol";

/// @dev TEST ONLY. Explicitly trusts test-provided messages; performs NO guardian signature verification.
contract MockWormholeCore is IWormholeCore {
    uint16 public immutable override chainId;
    uint256 public immutable override evmChainId;
    uint256 public override messageFee;
    bool public failPublish;
    mapping(address => uint64) public nextSequence;
    mapping(address => mapping(uint64 => bytes)) private messages;
    mapping(bytes32 => bool) public attested;

    constructor(uint16 chainId_) {
        chainId = chainId_;
        evmChainId = block.chainid;
    }

    function setMessageFee(uint256 fee) external {
        messageFee = fee;
    }

    function setFailPublish(bool value) external {
        failPublish = value;
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        override
        returns (uint64 sequence)
    {
        require(!failPublish, "mock publish failed");
        require(msg.value == messageFee, "mock fee");
        sequence = nextSequence[msg.sender]++;
        VM memory vm;
        vm.version = 1;
        vm.nonce = nonce;
        vm.emitterChainId = chainId;
        vm.emitterAddress = bytes32(uint256(uint160(msg.sender)));
        vm.sequence = sequence;
        vm.consistencyLevel = consistencyLevel;
        vm.payload = payload;
        vm.hash = keccak256(abi.encode(chainId, msg.sender, sequence, payload));
        messages[msg.sender][sequence] = abi.encode(vm);
    }

    function published(address emitter, uint64 sequence) external view returns (bytes memory) {
        return messages[emitter][sequence];
    }

    function attest(bytes memory encodedVM) external {
        attested[keccak256(encodedVM)] = true;
    }

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        override
        returns (VM memory vm, bool valid, string memory reason)
    {
        valid = attested[keccak256(encodedVM)];
        if (!valid) return (vm, false, "not attested by test");
        vm = abi.decode(encodedVM, (VM));
        return (vm, true, "");
    }
}

