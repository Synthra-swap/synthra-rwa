// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BridgeMessage {
    bytes32 internal constant DOMAIN = keccak256("synthra.rwa.bridge.v1");
    uint8 internal constant VERSION = 1;
    uint8 internal constant DEPOSIT = 1;
    uint8 internal constant REDEEM = 2;
    uint8 internal constant METADATA = 3;
    uint256 internal constant TRANSFER_LENGTH = 320;
    uint256 internal constant METADATA_LENGTH = 384;

    struct Header {
        bytes32 domain;
        uint8 version;
        uint8 action;
        uint256 sourceEvmChain;
        uint256 destinationEvmChain;
        uint16 destinationChain;
        address destinationBridge;
        address originToken;
    }

    struct Transfer {
        Header header;
        address recipient;
        uint256 amount;
    }

    struct Metadata {
        Header header;
        uint256 observedAt;
        uint256 current;
        uint256 next;
        uint256 effectiveAt;
    }
}
