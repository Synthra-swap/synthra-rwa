#!/usr/bin/env python3
"""Fetch a VAA for a finalized Synthra publication and verify it with the receiving Core. Never signs."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

from preflight import RPC, address, cast, require, validate_pair

TOPIC = '0x6eb224fb001ed210e379b335e35efe88672a8ce935d981a6896b27ffdf52a3b2'
ACTIONS = {'deposit': 1, 'redemption': 2, 'metadata': 3}


def publication(receipt, block, core, emitter, chain):
    """Reconstruct the complete signed body from a unique canonical Core event."""
    require(receipt and receipt.get('status') == '0x1', 'publication transaction not successful/mined')
    require(block and receipt['blockHash'] == block['hash'], 'publication block changed')
    emitter_word = int(address(emitter), 16).to_bytes(32, 'big')
    matches = [log for log in receipt['logs'] if log['address'].lower() == address(core)
               and len(log['topics']) == 2 and log['topics'][0].lower() == TOPIC
               and log['topics'][1].lower() == '0x' + emitter_word.hex()]
    require(len(matches) == 1, 'expected exactly one publication from the configured endpoint')
    log = matches[0]
    require(not log.get('removed', False) and log['blockHash'] == block['hash'], 'removed publication')
    data = bytes.fromhex(log['data'].removeprefix('0x'))
    require(len(data) >= 160, 'truncated publication')
    sequence, nonce, offset, consistency, size = [int.from_bytes(data[i:i+32], 'big') for i in range(0, 160, 32)]
    require(sequence < 2**64 and nonce < 2**32 and consistency < 256 and offset == 128,
            'noncanonical publication encoding')
    require(len(data) == 160 + ((size + 31) // 32) * 32 and not any(data[160+size:]),
            'truncated or noncanonical publication payload')
    payload = data[160:160+size]
    body = (int(block['timestamp'], 16).to_bytes(4, 'big') + nonce.to_bytes(4, 'big')
            + chain.to_bytes(2, 'big') + emitter_word + sequence.to_bytes(8, 'big')
            + bytes([consistency]) + payload)
    return sequence, body, payload


def check_payload(payload, kind, source, destination, destination_endpoint):
    require(len(payload) == (384 if kind == 'metadata' else 320), 'unexpected application payload size')
    words = [int.from_bytes(payload[i:i+32], 'big') for i in range(0, len(payload), 32)]
    expected = [int(cast('keccak', 'synthra.rwa.bridge.v1'), 16), 1, ACTIONS[kind],
                source['evmChain'], destination['evmChain'], destination['wormholeChain'],
                int(address(destination_endpoint), 16), int(address(source['sourceAsset']), 16)]
    require(words[:8] == expected, 'message kind or configured bridge route mismatch')


def checked_vaa(encoded, expected_body):
    require(len(encoded) >= 6 and encoded[0] == 1 and 0 < encoded[5] <= 19, 'malformed VAA header')
    offset = 6 + 66 * encoded[5]
    require(len(encoded) >= offset + 51 and encoded[offset:] == expected_body,
            'VAA body differs from finalized publication')
    return '0x' + encoded.hex()


def retrieve(url):
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'Synthra-ReadOnly-VAA-Fetch/1.0'})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise ValueError('VAA not indexed yet; rerun this fetch later, do not repeat the source transaction') from error
        raise ValueError(f'VAA service returned HTTP {error.code}; no transaction was sent') from error
    except Exception as error:
        raise ValueError('VAA service unavailable; no transaction was sent') from error
    require(isinstance(data.get('vaaBytes'), str),
            'VAA unavailable; rerun this fetch later, do not repeat the source transaction')
    return base64.b64decode(data['vaaBytes'], validate=True)


def write_vaa(path, value):
    require(path.suffix == '.hex', 'output must end in .hex')
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        require(path.read_text().strip() == value, 'output already contains a different VAA; preserve it')
    else:
        with path.open('x') as file:
            file.write(value + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pair', required=True)
    parser.add_argument('--kind', choices=ACTIONS, required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--tx')
    group.add_argument('--receipt', help='JSON receipt saved by cast send --json; corroborated independently onchain')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    tx_hash = args.tx if args.tx else json.loads(Path(args.receipt).read_text())['transactionHash']
    require(re.fullmatch(r'0x[0-9a-fA-F]{64}', tx_hash), 'invalid publication transaction hash')
    pair = json.loads(Path(args.pair).read_text())
    configs = {side: json.loads(Path(pair[side]['deployment']).read_text()) for side in ('source', 'destination')}
    validate_pair(configs['source'], configs['destination'])
    start, finish = ('destination', 'source') if args.kind == 'redemption' else ('source', 'destination')
    source, destination = configs[start], configs[finish]
    rpc, verifier = [RPC(os.environ[pair[side]['rpcEnv']]) for side in (start, finish)]
    for client, config in ((rpc, source), (verifier, destination)):
        require(int(client.request('eth_chainId', []), 16) == config['evmChain'], 'wrong RPC chain')
    receipt = rpc.request('eth_getTransactionReceipt', [tx_hash])
    require(receipt and receipt.get('status') == '0x1', 'publication transaction not successful/mined')
    finalized = rpc.request('eth_getBlockByNumber', ['finalized', False])
    require(finalized and int(receipt['blockNumber'], 16) <= int(finalized['number'], 16),
            'publication not finalized yet; rerun this fetch later, do not repeat the source transaction')
    block = rpc.request('eth_getBlockByNumber', [receipt['blockNumber'], False])
    sequence, body, payload = publication(receipt, block, source['core'], pair[start]['endpoint'], source['wormholeChain'])
    check_payload(payload, args.kind, source, destination, pair[finish]['endpoint'])
    require(body[50] == source['outboundConsistency'], 'unexpected publication consistency')
    vaa_id = f"{source['wormholeChain']}/{body[10:42].hex()}/{sequence}"
    encoded = retrieve('https://api.wormholescan.io/v1/signed_vaa/' + vaa_id)
    vaa = checked_vaa(encoded, body)
    verified = verifier.request('eth_call', [{'to': address(destination['core']),
                                'data': cast('calldata', 'parseAndVerifyVM(bytes)', vaa)}, 'latest'])
    raw = bytes.fromhex(verified.removeprefix('0x'))
    require(len(raw) >= 96 and int.from_bytes(raw[32:64], 'big') == 1,
            'receiving Wormhole Core rejected the signatures')
    require(rpc.request('eth_getBlockByNumber', [receipt['blockNumber'], False])['hash'] == block['hash'],
            'publication block changed during verification')
    path = Path(args.output)
    write_vaa(path, vaa)
    print(json.dumps({'vaaId': vaa_id, 'file': str(path), 'kind': args.kind,
                     'publicationFinalized': True, 'receivingCoreVerified': True,
                     'notice': 'No transaction sent. Run prepare_relay.py before signing the completion.'}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if isinstance(error, (ValueError, KeyError)):
            raise SystemExit(f'VAA fetch stopped: {error}')
        raise SystemExit('VAA fetch stopped: local input or tool failure; no transaction sent.')
