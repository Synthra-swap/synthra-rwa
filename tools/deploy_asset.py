#!/usr/bin/env python3
"""Simulate one reviewed asset/chain. Broadcast requires an explicit flag and a local signer."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time

from prepare_deployment import ROOT, digest
from preflight import RPC, address, require, validate_pair


def load(bundle_path, symbol, side, root=ROOT):
    root = root.resolve()
    bundle = json.loads(bundle_path.read_text())
    require(bundle['schema'] == 1, 'unsupported bundle')
    for section in ('filesSha256', 'buildInputsSha256'):
        for name, expected in bundle[section].items():
            path = (root / name).resolve()
            require(path.is_relative_to(root), 'bundle path outside repository')
            require(digest(path) == expected, f'changed bundle input: {name}')
    entries = [a for a in bundle['assets'] if a['symbol'] == symbol]
    require(len(entries) == 1, 'asset missing or duplicated')
    entry = entries[0]
    configs = []
    for name in ('source', 'destination'):
        file = entry[name]['deployment']
        require(file in bundle['filesSha256'], 'deployment file not in manifest')
        configs.append(json.loads((root / file).read_text()))
        address(entry[name]['sender'])
    validate_pair(*configs)
    require(configs[0]['maxTransferRaw'] == configs[0]['inboundMaxTransferRaw'], 'not initial deployment limits')
    return entry, configs[0 if side == 'source' else 1]


def check_network(rpc, config, entry, side, finalized=False):
    require(int(rpc.request('eth_chainId', []), 16) == int(config['evmChain']), 'RPC on wrong chain')
    block = rpc.request('eth_getBlockByNumber', ['finalized' if finalized else 'latest', False])
    require(block is not None, 'required block unavailable')
    pin = block['number']
    core = config['core']
    require(rpc.request('eth_getCode', [core, pin]) != '0x', 'Core code missing')
    require(rpc.call(core, 'chainId()', pin) == int(config['wormholeChain']), 'wrong Core domain')
    require(rpc.call(core, 'evmChainId()', pin) == int(config['evmChain']), 'wrong Core EVM domain')
    if side == 'source':
        token = config['sourceAsset']
        require(rpc.request('eth_getCode', [token, pin]) != '0x', 'asset code missing')
        require(rpc.call(token, 'uid()', pin) == int(entry['uid'], 16), 'asset UID mismatch')
        require(rpc.call(token, 'decimals()', pin) == 18, 'asset decimals mismatch')
    require(rpc.request('eth_getBlockByNumber', [pin, False])['hash'] == block['hash'], 'block changed')
    return {'number': pin, 'hash': block['hash'], 'finalized': finalized}


def command(config, sender, rpc_url):
    result = ['forge', 'script', 'script/Deploy.s.sol:Deploy', '--rpc-url', rpc_url,
              '--sender', address(sender), '--non-interactive']
    compiler = ROOT / '.tools/solc-0.8.28'
    if compiler.exists():
        result += ['--use', str(compiler), '--offline']
    return result


def simulation_environment(environ, deployment, state):
    # Do not let an inherited compiler/profile override silently change reviewed bytecode.
    env = {k: v for k, v in environ.items()
           if not k.startswith(('FOUNDRY_', 'DAPP_')) and k != 'DEPLOYER_PRIVATE_KEY'}
    env.update(DEPLOY_CONFIG=str(ROOT / deployment), FOUNDRY_PROFILE='deployment',
               FOUNDRY_BROADCAST=str(state / 'foundry'))
    return env


def run_logged(cmd, env, path, secret=None):
    # Do not print argv: it may contain a local signer key or a private RPC URL.
    run = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    output = run.stdout + run.stderr
    for value in (secret, env.get('SOURCE_RPC_URL'), env.get('DESTINATION_RPC_URL')):
        if value:
            output = output.replace(value, '[REDACTED]')
    path.write_text(output)
    path.chmod(0o600)
    require(run.returncode == 0, f'Foundry failed; inspect {path.relative_to(ROOT)}')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--asset', required=True)
    parser.add_argument('--side', choices=('source', 'destination'), required=True)
    parser.add_argument('--broadcast', action='store_true')
    args = parser.parse_args()
    bundle_path = Path(args.bundle).resolve()
    entry, config = load(bundle_path, args.asset, args.side)
    meta = entry[args.side]
    require(meta['rpcEnv'] in ('SOURCE_RPC_URL', 'DESTINATION_RPC_URL'), 'unexpected RPC environment name')
    rpc_url = os.environ[meta['rpcEnv']]
    rpc = RPC(rpc_url)
    snapshot = check_network(rpc, config, entry, args.side, finalized=args.broadcast)
    state = ROOT / '.tools/deployment-runs' / str(config['evmChain']) / args.asset
    state.mkdir(parents=True, exist_ok=True)
    marker = state / 'broadcast-attempt.json'
    require(not marker.exists(), 'broadcast already attempted; reconcile receipts before any rerun')
    env = simulation_environment(os.environ, meta['deployment'], state)
    key = os.environ.get('DEPLOYER_PRIVATE_KEY')
    if args.broadcast:
        require(isinstance(key, str) and re.fullmatch(r'(0x)?[0-9a-fA-F]{64}', key),
                'set DEPLOYER_PRIVATE_KEY locally; never put it in config or chat')
        signer = subprocess.run(['cast', 'wallet', 'address', '--private-key', key],
                                capture_output=True, text=True, env=env)
        require(signer.returncode == 0, 'cannot derive signer address')
        require(address(signer.stdout.strip()) == address(meta['sender']), 'signer differs from reviewed deployer')
    stamp = str(time.time_ns())
    cmd = command(config, meta['sender'], rpc_url)
    output = run_logged(cmd, env, state / (stamp + '-simulation.log'))
    report = {'asset': args.asset, 'side': args.side, 'sender': meta['sender'], 'snapshot': snapshot,
              'bundleSha256': digest(bundle_path), 'simulationPassed': True,
              'observedAtUTC': datetime.now(timezone.utc).isoformat(),
              'notice': 'Independent simulation; addresses/nonces must be reconciled with actual receipts.'}
    (state / (stamp + '-simulation.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(f"{args.asset} {args.side}: simulation passed. Logs: {state.relative_to(ROOT)}", flush=True)
    for line in output.splitlines():
        if any(label in line for label in ('Timelock:', 'Endpoint:', 'Wrapped:', 'Estimated total gas', 'Amount required')):
            print(line)
    if args.broadcast:
        # Exclusive marker prevents simultaneous/repeated submissions after partial deployment.
        # It intentionally remains after errors. Never automatically resume or retry a broadcast.
        with marker.open('x') as file:
            json.dump(dict(report, status='attempting; reconcile receipts before retry'), file, indent=2)
        run_logged(cmd + ['--broadcast', '--slow', '--private-key', key], env,
                   state / (stamp + '-broadcast.log'), secret=key)
        marker.write_text(json.dumps(dict(report, status='Foundry broadcast completed; verify receipts and paused state'), indent=2) + '\n')
        print('Broadcast completed. Preserve receipts; endpoints are still paused. Follow docs/DEPLOYMENT_BUNDLE.md.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        # RPC transport/Foundry commands can contain credentials. Do not emit tracebacks or argv.
        if isinstance(error, ValueError):
            raise SystemExit(f'Deployment stopped: {error}')
        raise SystemExit('Deployment stopped: missing input or tool failure; inspect local configuration/logs.')
