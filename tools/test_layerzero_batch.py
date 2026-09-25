import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import layerzero_batch as batch
import layerzero_deploy as deploy
import layerzero_operate as operate


class BatchTests(unittest.TestCase):
    def test_default_prepare_excludes_live_nvda(self):
        with patch('sys.argv', ['batch', 'prepare']), patch.object(operate, 'select_asset') as select, patch.object(deploy, 'prepare') as prepare:
            batch.main()
        self.assertEqual(prepare.call_count, 11)
        self.assertNotIn('NVDA', [c.args[0] for c in select.call_args_list])

    def test_deploy_simulates_by_default(self):
        with TemporaryDirectory() as tmp, patch.object(deploy, 'CONFIG', Path(tmp)), patch('sys.argv', ['batch', 'deploy', '--assets', 'AAPL', '--chain', 'arc']), patch.object(operate, 'select_asset'), patch.object(deploy, 'deploy') as send:
            batch.main()
            send.assert_called_once_with('arc', False)

    def test_reconciled_deployment_is_verified_and_never_redeployed(self):
        record = {'endpoint': 'recorded'}
        with TemporaryDirectory() as tmp, patch.object(deploy, 'CONFIG', Path(tmp)), patch('sys.argv', ['batch', 'deploy', '--assets', 'AAPL', '--chain', 'arc', '--broadcast']), patch.object(operate, 'select_asset'), patch.object(deploy, 'deploy') as send, patch.object(batch, 'deployed_phase', return_value='active'), patch.object(deploy, 'inspect') as inspect:
            (Path(tmp)/'arc.deployed.json').write_text(json.dumps(record))
            batch.main()
            inspect.assert_called_once_with('arc', record, 'active')
            send.assert_not_called()

    def test_ambiguous_deployment_stops_before_next_stock(self):
        with TemporaryDirectory() as tmp, patch.object(deploy, 'CONFIG', Path(tmp)), patch('sys.argv', ['batch', 'deploy', '--assets', 'AAPL', 'MSFT', '--chain', 'arc', '--broadcast']), patch.object(operate, 'select_asset') as select, patch.object(deploy, 'deploy', side_effect=ValueError('Broadcast previously attempted')):
            with self.assertRaisesRegex(ValueError, 'previously attempted'):
                batch.main()
            select.assert_called_once_with('AAPL')

    def test_successful_metadata_receipt_prevents_republication(self):
        with TemporaryDirectory() as tmp, patch.object(deploy, 'STATE', Path(tmp)), patch('sys.argv', ['batch', 'metadata', '--assets', 'AAPL', '--broadcast']), patch.object(operate, 'select_asset'), patch.object(operate, 'packet', return_value={'sourceHash': 'original'}) as packet, patch.object(operate, 'packet_status', return_value='attesting'), patch.object(operate, 'operate') as send:
            receipt = Path(tmp)/'operations/metadata-initial/receipt.json'
            receipt.parent.mkdir(parents=True)
            receipt.write_text(json.dumps({'transactionHash': 'original'}))
            batch.main()
            packet.assert_called_once_with('robinhood', 'original')
            send.assert_not_called()

    def test_complete_skips_attesting_and_consumed_packets_but_submits_ready(self):
        with patch('sys.argv', ['batch', 'complete', '--assets', 'AAPL', 'MSFT', 'META', '--broadcast']), patch.object(operate, 'select_asset'), patch.object(batch, 'metadata_packet', return_value={'sourceHash': 'original'}), patch.object(operate, 'packet_status', side_effect=['attesting', 'complete', 'ready']), patch.object(operate, 'operate') as send:
            batch.main()
            self.assertEqual(send.call_count, 1)
            operation = send.call_args.args[0]
            self.assertEqual((operation.action, operation.chain, operation.tx, operation.id), ('complete', 'robinhood', 'original', 'metadata-complete'))
            self.assertTrue(operation.broadcast)

    def test_export_refuses_metadata_that_has_not_arrived(self):
        with patch('sys.argv', ['batch', 'export-frontend', '--assets', 'AAPL']), patch.object(operate, 'select_asset'), patch.object(batch, 'metadata_packet', return_value={'sourceHash': 'original'}), patch.object(operate, 'packet_status', return_value='ready'), patch.object(operate, 'export_frontend') as export:
            with self.assertRaisesRegex(ValueError, 'Receive metadata'):
                batch.main()
            export.assert_not_called()


if __name__ == '__main__':
    unittest.main()
