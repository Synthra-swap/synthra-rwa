import copy
import json
from pathlib import Path
import unittest
from check_layerzero_config import validate_pair

ROOT=Path(__file__).resolve().parents[1]
class LayerZeroConfigTests(unittest.TestCase):
    def setUp(self):
        self.networks=json.loads((ROOT/'config/layerzero.networks.example.json').read_text())
        self.pair=[]
        for name,other,is_source in [('robinhood','arc',True),('arc','robinhood',False)]:
            n=self.networks[name]
            c={k:n[k] for k in ['endpoint','sendLibrary','receiveLibrary','dvnA','dvnB','localEid','remoteEid']}
            c.update(sourceSide=is_source,evmChain=n['chainId'],remoteEvmChain=self.networks[other]['chainId'],
                     governance='0x20A32b077906Feb43D5EcaC7EF1425a48E25B4CC',guardian='0x20A32b077906Feb43D5EcaC7EF1425a48E25B4CC',
                     treasury='0x1CAB229e4D75E4DE0EC890bef0295a32BAaa1328',sourceAsset='0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC',
                     maxTransferRaw=str(10**25+123),inboundMaxTransferRaw=str(10**25+123),governanceDelaySeconds=172800,
                     metadataMaxAgeSeconds=2592000,sendConfirmations=15,receiveConfirmations=15,name='Synthra NVIDIA',symbol='sNVDA')
            self.pair.append(c)
    def validate(self): return validate_pair(*self.pair,self.networks)
    def test_valid_pair_is_not_production_approval(self):
        r=self.validate();self.assertTrue(r['configurationCompatible']);self.assertFalse(r['productionApproved'])
    def test_swapped_dvn_order_is_compatible(self):
        c=self.pair[0];c['dvnA'],c['dvnB']=c['dvnB'],c['dvnA'];self.validate()
    def test_wrong_protocol_addresses_domains_and_worker_identities(self):
        original=copy.deepcopy(self.pair)
        for key,value in [('endpoint','0x'+'11'*20),('sendLibrary','0x'+'11'*20),('receiveLibrary','0x'+'11'*20),
                          ('dvnA','0x6788f52439aca6bff597d3eec2dc9a44b8fee842'),('dvnB',self.pair[0]['dvnA']),
                          ('evmChain',5042),('remoteEvmChain',4663),('localEid',72),('remoteEid',71),('sourceSide',False)]:
            with self.subTest(key=key):
                self.pair=copy.deepcopy(original);self.pair[0][key]=value
                with self.assertRaises(ValueError):self.validate()
    def test_both_directions_confirmation_mismatch(self):
        for side in range(2):
            self.pair[side]['sendConfirmations']=14
            with self.assertRaisesRegex(ValueError,'fewer confirmations'):self.validate()
            self.pair[side]['sendConfirmations']=15
    def test_sentinels_narrowing_signed_float_and_boolean_rejected(self):
        for value in [0,-1,2**64-1,2**64,'15.0','1e3',True,15.5]:
            for key in ['sendConfirmations','receiveConfirmations']:
                with self.subTest(key=key,value=value):
                    self.pair[0][key]=value
                    with self.assertRaises(ValueError): self.validate()
                    self.pair[0][key]=15
    def test_incoming_limit_cannot_strand_remote_transfers(self):
        self.pair[1]['maxTransferRaw']=1;self.pair[1]['inboundMaxTransferRaw']=1
        with self.assertRaisesRegex(ValueError,'remote receive ceiling'):self.validate()
    def test_original_token_and_roles_must_match(self):
        for key in ['sourceAsset','governance','guardian']:
            old=self.pair[1][key];self.pair[1][key]='0x'+'11'*20
            with self.assertRaises(ValueError):self.validate()
            self.pair[1][key]=old
    def test_zero_addresses_delay_and_metadata_bounds(self):
        for key,value in [('governance','0x'+'00'*20),('guardian','0x'+'00'*20),('treasury',self.pair[0]['sourceAsset']),
                          ('governanceDelaySeconds',172799),('metadataMaxAgeSeconds',2592001),('name','REPLACE')]:
            old=self.pair[0][key];self.pair[0][key]=value
            with self.assertRaises(ValueError):self.validate()
            self.pair[0][key]=old
    def test_legacy_fields_fail_closed(self):
        for key in ['core','wormholeChain','capRaw','rateCapacityRaw','refillSeconds']:
            self.pair[0][key]=1
            with self.assertRaisesRegex(ValueError,'obsolete'):self.validate()
            self.pair[0].pop(key)
    def test_stock_tokens_all_have_distinct_addresses(self):
        stock=json.loads((ROOT/'config/stock-assets.example.json').read_text())['assets']
        self.assertEqual(len(stock),12);self.assertEqual(len({a['token'].lower() for a in stock}),12)
        for a in stock:
            for c in self.pair:c['sourceAsset']=a['token']
            self.validate()
