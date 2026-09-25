import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import layerzero_deploy as deploy
import layerzero_operate as operate

class DeploymentToolTests(unittest.TestCase):
    def test_failed_completion_preserves_redacted_diagnostics_and_blocks_retry(self):
        key='test-private-key-do-not-log'
        url='https://rpc.example.test/private-api-token'
        rpc=Mock(url=url)
        rpc.request.return_value='0x42'
        configs={chain:{'evmChain':chain_id} for chain,chain_id in [('robinhood',4663),('arc',5042)]}
        records={chain:{'endpoint':deploy.SENDER} for chain in configs}
        packet={'origin':'origin','guid':'guid','message':'message'}
        def args():
            return SimpleNamespace(action='complete',chain='robinhood',tx='source-hash',broadcast=True,id='metadata-complete')
        with TemporaryDirectory() as tmp, patch.object(operate,'STATE',Path(tmp)), patch.object(operate,'inputs',return_value=configs), patch.object(operate,'records',return_value=records), patch.object(operate,'rpc_for',return_value=rpc), patch.object(operate,'packet',return_value=packet), patch.object(operate,'packet_status',return_value='ready'), patch.object(operate,'inspect'), patch.object(operate,'cast',return_value=deploy.SENDER), patch.dict(os.environ,{'DEPLOYER_PRIVATE_KEY':key}), patch.object(operate.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout='',stderr=f'RPC rejected {url}; key={key}')) as run, patch('builtins.print') as printed:
            with self.assertRaisesRegex(ValueError,'Broadcast outcome uncertain'):
                operate.operate(args())
            folder=Path(tmp)/'operations/metadata-complete'
            diagnostics=(folder/'broadcast.stderr.log').read_text()
            self.assertIn('RPC rejected',diagnostics)
            self.assertIn('[REDACTED]',diagnostics)
            self.assertNotIn(key,diagnostics)
            self.assertNotIn(url,diagnostics)
            self.assertNotIn(key,str(printed.call_args_list))
            self.assertNotIn(url,str(printed.call_args_list))
            self.assertTrue((folder/'attempt.json').exists())
            with self.assertRaisesRegex(ValueError,'Operation already attempted'):
                operate.operate(args())
            self.assertEqual(run.call_count,1)

    @unittest.skipUnless(shutil.which('cast'), 'Foundry is required for CLI compatibility testing')
    def test_real_cast_send_preserves_raw_calldata_against_local_rpc(self):
        # Exercise the actual argument parser and transaction builder, without a
        # signer or any mainnet RPC. The local stub records rather than broadcasts.
        sent = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                method = request['method']
                if method == 'eth_sendTransaction':
                    sent.append(request['params'][0]); result = '0x'+'ab'*32
                elif method == 'eth_chainId': result = '0x1237'
                else:
                    self.send_response(400); self.end_headers(); return
                data = json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}).encode()
                self.send_response(200); self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread = Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            for data, value in [('0xb7d2f768'+'00'*12+'11'*20+'00'*12+'22'*20,'0'),('0x12345678','123')]:
                plan = {'to':deploy.SENDER,'wallet':'0x20A32b077906Feb43D5EcaC7EF1425a48E25B4CC',
                        'data':data,'valueRaw':value,'estimatedGas':55000,'chainId':4663}
                cmd = operate.send_command(plan,f'http://127.0.0.1:{server.server_port}')
                cmd += ['--unlocked','--async','--legacy','--gas-price','1','--nonce','0']
                result = subprocess.run(cmd,capture_output=True,text=True,timeout=20,
                                        env={k:os.environ[k] for k in ('PATH','HOME') if k in os.environ})
                self.assertEqual(result.returncode,0,result.stderr)
                tx = sent[-1]
                self.assertEqual(tx.get('input',tx.get('data')),data)
                self.assertEqual(tx['to'].lower(),plan['to'].lower())
                self.assertEqual(tx['from'].lower(),plan['wallet'].lower())
                self.assertEqual(int(tx['value'],16),int(value))
                self.assertEqual(int(tx['gas'],16),66000)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_prepare_is_idempotent_but_never_overwrites_changed_roles(self):
        with TemporaryDirectory() as tmp, patch.object(deploy,'CONFIG',Path(tmp)):
            deploy.prepare();deploy.prepare()
            path=Path(tmp)/'arc.json';c=json.loads(path.read_text());c['governance']=deploy.SENDER;path.write_text(json.dumps(c))
            with self.assertRaisesRegex(ValueError,'Existing configuration differs'):deploy.prepare()
            self.assertEqual(json.loads(path.read_text())['governance'],deploy.SENDER)

    def test_attempt_marker_blocks_duplicate_submission_before_simulation(self):
        with TemporaryDirectory() as tmp, patch.object(deploy,'STATE',Path(tmp)), patch.object(deploy,'CONFIG',Path(tmp)/'config'), patch.object(deploy,'rpc_for'), patch.object(deploy,'run_logged') as run:
            deploy.prepare()
            folder=Path(tmp)/'arc';folder.mkdir();(folder/'attempt.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'previously attempted'):deploy.deploy('arc',True)
            run.assert_not_called()

    def test_reconciliation_rejects_config_change_before_reading_broadcast(self):
        with TemporaryDirectory() as tmp, patch.object(deploy,'STATE',Path(tmp)), patch.object(deploy,'CONFIG',Path(tmp)/'config'):
            deploy.prepare()
            folder=Path(tmp)/'arc';folder.mkdir();(folder/'attempt.json').write_text(json.dumps({'configSha256':'00'*32}))
            with self.assertRaisesRegex(ValueError,'Configuration changed'):deploy.reconcile('arc')

    def test_runtime_verifier_rejects_nonimmutable_bytecode_change(self):
        class RPC:
            def request(self,*args):return '0x6101020399'
        with TemporaryDirectory() as tmp, patch.object(deploy,'ROOT',Path(tmp)):
            folder=Path(tmp)/'out/Test.sol';folder.mkdir(parents=True)
            (folder/'Test.json').write_text(json.dumps({'deployedBytecode':{'object':'0x6001020399','immutableReferences':{'1':[{'start':1,'length':3}]}}}))
            with self.assertRaisesRegex(ValueError,'runtime differs'):deploy.verify_runtime(RPC(),deploy.SENDER,'Test')

    def test_runtime_verifier_masks_only_declared_immutable_spans(self):
        class RPC:
            def request(self,*args):return '0x60aabbcc99'
        with TemporaryDirectory() as tmp, patch.object(deploy,'ROOT',Path(tmp)), patch.object(deploy,'cast',return_value='verified-hash'):
            folder=Path(tmp)/'out/Test.sol';folder.mkdir(parents=True)
            (folder/'Test.json').write_text(json.dumps({'deployedBytecode':{'object':'0x6000000099','immutableReferences':{'1':[{'start':1,'length':3}]}}}))
            self.assertEqual(deploy.verify_runtime(RPC(),deploy.SENDER,'Test'),'verified-hash')

    def test_export_refuses_to_replace_a_route_which_has_saved_claims(self):
        records={'robinhood':{'endpoint':deploy.SENDER,'endpointCodeHash':'0x01','deploymentBlock':1},'arc':{'endpoint':deploy.SENDER,'wrapped':deploy.SENDER,'endpointCodeHash':'0x02','wrappedCodeHash':'0x03','deploymentBlock':2}}
        with TemporaryDirectory() as tmp, patch.object(operate,'records',return_value=records),patch.object(operate,'inspect'),patch.object(deploy,'CONFIG',Path(tmp)/'config'):
            deploy.prepare()
            path=Path(tmp)/'frontend.json';path.write_text(json.dumps({'schema':1,'asset':{'id':'NVDA-LZ-1','vault':'old'}}))
            with self.assertRaisesRegex(ValueError,'Do not replace'):operate.export_frontend(path)
            self.assertEqual(json.loads(path.read_text())['asset']['vault'],'old')

class StockRolloutTests(unittest.TestCase):
    def test_all_stock_configs_preserve_policy_and_bind_correct_issuer(self):
        baseline = self.enterContext(TemporaryDirectory())
        self.enterContext(patch.object(deploy,'CONFIG',Path(baseline)))
        self.enterContext(patch.object(deploy,'ASSET','NVDA'))
        deploy.prepare()
        original = (Path(baseline)/'robinhood.json').read_bytes()
        for symbol, stock in deploy.stock_catalog().items():
            with self.subTest(symbol=symbol), TemporaryDirectory() as tmp, patch.object(deploy,'CONFIG',Path(tmp)), patch.object(deploy,'ASSET',symbol):
                deploy.prepare()
                configs=deploy.inputs()
                for c in configs.values():
                    self.assertEqual(c['sourceAsset'].lower(),stock['token'].lower())
                    self.assertEqual(c['symbol'],'s'+symbol)
                    self.assertEqual(c['maxTransferRaw'],stock['maxTransferRaw'])
                    self.assertEqual(c['sendConfirmations'],15)
                    self.assertEqual(c['receiveConfirmations'],15)
                c=configs['robinhood'];c['sourceAsset']=deploy.SENDER
                (Path(tmp)/'robinhood.json').write_text(json.dumps(c))
                with self.assertRaises(ValueError): deploy.inputs()
        self.assertEqual((Path(baseline)/'robinhood.json').read_bytes(),original)

    def test_asset_paths_are_isolated_and_unknown_symbols_cannot_escape(self):
        try:
            operate.select_asset('AAPL')
            self.assertEqual(operate.CONFIG,deploy.CONFIG)
            self.assertEqual(operate.STATE,deploy.STATE)
            self.assertEqual(deploy.STATE.name,'AAPL')
            with self.assertRaises(ValueError): operate.select_asset('../NVDA')
            self.assertEqual(deploy.STATE.name,'AAPL')
        finally: operate.select_asset('NVDA')

    def test_export_migrates_and_preserves_existing_identities_when_adding_stock(self):
        records={'robinhood':{'endpoint':deploy.SENDER,'endpointCodeHash':'0x01','deploymentBlock':1},'arc':{'endpoint':deploy.SENDER,'wrapped':deploy.SENDER,'endpointCodeHash':'0x02','wrappedCodeHash':'0x03','deploymentBlock':2}}
        original={'id':'NVDA-LZ-1','vault':'original-nvda'}
        with TemporaryDirectory() as tmp, patch.object(operate,'records',return_value=records),patch.object(operate,'inspect'),patch.object(deploy,'ASSET','AAPL'),patch.object(deploy,'CONFIG',Path(tmp)/'config'):
            deploy.prepare()
            path=Path(tmp)/'frontend.json';path.write_text(json.dumps({'schema':1,'asset':original}))
            operate.export_frontend(path);operate.export_frontend(path)
            manifest=json.loads(path.read_text())
            self.assertEqual(manifest['schema'],2)
            self.assertEqual(manifest['assets'][0],original)
            self.assertEqual(len(manifest['assets']),2)
            self.assertEqual(manifest['assets'][1]['id'],'AAPL-LZ-1')

if __name__=='__main__':unittest.main()
