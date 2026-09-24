// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Messages} from "../../vendor/wormhole/ethereum/contracts/Messages.sol";
import {Structs} from "../../vendor/wormhole/ethereum/contracts/Structs.sol";

/// @dev Test-only state initialization/publishing. Parsing, quorum and signature verification are unmodified upstream.
contract VerifiedCoreHarness is Messages {
    mapping(address => mapping(uint64 => bytes)) public publishedPayload;

    constructor(uint16 local, address[] memory guardians) {
        _state.provider.chainId = local;
        _state.evmChainId = block.chainid;
        _state.guardianSets[0] = Structs.GuardianSet(guardians, 0);
    }

    function publishMessage(uint32, bytes memory payload, uint8) external payable returns (uint64 sequence) {
        require(msg.value == messageFee(), "fee");
        sequence = _state.sequences[msg.sender]++;
        publishedPayload[msg.sender][sequence] = payload;
    }

    function rotate(address[] memory guardians, uint32 expiry) external {
        _state.guardianSets[_state.guardianSetIndex].expirationTime = expiry;
        _state.guardianSetIndex++;
        _state.guardianSets[_state.guardianSetIndex] = Structs.GuardianSet(guardians, 0);
    }
}
