#!/usr/bin/env python3
"""Build per-asset deployment files from reviewed, dated inputs. Offline; never signs."""
import argparse
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re

from preflight import address, require, uint, validate_pair

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decimal(value):
    require(isinstance(value, str) and re.fullmatch(r'(0|[1-9][0-9]*)(\.[0-9]+)?', value),
            'expected positive decimal string')
    result = Fraction(value)
    require(result > 0, 'decimal must be positive')
    return result


def raw_amount(usd, ask, multiplier):
    # REST prices are USD per underlying share, NOT multiplier-adjusted token prices.
    m = uint(multiplier)
    require(m > 0, 'zero multiplier')
    amount = decimal(usd) * 10**36 / (decimal(ask) * m)
    result = amount.numerator // amount.denominator
    require(0 < result < 2**256, 'raw amount outside uint256 range')
    return result


def make_pair(plan, asset, now):
    require(re.fullmatch(r'[A-Z][A-Z0-9]{0,15}', asset['symbol']), 'invalid asset symbol')
    address(asset['token'])
    require(re.fullmatch(r'0x[0-9a-fA-F]{64}', asset['uid']), 'invalid asset UID')
    require(asset['decimals'] == 18 and type(asset['decimals']) is int, 'requires 18 decimals')
    require(asset['currency'] == 'USD' and asset['isTradingHalt'] is False, 'quote unavailable or halted')
    require(asset['registryStatus'] == 'ASSET_STATUS_ACTIVE', 'inactive registry asset')
    require(decimal(asset['quoteBidUsd']) <= decimal(asset['quoteAskUsd']), 'crossed quote')
    require(decimal(asset['registryMultiplier']) * 10**18 == uint(asset['multiplierRaw']),
            'registry/onchain multiplier mismatch')
    for field in ('quoteGeneratedAt', 'multiplierObservedAt'):
        observed = datetime.fromisoformat(asset[field].replace('Z', '+00:00'))
        require(observed.tzinfo is not None, 'timestamp needs timezone')
        require(-300 <= (now - observed).total_seconds() <= 86400, 'stale or future reference input')
    maximum = raw_amount(plan['referenceLimitUsd'], asset['quoteAskUsd'], asset['multiplierRaw'])
    gross = raw_amount(plan['referenceTestUsd'], asset['quoteAskUsd'], asset['multiplierRaw'])
    require(gross <= maximum and gross * 50 // 10000 > 0, 'invalid test amount')
    configs = []
    for side, other in (('source', 'destination'), ('destination', 'source')):
        network, remote = plan[side], plan[other]
        address(network['deployer'])
        c = {key: network[key] for key in ('evmChain', 'wormholeChain', 'core', 'governanceSafe', 'guardian')}
        c.update(sourceSide=side == 'source', remoteEvmChain=remote['evmChain'],
                 remoteWormholeChain=remote['wormholeChain'], sourceAsset=asset['token'],
                 treasury=plan['source']['treasury'], governanceDelaySeconds=plan['governanceDelaySeconds'],
                 outboundConsistency=network['outboundConsistency'], inboundConsistency=network['inboundConsistency'],
                 maxTransferRaw=str(maximum), inboundMaxTransferRaw=str(maximum),
                 metadataMaxAgeSeconds=plan['metadataMaxAgeSeconds'],
                 name=asset['wrappedName'], symbol=asset['wrappedSymbol'])
        require(isinstance(c['name'], str) and 0 < len(c['name']) <= 100, 'invalid wrapped name')
        require(re.fullmatch(r'[A-Za-z][A-Za-z0-9]{0,15}', c['symbol']), 'invalid wrapped symbol')
        configs.append(c)
    validate_pair(*configs)
    amounts = {'symbol': asset['symbol'], 'maxTransferRaw': str(maximum), 'testGrossRaw': str(gross),
               'testFeeRaw': str(gross * 50 // 10000), 'testNetRaw': str(gross - gross * 50 // 10000)}
    return configs, amounts


def build(plan, output, root=ROOT, now=None):
    now = now or datetime.now(timezone.utc)
    root, output = root.resolve(), output.resolve()
    require(output.is_relative_to(root / 'config' / 'deployments'), 'output must be under config/deployments')
    require(not output.exists(), 'output already exists; use a new directory, never overwrite a deployment')
    require(plan['amountPolicyApproved'] is True, 'amount policy not approved')
    require(isinstance(plan['assets'], list) and plan['assets'], 'empty assets')
    symbols = [a['symbol'] for a in plan['assets']]
    tokens = [address(a['token']) for a in plan['assets']]
    wrapped = [a['wrappedSymbol'] for a in plan['assets']]
    require(len(set(symbols)) == len(symbols) and len(set(tokens)) == len(tokens)
            and len(set(wrapped)) == len(wrapped), 'duplicate asset or wrapped symbol')
    # Validate the entire set before creating any deployment files.
    prepared = [make_pair(plan, asset, now) for asset in plan['assets']]
    files, records = {}, []
    for asset, (configs, amounts) in zip(plan['assets'], prepared):
        folder = output / asset['symbol']
        pair = json.loads((root / 'config/pair.example.json').read_text())
        entry = dict(amounts, uid=asset['uid'], wrappedSymbol=asset['wrappedSymbol'])
        for side, c in zip(('source', 'destination'), configs):
            relative = str((folder / (side + '.json')).relative_to(root))
            files[relative] = c
            pair[side]['deployment'] = relative
            entry[side] = {'deployment': relative, 'sender': plan[side]['deployer'],
                           'rpcEnv': pair[side]['rpcEnv']}
        files[str((folder / 'pair.pending.json').relative_to(root))] = pair
        records.append(entry)
    files[str((output / 'reviewed-inputs.json').relative_to(root))] = plan
    for path, body in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(body, indent=2) + '\n')
    inputs = [p for folder in ('src', 'script', 'vendor') for p in (root / folder).rglob('*') if p.is_file()]
    inputs += [root / p for p in ('foundry.toml', 'tools/prepare_deployment.py', 'tools/deploy_asset.py',
                                  'tools/preflight.py')]
    bundle = {'schema': 1, 'createdAtUTC': now.isoformat(), 'assets': records,
              'filesSha256': {path: digest(root / path) for path in files},
              'buildInputsSha256': {str(p.relative_to(root)): digest(p) for p in sorted(inputs)},
              'notice': 'Prepared configuration only. No deployment, audit sign-off or finalized-state proof. '
                        'Each independent simulation uses the current nonce; predicted addresses across assets '
                        'are not a batch deployment address plan. Record actual receipts after each broadcast.'}
    (output / 'bundle.json').write_text(json.dumps(bundle, indent=2) + '\n')
    rows = ['# Deployment amounts', '', 'Reference: REST ask in USD per underlying share; onchain multiplier.',
            'Raw = floor(USD × 10^36 / (ask × multiplierRaw)). Fixed raw limits; no live USD oracle.', '',
            '| Stock | Ask USD | Multiplier raw | Maximum raw | Test gross raw | Test fee raw |',
            '| --- | --- | --- | --- | --- | --- |']
    for a, r in zip(plan['assets'], records):
        rows.append(f"| {a['symbol']} | {a['quoteAskUsd']} | {a['multiplierRaw']} | {r['maxTransferRaw']} | {r['testGrossRaw']} | {r['testFeeRaw']} |")
    (output / 'AMOUNTS.md').write_text('\n'.join(rows) + '\n')
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    bundle = build(json.loads(Path(args.plan).read_text()), Path(args.output))
    print(f"Prepared {len(bundle['assets'])} asset pairs; no network access or transactions.")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit(f'Preparation failed: {error}')
