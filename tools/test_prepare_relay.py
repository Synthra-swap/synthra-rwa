import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import prepare_relay

ENDPOINT = '0x' + '1' * 40
SENDER = '0x' + '2' * 40


class RelayRPC:
    def __init__(self):
        self.methods = []
        self.chain = '0x6f'
        self.simulation_fails = False

    def request(self, method, params):
        self.methods.append(method)
        if method == 'eth_chainId': return self.chain
        if method == 'eth_getCode': return '0x6000'
        if method == 'eth_call':
            if self.simulation_fails: raise ValueError('simulation reverted')
            return '0x'
        if method == 'eth_estimateGas': return '0x186a0'
        raise AssertionError(f'Unexpected RPC method, especially signing or submission: {method}')


class RelayTests(unittest.TestCase):
    def run_preparation(self, rpc, contents='010203'):
        with tempfile.TemporaryDirectory() as tmp:
            vaa = Path(tmp) / 'vaa.hex'; vaa.write_text(contents)
            arguments = ['prepare_relay.py', '--kind', 'deposit', '--vaa', str(vaa),
                         '--endpoint', ENDPOINT, '--sender', SENDER, '--rpc-env', 'AUDIT_TEST_RPC', '--chain-id', '111']
            output = io.StringIO()
            with patch('sys.argv', arguments), patch.dict('os.environ', {'AUDIT_TEST_RPC': 'https://example.invalid'}), \
                 patch('prepare_relay.RPC', return_value=rpc), patch('prepare_relay.cast', return_value='0x1234'), \
                 contextlib.redirect_stdout(output):
                prepare_relay.main()
            return json.loads(output.getvalue())

    def test_preparation_only_simulates_and_never_signs_or_sends(self):
        rpc = RelayRPC(); result = self.run_preparation(rpc)
        self.assertEqual(rpc.methods, ['eth_chainId', 'eth_getCode', 'eth_call', 'eth_estimateGas'])
        self.assertEqual(result['unsignedTransaction']['to'], ENDPOINT)
        self.assertEqual(result['unsignedTransaction']['from'], SENDER)
        self.assertEqual(result['unsignedTransaction']['value'], '0x0')
        self.assertEqual(int(result['unsignedTransaction']['gas'], 16), 120000)

    def test_wrong_chain_stops_before_simulation(self):
        rpc = RelayRPC(); rpc.chain = '0xde'
        with self.assertRaisesRegex(ValueError, 'wrong chain'): self.run_preparation(rpc)
        self.assertEqual(rpc.methods, ['eth_chainId'])

    def test_reverted_simulation_produces_no_transaction(self):
        rpc = RelayRPC(); rpc.simulation_fails = True
        with self.assertRaisesRegex(ValueError, 'simulation reverted'): self.run_preparation(rpc)
        self.assertNotIn('eth_estimateGas', rpc.methods)

    def test_oversized_or_malformed_vaa_rejected_before_network(self):
        for contents in ('ff' * 65537, 'not hex', ''):
            rpc = RelayRPC()
            with self.subTest(size=len(contents)), self.assertRaises(ValueError): self.run_preparation(rpc, contents)
            self.assertEqual(rpc.methods, [])
