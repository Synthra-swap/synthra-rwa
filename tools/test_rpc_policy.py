"""Pacing and split-provider failures must not bypass finalized-state checks."""
from concurrent.futures import ThreadPoolExecutor
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from deploy_asset import deployment_snapshot, main, run_logged
from preflight import RPC
from rpc_policy import finalized_url, is_nodeflare_public, public_rpc_slot


PUBLIC = 'https://rpc.nodeflare.app/robinhood/public'
ENVS = {'SOURCE_RPC_URL': 'https://execution.invalid', 'SOURCE_FINALIZED_RPC_URL': PUBLIC}
SNAPSHOT = {'number': '0x20', 'hash': '0x' + 'a' * 64, 'finalized': True}


class PublicRPCPolicyTests(unittest.TestCase):
    def test_override_is_optional_and_chain_specific(self):
        self.assertEqual(finalized_url('SOURCE_RPC_URL', ENVS), PUBLIC)
        self.assertEqual(finalized_url('SOURCE_RPC_URL', {'SOURCE_RPC_URL': 'base'}), 'base')
        self.assertEqual(finalized_url('DESTINATION_RPC_URL', dict(ENVS, DESTINATION_RPC_URL='arc')), 'arc')
        self.assertEqual(finalized_url('CUSTOM_RPC', {'CUSTOM_RPC': 'custom'}), 'custom')

    def test_only_keyless_robinhood_endpoint_is_paced(self):
        self.assertTrue(is_nodeflare_public(PUBLIC))
        self.assertTrue(is_nodeflare_public(PUBLIC + '/'))
        for url in ('https://rpc.nodeflare.app/robinhood/v1/key',
                    'https://rpc.nodeflare.app.attacker.invalid/robinhood/public',
                    'https://rpc.mainnet.chain.robinhood.com'):
            self.assertFalse(is_nodeflare_public(url))
            with patch('rpc_policy.PACE_FILE') as path, public_rpc_slot(url):
                path.open.assert_not_called()

    def test_pacing_applies_across_instances_and_after_failure(self):
        with tempfile.TemporaryDirectory() as tmp, \
             patch('rpc_policy.PACE_FILE', Path(tmp) / 'pace.lock'), \
             patch('rpc_policy.time.time', return_value=100), \
             patch('rpc_policy.time.sleep') as sleep:
            with self.assertRaises(RuntimeError), public_rpc_slot(PUBLIC):
                raise RuntimeError('failed request still consumes its slot')
            with public_rpc_slot(PUBLIC):
                pass
            sleep.assert_called_once_with(11.0)

    def test_backwards_clock_change_has_bounded_wait(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'pace.lock'; path.write_text('99999999999')
            with patch('rpc_policy.PACE_FILE', path), \
                 patch('rpc_policy.time.time', return_value=100), \
                 patch('rpc_policy.time.sleep') as sleep, public_rpc_slot(PUBLIC):
                sleep.assert_called_once_with(11.0)

    def test_concurrent_callers_share_lock_and_interval(self):
        with tempfile.TemporaryDirectory() as tmp, \
             patch('rpc_policy.PACE_FILE', Path(tmp) / 'pace.lock'), \
             patch('rpc_policy.NODEFLARE_INTERVAL', 0.04):
            barrier = threading.Barrier(3)
            def request(_):
                barrier.wait()
                with public_rpc_slot(PUBLIC):
                    start = time.monotonic()
                    time.sleep(0.01)
                    return start, time.monotonic()
            with ThreadPoolExecutor(max_workers=3) as pool:
                intervals = sorted(pool.map(request, range(3)))
            for previous, current in zip(intervals, intervals[1:]):
                self.assertGreaterEqual(current[0] - previous[0], 0.035)
                self.assertGreaterEqual(current[0], previous[1])

    def test_rpc_errors_are_not_retried(self):
        response = {'jsonrpc':'2.0', 'id':1, 'error':{'message':'rate limited'}}
        with patch('preflight.public_rpc_slot') as slot, \
             patch('preflight.urllib.request.urlopen', return_value=io.BytesIO(json.dumps(response).encode())) as send:
            with self.assertRaisesRegex(ValueError, 'rejected'):
                RPC(PUBLIC).request('eth_chainId', [])
            send.assert_called_once()
            slot.assert_called_once_with(PUBLIC)


class SplitProviderTests(unittest.TestCase):
    def test_finalized_simulation_never_enables_broadcast_or_loads_a_signer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); bundle = root / 'bundle.json'; bundle.write_text('{}')
            meta = {'rpcEnv': 'SOURCE_RPC_URL', 'deployment': 'config/source.json',
                    'sender': '0x' + '1' * 40}
            with patch.dict('os.environ', dict(ENVS, DEPLOYER_PRIVATE_KEY='must-not-be-used'), clear=True), \
                 patch('sys.argv', ['deploy_asset.py', '--bundle', str(bundle), '--asset', 'NVDA',
                                    '--side', 'source', '--finalized-preflight']), \
                 patch('deploy_asset.ROOT', root), \
                 patch('deploy_asset.load', return_value=({'source': meta}, {'evmChain': 4663})), \
                 patch('deploy_asset.deployment_snapshot', return_value=dict(SNAPSHOT)) as snapshot, \
                 patch('deploy_asset.run_logged', return_value='') as run, \
                 patch('deploy_asset.subprocess.run') as signer, patch('builtins.print'):
                main()
                self.assertTrue(snapshot.call_args.kwargs['finalized'])
                run.assert_called_once()
                cmd, env, _ = run.call_args.args
                self.assertNotIn('--broadcast', cmd)
                self.assertNotIn('--private-key', cmd)
                self.assertNotIn('DEPLOYER_PRIVATE_KEY', env)
                signer.assert_not_called()
                self.assertEqual(list(root.rglob('broadcast-attempt.json')), [])

    def test_logs_redact_optional_provider_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'run.log'
            provider = 'https://example.invalid/SECRET'
            with patch('deploy_asset.ROOT', Path(tmp)), patch('deploy_asset.subprocess.run',
                       return_value=Mock(returncode=0, stdout=provider, stderr='')):
                run_logged([], {'SOURCE_FINALIZED_RPC_URL': provider}, path)
            self.assertEqual(path.read_text(), '[REDACTED]')

    def check(self, execution_chain=4663, execution_hash=SNAPSHOT['hash'], missing_block=False):
        checked, execution = Mock(), Mock()
        execution.request.side_effect = [hex(execution_chain),
                                         None if missing_block else {'hash': execution_hash}]
        with patch.dict('os.environ', ENVS, clear=True), \
             patch('deploy_asset.RPC', side_effect=[checked, execution]) as factory, \
             patch('deploy_asset.check_network', return_value=dict(SNAPSHOT)) as inspect:
            result = deployment_snapshot({'evmChain':4663}, {}, 'source', 'SOURCE_RPC_URL', finalized=True)
            self.assertEqual(factory.call_args_list[0].args, (PUBLIC,))
            self.assertEqual(factory.call_args_list[1].args, (ENVS['SOURCE_RPC_URL'],))
            self.assertTrue(inspect.call_args.kwargs['finalized'])
            self.assertEqual(execution.request.call_args.args,
                             ('eth_getBlockByNumber', [SNAPSHOT['number'], False]))
            return result

    def test_execution_provider_must_match_finalized_chain_and_block(self):
        self.assertTrue(self.check()['executionRpcMatchesFinalizedSnapshot'])
        with self.assertRaisesRegex(ValueError, 'wrong chain'): self.check(execution_chain=1)
        with self.assertRaisesRegex(ValueError, 'disagree'): self.check(execution_hash='different')
        with self.assertRaisesRegex(ValueError, 'disagree'): self.check(missing_block=True)

    def test_failed_finalized_check_never_falls_back_to_latest(self):
        with patch.dict('os.environ', ENVS, clear=True), \
             patch('deploy_asset.RPC') as factory, \
             patch('deploy_asset.check_network', side_effect=ValueError('finalized unavailable')):
            with self.assertRaisesRegex(ValueError, 'finalized unavailable'):
                deployment_snapshot({'evmChain':4663}, {}, 'source', 'SOURCE_RPC_URL', finalized=True)
            factory.assert_called_once_with(PUBLIC)

    def test_regular_simulation_uses_execution_provider(self):
        with patch.dict('os.environ', ENVS, clear=True), \
             patch('deploy_asset.RPC') as factory, \
             patch('deploy_asset.check_network', return_value={}) as inspect:
            deployment_snapshot({}, {}, 'source', 'SOURCE_RPC_URL')
            factory.assert_called_once_with(ENVS['SOURCE_RPC_URL'])
            self.assertFalse(inspect.call_args.kwargs['finalized'])

    def test_no_override_preserves_single_provider_finalized_check(self):
        with patch.dict('os.environ', {'SOURCE_RPC_URL': ENVS['SOURCE_RPC_URL']}, clear=True), \
             patch('deploy_asset.RPC') as factory, \
             patch('deploy_asset.check_network', return_value=dict(SNAPSHOT)) as inspect:
            result = deployment_snapshot({}, {}, 'source', 'SOURCE_RPC_URL', finalized=True)
            factory.assert_called_once_with(ENVS['SOURCE_RPC_URL'])
            self.assertTrue(inspect.call_args.kwargs['finalized'])
            self.assertNotIn('executionRpcMatchesFinalizedSnapshot', result)
