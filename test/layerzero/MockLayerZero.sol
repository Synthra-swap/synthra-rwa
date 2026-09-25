// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin,
    SetConfigParam,
    UlnConfig
} from "../../src/layerzero/ILayerZero.sol";

interface ITestReceiver {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

/// @dev TEST ONLY. Models fee payment, configuration, payload commitments and atomic execution.
contract MockLayerZero {
    uint32 public immutable eid;
    uint256 public fee;
    mapping(address => uint64) public nonce;
    mapping(address => mapping(uint64 => bytes)) public published;
    mapping(address => mapping(uint32 => address)) public sendLibrary;
    mapping(address => mapping(uint32 => address)) public receiveLibrary;
    mapping(address => mapping(address => mapping(uint32 => mapping(uint32 => bytes)))) public configs;
    mapping(address => mapping(uint32 => mapping(bytes32 => mapping(uint64 => bytes32)))) public
        inboundPayloadHash;

    mapping(address => mapping(uint32 => mapping(bytes32 => uint64))) public lazyInboundNonce;

    constructor(uint32 id) {
        eid = id;
    }

    function setFee(uint256 amount) external {
        fee = amount;
    }

    function setSendLibrary(address app, uint32 remote, address lib) external {
        require(msg.sender == app);
        sendLibrary[app][remote] = lib;
    }

    function setReceiveLibrary(address app, uint32 remote, address lib, uint256) external {
        require(msg.sender == app);
        receiveLibrary[app][remote] = lib;
    }

    function setConfig(address app, address lib, SetConfigParam[] calldata params) external {
        require(msg.sender == app);
        for (uint256 i; i < params.length; ++i) {
            configs[app][lib][params[i].eid][params[i].configType] = params[i].config;
        }
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee(fee, 0);
    }

    function send(MessagingParams calldata p, address refund)
        external
        payable
        returns (MessagingReceipt memory r)
    {
        require(msg.value >= fee, "fee");
        require(!p.payInLzToken && keccak256(p.options) == keccak256(hex"0003"));
        r.nonce = ++nonce[msg.sender];
        r.guid = keccak256(
            abi.encodePacked(r.nonce, eid, bytes32(uint256(uint160(msg.sender))), p.dstEid, p.receiver)
        );
        r.fee = MessagingFee(fee, 0);
        published[msg.sender][r.nonce] =
            abi.encode(Origin(eid, bytes32(uint256(uint160(msg.sender))), r.nonce), r.guid, p.message);
        if (msg.value > fee) {
            (bool ok,) = refund.call{value: msg.value - fee}("");
            require(ok, "refund");
        }
    }

    function commit(address receiver, Origin calldata origin, bytes32 hash) external {
        require(msg.sender == receiveLibrary[receiver][origin.srcEid], "library");
        inboundPayloadHash[receiver][origin.srcEid][origin.sender][origin.nonce] = hash;
    }

    function lzReceive(
        Origin calldata o,
        address receiver,
        bytes32 guid,
        bytes calldata message,
        bytes calldata extra
    ) external payable {
        _clear(o, receiver, guid, message);
        ITestReceiver(receiver).lzReceive{value: msg.value}(o, guid, message, msg.sender, extra);
    }

    function clear(address receiver, Origin calldata o, bytes32 guid, bytes calldata message) external {
        require(msg.sender == receiver, "OApp only");
        _clear(o, receiver, guid, message);
    }

    function _clear(Origin calldata o, address receiver, bytes32 guid, bytes calldata message) private {
        uint64 cursor = lazyInboundNonce[receiver][o.srcEid][o.sender];
        if (o.nonce > cursor) {
            for (uint256 n = uint256(cursor) + 1; n <= o.nonce; ++n) {
                require(
                    inboundPayloadHash[receiver][o.srcEid][o.sender][uint64(n)] != bytes32(0), "nonce gap"
                );
            }
            lazyInboundNonce[receiver][o.srcEid][o.sender] = o.nonce;
        }
        require(
            inboundPayloadHash[receiver][o.srcEid][o.sender][o.nonce]
                == keccak256(abi.encodePacked(guid, message)),
            "unverified"
        );
        delete inboundPayloadHash[receiver][o.srcEid][o.sender][o.nonce];
    }
}

/// @dev TEST ONLY. Trusted attestation shortcut; real quorum behavior is tested separately against live ULN forks.
contract MockReceiveUln {
    MockLayerZero immutable endpoint;
    mapping(bytes32 => bool) public attested;

    constructor(MockLayerZero e) {
        endpoint = e;
    }

    function attest(bytes memory header, bytes32 hash) external {
        attested[keccak256(abi.encode(header, hash))] = true;
    }

    function commitVerification(bytes calldata header, bytes32 hash) external {
        bytes32 key = keccak256(abi.encode(header, hash));
        require(attested[key], "missing attestations");
        delete attested[key];
        require(header.length == 81 && uint8(header[0]) == 1);
        Origin memory o =
            Origin(uint32(bytes4(header[9:13])), bytes32(header[13:45]), uint64(bytes8(header[1:9])));
        require(uint32(bytes4(header[45:49])) == endpoint.eid());
        address receiver = address(uint160(uint256(bytes32(header[49:81]))));
        endpoint.commit(receiver, o, hash);
    }
}
