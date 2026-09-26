"""Shared RPC pacing and credential-safe deployment logs."""
from concurrent.futures import ThreadPoolExecutor
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from deployment_helpers import run_logged
from evm_rpc import RPC
from rpc_policy import finalized_url, is_nodeflare_public, public_rpc_slot


PUBLIC = 'https://rpc.nodeflare.app/robinhood/public'
ENVS = {'SOURCE_RPC_URL': 'https://execution.invalid', 'SOURCE_FINALIZED_RPC_URL': PUBLIC}


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
        with patch('evm_rpc.public_rpc_slot') as slot, \
             patch('evm_rpc.urllib.request.urlopen', return_value=io.BytesIO(json.dumps(response).encode())) as send:
            with self.assertRaisesRegex(ValueError, 'rejected'):
                RPC(PUBLIC).request('eth_chainId', [])
            send.assert_called_once()
            slot.assert_called_once_with(PUBLIC)


class DeploymentLogTests(unittest.TestCase):
    def test_logs_redact_optional_provider_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'run.log'
            provider = 'https://example.invalid/SECRET'
            with patch('deployment_helpers.ROOT', Path(tmp)), patch('deployment_helpers.subprocess.run',
                       return_value=Mock(returncode=0, stdout=provider, stderr='')):
                run_logged([], {'SOURCE_FINALIZED_RPC_URL': provider}, path)
            self.assertEqual(path.read_text(), '[REDACTED]')
