"""Public-provider compatibility and response/credential handling for operational RPC tools."""
import io
import json
import unittest
from unittest.mock import patch
from evm_rpc import RPC


class RPCTransportTests(unittest.TestCase):
    def response(self, data):
        return patch('evm_rpc.urllib.request.urlopen', return_value=io.BytesIO(json.dumps(data).encode()))

    def test_explicit_user_agent_and_json_request(self):
        with self.response({'jsonrpc': '2.0', 'id': 1, 'result': '0x1237'}) as send:
            self.assertEqual(RPC('https://example.invalid').request('eth_chainId', []), '0x1237')
        request = send.call_args.args[0]
        self.assertEqual(request.get_header('User-agent'), 'Synthra-ReadOnly-Integration-Review/1.0')
        self.assertEqual(json.loads(request.data)['method'], 'eth_chainId')

    def test_wrong_rpc_response_identity_rejected(self):
        with self.response({'jsonrpc': '2.0', 'id': 2, 'result': '0x1237'}):
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                RPC('https://example.invalid').request('eth_chainId', [])

    def test_transport_error_does_not_expose_rpc_credentials(self):
        with patch('evm_rpc.urllib.request.urlopen', side_effect=OSError('SECRET_IN_URL')):
            with self.assertRaises(ValueError) as raised:
                RPC('https://example.invalid/SECRET_IN_URL').request('eth_chainId', [])
        self.assertNotIn('SECRET', str(raised.exception))

    def test_provider_error_details_are_not_printed(self):
        with self.response({'jsonrpc': '2.0', 'id': 1, 'error': {'message': 'SECRET_IN_URL'}}):
            with self.assertRaisesRegex(ValueError, 'rejected') as raised:
                RPC('https://example.invalid').request('eth_chainId', [])
        self.assertNotIn('SECRET', str(raised.exception))
