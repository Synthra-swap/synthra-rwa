// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ABI subset checked against LayerZero-v2 commit 9c741e7f9790639537b1710a203bcdfd73b0b9ac.
// Verification is performed by the configured, external ULN library.
struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct SetConfigParam {
    uint32 eid;
    uint32 configType;
    bytes config;
}

struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

interface ILayerZeroEndpoint {
    function eid() external view returns (uint32);
    function setSendLibrary(address, uint32, address) external;
    function setReceiveLibrary(address, uint32, address, uint256) external;
    function setConfig(address, address, SetConfigParam[] calldata) external;
    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory);
    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory);
    function inboundPayloadHash(address, uint32, bytes32, uint64) external view returns (bytes32);
    function lzReceive(Origin calldata, address, bytes32, bytes calldata, bytes calldata) external payable;
    function clear(address, Origin calldata, bytes32, bytes calldata) external;
}

interface ILayerZeroUln {
    function getUlnConfig(address, uint32) external view returns (UlnConfig memory);
    function getAppUlnConfig(address, uint32) external view returns (UlnConfig memory);
    function verify(bytes calldata, bytes32, uint64) external;
    function commitVerification(bytes calldata, bytes32) external;
}
