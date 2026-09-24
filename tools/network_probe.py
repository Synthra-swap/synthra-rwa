#!/usr/bin/env python3
"""Read-only public-network evidence. Never signs, submits, or calls send/debug RPC methods.

Research addresses are not deployment approval. RPC/explorer assertions still need independent
corroboration; this records observations and failed checks without converting failures into passes.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
from preflight import address, require

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'audit/network'
NETWORKS = {
    'robinhood': {'rpc': 'https://rpc.mainnet.chain.robinhood.com', 'evmChain': 4663, 'wormholeChain': 72,
                 'core': '0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB',
                 'reference': 'https://docs.robinhood.com/chain/connecting/'},
    'arc': {'rpc': 'https://rpc.mainnet.arc.io', 'evmChain': 5042, 'wormholeChain': 71,
            'core': '0xC8aD24fC6063c41cB5C12a8e3851AafC3b3CF027',
            'reference': 'https://docs.arc.io/arc/references/connect-to-arc'},
}
ASSETS_URL = 'https://api.robinhood.com/rhj/assets'
SLOTS = {
    'implementation': '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
    'beacon': '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50',
    'admin': '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103',
}


def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip()


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Synthra-ReadOnly-Review/1.0'}), timeout=25) as response:
        return response.read(8 * 1024 * 1024)


class ReadRPC:
    ALLOWED = {'eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call', 'eth_getLogs',
               'eth_getTransactionReceipt'}

    def __init__(self, url):
        self.url, self.trace = url, []

    def request(self, method, params):
        require(method in self.ALLOWED, 'read-only RPC method required')
        payload = {'jsonrpc': '2.0', 'id': len(self.trace) + 1, 'method': method, 'params': params}
        entry = {'request': payload}
        self.trace.append(entry)
        try:
            request = urllib.request.Request(self.url, json.dumps(payload).encode(), {
                'Content-Type': 'application/json', 'User-Agent': 'Synthra-ReadOnly-Integration-Review/1.0'})
            with urllib.request.urlopen(request, timeout=25) as response:
                data = json.load(response)
            entry['response'] = data
            require(data.get('jsonrpc') == '2.0' and data.get('id') == payload['id'], 'mismatched RPC response')
            require('error' not in data and 'result' in data, f'RPC rejected {method}: {data.get("error")}')
            return data['result']
        except Exception as error:
            entry['error'] = str(error)
            raise

    def call(self, target, signature, block, *args):
        return self.request('eth_call', [{'to': address(target), 'data': cast('calldata', signature, *map(str, args))}, block])


def attempt(function):
    try:
        return {'ok': True, 'value': function()}
    except Exception as error:
        return {'ok': False, 'error': str(error)}


def inspect_code(rpc, target, pin):
    code = rpc.request('eth_getCode', [address(target), pin])
    require(code != '0x', 'no runtime code at pinned block')
    result = {'address': target, 'runtimeKeccak256': cast('keccak', code), 'runtimeBytes': (len(code) - 2) // 2, 'slots': {}}
    for name, slot in SLOTS.items():
        value = rpc.request('eth_getStorageAt', [target, slot, pin])
        result['slots'][name] = value
        if name in ('implementation', 'beacon') and int(value, 16):
            implementation = '0x' + value[-40:]
            remote_code = rpc.request('eth_getCode', [implementation, pin])
            result[name] = {'address': implementation, 'runtimeKeccak256': cast('keccak', remote_code),
                            'runtimeBytes': (len(remote_code) - 2) // 2}
            require(remote_code != '0x', f'{name} has no runtime code')
            if name == 'beacon':
                resolved = rpc.call(implementation, 'implementation()', pin)
                require(len(resolved) == 66 and int(resolved, 16) >> 160 == 0 and int(resolved, 16),
                        'invalid beacon implementation address')
                target_impl = address('0x' + resolved[-40:])
                impl_code = rpc.request('eth_getCode', [target_impl, pin])
                require(impl_code != '0x', 'beacon implementation has no runtime code')
                result['beaconImplementation'] = {'address': target_impl,
                    'runtimeKeccak256': cast('keccak', impl_code), 'runtimeBytes': (len(impl_code) - 2) // 2}
    return result


def probe(name, config, assets, block_tag='finalized'):
    rpc = ReadRPC(config['rpc'])
    result = {'network': name, 'configuration': config, 'blockTag': block_tag, 'calls': {}}
    try:
        actual = int(rpc.request('eth_chainId', []), 16)
        require(actual == config['evmChain'], 'unexpected EVM chain')
        block = rpc.request('eth_getBlockByNumber', [block_tag, False])
        require(block is not None, f'no {block_tag} block')
        pin = block['number']
        result['block'] = {key: block[key] for key in ('number', 'hash', 'timestamp')}
        result['core'] = attempt(lambda: inspect_code(rpc, config['core'], pin))
        for signature in ('chainId()', 'evmChainId()', 'messageFee()', 'getCurrentGuardianSetIndex()', 'governanceChainId()', 'governanceContract()'):
            result['calls'][signature] = attempt(lambda s=signature: rpc.call(config['core'], s, pin))
        for signature, expected in (('chainId()', config['wormholeChain']), ('evmChainId()', config['evmChain'])):
            observed = result['calls'][signature]
            require(observed['ok'], f'Core identity unavailable: {signature}')
            require(int(observed['value'], 16) == expected, f'Core identity mismatch: {signature}')
        index = result['calls']['getCurrentGuardianSetIndex()']
        if index['ok']:
            result['guardianSet'] = attempt(lambda: rpc.call(config['core'], 'getGuardianSet(uint32)', pin, int(index['value'], 16)))
        result['assets'] = []
        for asset in assets:
            target = asset['address']
            item = {'symbol': asset['symbol'], 'registry': asset, 'code': attempt(lambda: inspect_code(rpc, target, pin)), 'calls': {}}
            for signature in ('decimals()', 'uiMultiplier()', 'newUIMultiplier()', 'effectiveAt()', 'totalSupply()', 'name()', 'symbol()', 'uid()', 'owner()', 'paused()'):
                item['calls'][signature] = attempt(lambda s=signature: rpc.call(target, s, pin))
            result['assets'].append(item)
        check = rpc.request('eth_getBlockByNumber', [pin, False])
        require(check is not None and check['hash'] == block['hash'], 'pinned block changed')
        result['snapshotRechecked'] = True
        require(result['core']['ok'], 'Core code inspection incomplete')
        require(all(value['ok'] for value in result['calls'].values()) and result['guardianSet']['ok'],
                'Core reads incomplete')
        for item in result['assets']:
            require(item['code']['ok'], f"{item['symbol']} code inspection incomplete")
            for signature in ('decimals()', 'uiMultiplier()', 'newUIMultiplier()', 'effectiveAt()', 'uid()'):
                require(item['calls'][signature]['ok'], f"{item['symbol']} {signature} unavailable")
            require(int(item['calls']['decimals()']['value'], 16) == 18, 'unsupported asset decimals')
            require(int(item['calls']['uiMultiplier()']['value'], 16) > 0 and
                    int(item['calls']['newUIMultiplier()']['value'], 16) > 0, 'invalid multiplier')
            require(int(item['calls']['uid()']['value'], 16) == int(item['registry']['assetId'], 16),
                    'asset UID differs from official registry')
        result['compatibilityReadsPassed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        (OUTPUT / f'{name}-{block_tag}-rpc.json').write_text(json.dumps(rpc.trace, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--block-tag', choices=('finalized', 'latest'), default='finalized',
                        help='latest is diagnostic only and does not establish finality')
    parser.add_argument('--network', choices=tuple(NETWORKS))
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    body = get(ASSETS_URL)
    (OUTPUT / 'asset-registry.json').write_bytes(body)
    registry = json.loads(body)['assets']
    assets = []
    for symbol in ('AAPL', 'NVDA', 'TSLA', 'SPY'):
        candidates = [a for a in registry if a['tokenSymbol'] == symbol]
        require(len(candidates) == 1, f'ambiguous/missing official symbol {symbol}')
        item = candidates[0]
        deployments = [d for d in item['deployments'] if d['chainId'] == 4663]
        require(len(deployments) == 1, f'ambiguous/missing source deployment {symbol}')
        assets.append({'symbol': symbol, 'address': address(deployments[0]['contractAddress']),
                       'assetId': item['id'], 'status': item['status'], 'apiMultiplier': item['currentMultiplier']})
    with ThreadPoolExecutor(max_workers=2) as executor:
        jobs = [executor.submit(probe, name, config, assets if name == 'robinhood' else [], args.block_tag)
                for name, config in NETWORKS.items() if not args.network or args.network == name]
        results = [job.result() for job in jobs]
    report = {'observedAtUTC': datetime.now(timezone.utc).isoformat(), 'registryURL': ASSETS_URL,
              'registrySha256': hashlib.sha256(body).hexdigest(), 'networks': results,
              'notice': 'Read-only observations, not deployment approval, live bridging, or issuer authorization.'}
    (OUTPUT / f'observations-{args.network or "both"}-{args.block_tag}.json').write_text(json.dumps(report, indent=2) + '\n')
    for result in results:
        print(result['network'], 'snapshot rechecked:', result.get('snapshotRechecked', False), 'error:', result.get('error', 'none'), flush=True)
    return 0 if all(result.get('compatibilityReadsPassed', False) for result in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
