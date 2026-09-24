#!/usr/bin/env python3
"""Observe existing third-party messages and verify their signed VAA with the opposite live Core.
Read-only. Never publishes a message. This does not establish Synthra end-to-end liveness.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from network_probe import NETWORKS, OUTPUT, ReadRPC, cast, get, require

TOPIC = '0x6eb224fb001ed210e379b335e35efe88672a8ce935d981a6896b27ffdf52a3b2'


def observe(source_name, target_name):
    source, target = NETWORKS[source_name], NETWORKS[target_name]
    rpc, verifier = ReadRPC(source['rpc']), ReadRPC(target['rpc'])
    result = {'source': source_name, 'verifier': target_name, 'verified': False}
    try:
        require(int(rpc.request('eth_chainId', []), 16) == source['evmChain'], 'wrong source chain')
        require(int(verifier.request('eth_chainId', []), 16) == target['evmChain'], 'wrong verifier chain')
        block = rpc.request('eth_getBlockByNumber', ['finalized', False])
        height = int(block['number'], 16)
        result['sourceBlock'] = {k: block[k] for k in ('number', 'hash', 'timestamp')}
        logs = rpc.request('eth_getLogs', [{'address': source['core'], 'topics': [TOPIC],
            'fromBlock': hex(max(0, height - 9999)), 'toBlock': block['number']}])
        result['observedLogCount'] = len(logs)
        if logs:
            log = logs[-1]
        else:
            # Sparse networks: use the index only to locate a transaction, then corroborate onchain.
            index_url = f"https://api.wormholescan.io/api/v1/vaas/{source['wormholeChain']}?pageSize=1"
            index = json.loads(get(index_url))
            result['indexURL'], result['indexResponse'] = index_url, index
            require(index.get('data'), 'no indexed source VAA available')
            item = index['data'][0]
            require(item['emitterChain'] == source['wormholeChain'], 'index returned wrong chain')
            tx = '0x' + item['txHash'].removeprefix('0x')
            receipt = rpc.request('eth_getTransactionReceipt', [tx])
            require(receipt and int(receipt['status'], 16) == 1, 'no successful source receipt')
            require(int(receipt['blockNumber'], 16) <= height, 'indexed transaction not yet finalized')
            matches = [entry for entry in receipt['logs'] if entry['address'].lower() == source['core'].lower()
                and entry['topics'][0] == TOPIC and entry['topics'][1][2:] == item['emitterAddr']
                and int(entry['data'][2:66], 16) == int(item['sequence'])]
            require(len(matches) == 1, 'index does not match a unique Core publication')
            log = matches[0]
        publication_block = rpc.request('eth_getBlockByNumber', [log['blockNumber'], False])
        require(publication_block['hash'] == log['blockHash'] and not log.get('removed', False),
                'publication removed or on different block')
        result['log'] = log
        emitter = log['topics'][1][2:]
        sequence = int(log['data'][2:66], 16)
        identifier = f"{source['wormholeChain']}/{emitter}/{sequence}"
        url = f'https://api.wormholescan.io/v1/signed_vaa/{identifier}'
        response = json.loads(get(url))
        encoded = base64.b64decode(response['vaaBytes'], validate=True)
        # Compare signed body to independently read publication, not merely an API supplied ID.
        body = encoded[6 + 66 * encoded[5]:]
        require(encoded[0] == 1 and len(body) >= 51, 'malformed VAA')
        require(int.from_bytes(body[:4], 'big') == int(publication_block['timestamp'], 16),
                'VAA timestamp differs from source block')
        require(int.from_bytes(body[8:10], 'big') == source['wormholeChain'], 'wrong VAA chain')
        require(body[10:42].hex() == emitter and int.from_bytes(body[42:50], 'big') == sequence,
                'VAA identity does not match observed publication')
        words = bytes.fromhex(log['data'][2:])
        nonce = int.from_bytes(words[32:64], 'big')
        offset = int.from_bytes(words[64:96], 'big')
        consistency = int.from_bytes(words[96:128], 'big')
        size = int.from_bytes(words[offset:offset + 32], 'big')
        require(int.from_bytes(body[4:8], 'big') == nonce and body[50] == consistency and
                body[51:] == words[offset + 32:offset + 32 + size], 'VAA body differs from publication')
        # Robinhood public endpoint cannot serve finalized historical state: label latest explicitly.
        pin = verifier.request('eth_getBlockByNumber', ['latest', False])
        result['verifierBlockTag'] = 'latest'
        result['verifierBlock'] = {k: pin[k] for k in ('number', 'hash', 'timestamp')}
        raw = verifier.call(target['core'], 'parseAndVerifyVM(bytes)', pin['number'], '0x' + encoded.hex())
        require(len(raw) >= 194 and int(raw[66:130], 16) == 1, 'opposite live Core rejected VAA')
        check = verifier.request('eth_getBlockByNumber', [pin['number'], False])
        require(check['hash'] == pin['hash'], 'verifier block changed')
        result.update(verified=True, vaaID=identifier, vaaURL=url, vaaHex='0x' + encoded.hex(),
                      consistencyLevel=consistency, guardianSetIndex=int.from_bytes(encoded[1:5], 'big'))
    except Exception as error:
        result['error'] = str(error)
    result['sourceRPC'] = rpc.trace
    result['verifierRPC'] = verifier.trace
    return result


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=2) as executor:
        jobs = [executor.submit(observe, *pair) for pair in [('robinhood', 'arc'), ('arc', 'robinhood')]]
        results = [job.result() for job in jobs]
    (OUTPUT / 'live-vaa-verification.json').write_text(json.dumps({
        'observedAtUTC': datetime.now(timezone.utc).isoformat(), 'results': results}, indent=2) + '\n')
    for result in results:
        print(result['source'], '->', result['verifier'], 'verified:', result['verified'], result.get('error', ''))
    return 0 if all(r['verified'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
