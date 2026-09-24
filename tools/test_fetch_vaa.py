"""Adversarial receipt/VAA checks for the manual live-pilot completion workflow."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from fetch_vaa import TOPIC, checked_vaa, check_payload, main, publication, write_vaa
from preflight import cast
from test_preflight import fixture

EMITTER = '0x' + '6' * 40
TARGET = '0x' + '7' * 40
HASH = '0x' + 'a' * 64
TX = '0x' + 'b' * 64
BLOCK = {'number': '0x20', 'hash': HASH, 'timestamp': '0x1234'}


def example():
    source, destination = fixture()
    words = [int(cast('keccak', 'synthra.rwa.bridge.v1'), 16), 1, 3, source['evmChain'],
             destination['evmChain'], destination['wormholeChain'], int(TARGET, 16),
             int(source['sourceAsset'], 16), 123, 10**18, 10**18, 0]
    payload = b''.join(v.to_bytes(32, 'big') for v in words)
    event = b''.join(v.to_bytes(32, 'big') for v in (9, 0, 128, source['outboundConsistency'], len(payload))) + payload
    receipt = {'status': '0x1', 'blockNumber': '0x20', 'blockHash': HASH, 'transactionHash': TX,
               'logs': [{'address': source['core'], 'blockHash': HASH, 'removed': False,
                         'topics': [TOPIC, '0x' + int(EMITTER, 16).to_bytes(32, 'big').hex()],
                         'data': '0x' + event.hex()}]}
    return source, destination, payload, receipt


class FetchVAATests(unittest.TestCase):
    def test_reconstructs_body_and_validates_route(self):
        source, destination, payload, receipt = example()
        sequence, body, actual = publication(receipt, BLOCK, source['core'], EMITTER, source['wormholeChain'])
        self.assertEqual(sequence, 9)
        self.assertEqual(actual, payload)
        self.assertEqual(body[:4], bytes.fromhex('00001234'))
        check_payload(payload, 'metadata', source, destination, TARGET)
        encoded = b'\x01' + (7).to_bytes(4, 'big') + b'\x01' + b'\x00' * 66 + body
        self.assertEqual(checked_vaa(encoded, body), '0x' + encoded.hex())

    def test_failed_removed_wrong_emitter_duplicate_or_reorged_publication_rejected(self):
        source, _, _, original = example()
        cases = []
        r = copy.deepcopy(original); r['status'] = '0x0'; cases.append(r)
        r = copy.deepcopy(original); r['blockHash'] = 'different'; cases.append(r)
        r = copy.deepcopy(original); r['logs'][0]['removed'] = True; cases.append(r)
        r = copy.deepcopy(original); r['logs'][0]['topics'][1] = '0x' + '0' * 64; cases.append(r)
        r = copy.deepcopy(original); r['logs'] *= 2; cases.append(r)
        for receipt in cases:
            with self.assertRaises(ValueError):
                publication(receipt, BLOCK, source['core'], EMITTER, source['wormholeChain'])

    def test_malformed_dynamic_event_payload_rejected(self):
        source, _, _, original = example()
        for changed_word, value in [(0, 2**64), (1, 2**32), (2, 160), (3, 256), (4, 99999)]:
            receipt = copy.deepcopy(original)
            data = bytearray.fromhex(receipt['logs'][0]['data'][2:])
            data[changed_word*32:(changed_word+1)*32] = value.to_bytes(32, 'big')
            receipt['logs'][0]['data'] = '0x' + data.hex()
            with self.assertRaises(ValueError):
                publication(receipt, BLOCK, source['core'], EMITTER, source['wormholeChain'])

    def test_wrong_kind_or_route_rejected(self):
        source, destination, payload, _ = example()
        with self.assertRaises(ValueError): check_payload(payload, 'deposit', source, destination, TARGET)
        for word in range(8):
            changed = bytearray(payload); changed[word*32+31] ^= 1
            with self.assertRaises(ValueError): check_payload(bytes(changed), 'metadata', source, destination, TARGET)

    def test_vaa_cannot_change_body_or_truncate_signatures(self):
        source, _, _, receipt = example()
        _, body, _ = publication(receipt, BLOCK, source['core'], EMITTER, source['wormholeChain'])
        good = b'\x01' + b'\x00' * 4 + b'\x01' + b'\x00' * 66 + body
        for candidate in (b'', good[:5], good[:-1], good[:6] + body, b'\x02' + good[1:],
                          good[:-1] + bytes([good[-1] ^ 1])):
            with self.assertRaises(ValueError): checked_vaa(candidate, body)

    def test_existing_vaa_is_never_overwritten_with_different_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'message.hex'
            write_vaa(path, '0x1234'); write_vaa(path, '0x1234')
            with self.assertRaisesRegex(ValueError, 'different VAA'): write_vaa(path, '0x5678')
            self.assertEqual(path.read_text().strip(), '0x1234')

    def test_core_signature_verification_and_finality_gate_before_file_output(self):
        source, destination, _, receipt = example()
        _, body, _ = publication(receipt, BLOCK, source['core'], EMITTER, source['wormholeChain'])
        encoded = b'\x01' + b'\x00' * 4 + b'\x01' + b'\x00' * 66 + body
        for finalized, valid in ((True, True), (True, False), (False, True)):
            with self.subTest(finalized=finalized, valid=valid), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                pair = {}
                for side, config, endpoint in [('source', source, EMITTER), ('destination', destination, TARGET)]:
                    path = root / (side + '.json'); path.write_text(json.dumps(config))
                    pair[side] = {'deployment': str(path), 'rpcEnv': side.upper() + '_RPC_URL', 'endpoint': endpoint}
                pair_path = root / 'pair.json'; pair_path.write_text(json.dumps(pair))
                rpc, verifier = Mock(), Mock()
                rpc.request.side_effect = [hex(source['evmChain']), receipt,
                    dict(BLOCK, number='0x21' if finalized else '0x19'), BLOCK, BLOCK]
                verifier.request.side_effect = [hex(destination['evmChain']),
                    '0x' + (96).to_bytes(32, 'big').hex() + int(valid).to_bytes(32, 'big').hex() + '00' * 32]
                with patch.dict('os.environ', {'SOURCE_RPC_URL': 'https://source.invalid',
                                              'DESTINATION_RPC_URL': 'https://destination.invalid'}), \
                     patch('sys.argv', ['fetch_vaa.py', '--pair', str(pair_path), '--kind', 'metadata',
                                        '--tx', TX, '--output', str(root / 'vaa.hex')]), \
                     patch('fetch_vaa.RPC', side_effect=[rpc, verifier]), \
                     patch('fetch_vaa.retrieve', return_value=encoded) as get, \
                     patch('fetch_vaa.write_vaa') as save, patch('builtins.print'):
                    if finalized and valid:
                        main(); save.assert_called_once()
                    else:
                        with self.assertRaises(ValueError): main()
                        save.assert_not_called()
                    if not finalized: get.assert_not_called()
