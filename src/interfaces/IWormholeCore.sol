// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @dev Minimal ABI from wormhole-foundation/wormhole ethereum/contracts/interfaces/IWormhole.sol.
interface IWormholeCore {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence);
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VM memory vm, bool valid, string memory reason);
    function evmChainId() external view returns (uint256);
    function chainId() external view returns (uint16);
    function messageFee() external view returns (uint256);
}

