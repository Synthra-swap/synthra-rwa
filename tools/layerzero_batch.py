#!/usr/bin/env python3
"""Roll out reviewed stocks sequentially. Simulation is the default; NVDA is excluded by default.

Each stock retains independent configurations, attempt markers and receipts.
An ambiguous broadcast stops the batch and requires reconciliation, never a retry.
"""
import argparse
import json
import subprocess
from pathlib import Path

import layerzero_deploy as deploy
import layerzero_operate as operate
from evm_rpc import require


def deployed_phase(chain, record):
    rpc = deploy.rpc_for(chain)
    if rpc.call(record['endpoint'], 'pausedLanes()', 'latest') == 0:
        return 'active'
    return 'paired' if rpc.call(record['endpoint'], 'peer()', 'latest') else 'deployed'


def metadata_packet():
    receipt_path = deploy.STATE / 'operations/metadata-initial/receipt.json'
    require(receipt_path.exists(), 'Publish metadata first, or reconcile its missing receipt; never repeat publication.')
    receipt = json.loads(receipt_path.read_text())
    # packet() independently validates the source receipt, emitter, domain and canonical block.
    return operate.packet('robinhood', receipt['transactionHash'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'deploy', 'wire', 'activate', 'metadata', 'status', 'complete', 'export-frontend'])
    parser.add_argument('--assets', nargs='+', choices=list(deploy.stock_catalog()),
                        default=[s for s in deploy.stock_catalog() if s != 'NVDA'])
    parser.add_argument('--chain', choices=['robinhood', 'arc'])
    parser.add_argument('--broadcast', action='store_true')
    parser.add_argument('--output', type=Path, default=deploy.ROOT.parent / 'data-dex-frontend/src/lib/rwaBridge/layerzero-deployment.json')
    args = parser.parse_args()
    require(len(args.assets) == len(set(args.assets)), 'Duplicate assets in batch')
    require(not args.broadcast or args.action in ('deploy', 'wire', 'activate', 'metadata', 'complete'), 'This action does not broadcast')
    if args.action in ('deploy', 'wire', 'activate'):
        require(args.chain is not None, '--chain is required')
    waiting = []
    for symbol in args.assets:
        print(f'\n{symbol}: {args.action}', flush=True)
        operate.select_asset(symbol)
        if args.action == 'prepare':
            deploy.prepare()
            continue
        if args.action == 'deploy':
            record_path = deploy.CONFIG / (args.chain + '.deployed.json')
            if record_path.exists():
                record = json.loads(record_path.read_text())
                deploy.inspect(args.chain, record, deployed_phase(args.chain, record))
                print('Existing deployment verified; skipped.')
            else:
                deploy.deploy(args.chain, args.broadcast)
            continue
        if args.action == 'wire':
            record = operate.records()[args.chain]
            phase = deployed_phase(args.chain, record)
            if phase in ('paired', 'active'):
                deploy.inspect(args.chain, record, phase)
                print('Existing pair verified; skipped.')
                continue
        if args.action in ('metadata', 'status', 'complete', 'export-frontend'):
            receipt_path = deploy.STATE / 'operations/metadata-initial/receipt.json'
            if args.action != 'metadata' or receipt_path.exists():
                packet = metadata_packet()
                state = operate.packet_status(packet)
                print(f'Metadata: {state}; source transaction: {packet["sourceHash"]}', flush=True)
                if args.action in ('metadata', 'status'):
                    continue
                if args.action == 'export-frontend':
                    require(state == 'complete', 'Receive metadata before exporting this stock')
                    wrapped = operate.records()['arc']['wrapped']
                    require(deploy.rpc_for('arc').call(wrapped, 'metadataFresh()', 'latest') == 1,
                            'Refresh expired metadata before exporting this stock')
                    operate.export_frontend(args.output.resolve())
                    continue
                if state == 'complete':
                    continue
                if state != 'ready':
                    waiting.append(symbol)
                    continue
        operation_id = {'metadata': 'metadata-initial', 'complete': 'metadata-complete'}.get(
            args.action, args.action + '-' + str(args.chain))
        operate.operate(argparse.Namespace(
            action=args.action, chain=args.chain if args.action in ('wire', 'activate') else 'robinhood',
            broadcast=args.broadcast, id=operation_id, amount_raw=None,
            tx=packet['sourceHash'] if args.action == 'complete' else None, output=str(args.output)))
    if waiting:
        print('Still attesting: ' + ', '.join(waiting) + '. Rerun complete later; do not republish.')
    print('Batch finished. Existing successful actions were preserved.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        raise SystemExit('Batch stopped: ' + (str(exc) if isinstance(exc, ValueError)
                         else 'Missing input or tool failure. Preserve receipts and reconcile the current stock.'))
