"""Failure handling for public evidence collection, not simulated production readiness."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from network_probe import ReadRPC, attempt, inspect_code, probe, SLOTS

TARGET = '0x' + '1' * 40
IMPL = '0x' + '2' * 40
PIN = '0x123'


class NetworkProbeTests(unittest.TestCase):
    def test_rpc_cannot_submit_or_sign(self):
        with patch('network_probe.urllib.request.urlopen') as send:
            for method in ('eth_sendTransaction', 'eth_sendRawTransaction', 'eth_sign', 'debug_traceCall'):
                with self.subTest(method=method), self.assertRaisesRegex(ValueError, 'read-only'):
                    ReadRPC('https://example.invalid').request(method, [])
            send.assert_not_called()

    def rpc_response(self, data):
        rpc = ReadRPC('https://example.invalid')
        response = io.BytesIO(json.dumps(data).encode())
        with patch('network_probe.urllib.request.urlopen', return_value=response):
            return rpc.request('eth_chainId', [])

    def test_mismatched_response_id_rejected(self):
        with self.assertRaisesRegex(ValueError, 'mismatched'):
            self.rpc_response({'jsonrpc': '2.0', 'id': 2, 'result': '0x1237'})

    def test_rpc_error_never_becomes_a_result(self):
        with self.assertRaisesRegex(ValueError, 'RPC rejected'):
            self.rpc_response({'jsonrpc': '2.0', 'id': 1, 'error': {'code': -32000, 'message': 'pruned'}})

    def test_explicit_result(self):
        self.assertEqual(self.rpc_response({'jsonrpc': '2.0', 'id': 1, 'result': '0x1237'}), '0x1237')

    def test_failed_optional_read_remains_failed(self):
        result = attempt(lambda: (_ for _ in ()).throw(ValueError('unsupported selector')))
        self.assertEqual(result, {'ok': False, 'error': 'unsupported selector'})

    def test_empty_runtime_rejected(self):
        rpc = Mock(); rpc.request.return_value = '0x'
        with self.assertRaisesRegex(ValueError, 'no runtime'):
            inspect_code(rpc, TARGET, PIN)

    def beacon_rpc(self, implementation):
        rpc = Mock()
        def request(method, params):
            self.assertEqual(params[-1], PIN)
            if method == 'eth_getCode': return '0x6000'
            if method == 'eth_getStorageAt':
                return '0x' + (IMPL[2:].zfill(64) if params[1] == SLOTS['beacon'] else '0' * 64)
            self.fail(method)
        rpc.request.side_effect = request
        rpc.call.return_value = implementation
        return rpc

    def test_beacon_is_resolved_to_implementation(self):
        rpc = self.beacon_rpc('0x' + TARGET[2:].zfill(64))
        with patch('network_probe.cast', return_value='hash'):
            result = inspect_code(rpc, TARGET, PIN)
        self.assertEqual(result['beaconImplementation']['address'], TARGET)
        rpc.call.assert_called_once_with(IMPL, 'implementation()', PIN)

    def test_zero_beacon_implementation_rejected(self):
        with patch('network_probe.cast', return_value='hash'), self.assertRaisesRegex(ValueError, 'invalid beacon'):
            inspect_code(self.beacon_rpc('0x' + '0' * 64), TARGET, PIN)

    def test_wrong_chain_stops_before_contract_reads_and_saves_failure(self):
        rpc = Mock(); rpc.request.return_value = '0x1'; rpc.trace = []
        with tempfile.TemporaryDirectory() as temp, patch('network_probe.OUTPUT', Path(temp)), \
             patch('network_probe.ReadRPC', return_value=rpc):
            result = probe('test', {'rpc': 'https://example.invalid', 'evmChain': 4663}, [])
            self.assertIn('unexpected EVM chain', result['error'])
            self.assertNotIn('snapshotRechecked', result)
            self.assertNotIn('compatibilityReadsPassed', result)
            self.assertTrue((Path(temp) / 'test-finalized-rpc.json').exists())
        rpc.request.assert_called_once_with('eth_chainId', [])
