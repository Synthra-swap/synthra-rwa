import copy
import unittest
from preflight import validate_pair,word,address,uint

def fixture():
    source={'sourceSide':True,'evmChain':111,'remoteEvmChain':222,'wormholeChain':100,'remoteWormholeChain':200,
    'core':'0x'+'1'*40,'sourceAsset':'0x'+'2'*40,'governanceSafe':'0x'+'3'*40,'guardian':'0x'+'4'*40,'treasury':'0x'+'5'*40,
    'governanceDelaySeconds':172800,'metadataMaxAgeSeconds':86400,'maxTransferRaw':'10','inboundMaxTransferRaw':'10',
    'outboundConsistency':1,'inboundConsistency':1}
    dest=copy.deepcopy(source);dest.update(sourceSide=False,evmChain=222,remoteEvmChain=111,wormholeChain=200,remoteWormholeChain=100)
    return source,dest
class PreflightTests(unittest.TestCase):
    def test_fractional_json_amount_rejected(self):
        s,d=fixture();s['maxTransferRaw']=d['maxTransferRaw']=10.9
        with self.assertRaisesRegex(ValueError,'decimal integer'):validate_pair(s,d)
    def test_mixed_type_same_wormhole_domain_rejected(self):
        s,d=fixture()
        s.update(wormholeChain='100',remoteWormholeChain=100)
        d.update(wormholeChain=100,remoteWormholeChain='100')
        with self.assertRaisesRegex(ValueError,'same Wormhole'):validate_pair(s,d)
    def test_amount_uint256_overflow_rejected(self):
        s,d=fixture();s['maxTransferRaw']=d['maxTransferRaw']=str(2**256)
        with self.assertRaisesRegex(ValueError,'overflow'):validate_pair(s,d)
    def test_integer_parser_rejects_coercions(self):
        for value in (True,False,1.0,-1,'-1','+1','1e18','1.0','0xff',' 1','01',None):
            with self.subTest(value=value),self.assertRaises(ValueError):uint(value)
        self.assertEqual(uint(str(2**256-1)),2**256-1)
        self.assertEqual(uint('0'),0)
    def test_valid_pair(self):validate_pair(*fixture())
    def test_obsolete_total_cap_rejected(self):
        for which in (0,1):
            pair=fixture();pair[which]['capRaw']='1000'
            with self.assertRaisesRegex(ValueError,'obsolete capRaw'):validate_pair(*pair)
    def test_valid_lowered_maximum_with_historical_inbound_ceiling(self):
        s,d=fixture();s['maxTransferRaw']=d['maxTransferRaw']='5'
        validate_pair(s,d)
    def test_invalid_inbound_ceiling(self):
        for value in ('0','9'):
            s,d=fixture();s['inboundMaxTransferRaw']=d['inboundMaxTransferRaw']=value
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,'amount limits'):validate_pair(s,d)
    def test_mismatched_inbound_ceiling(self):
        s,d=fixture();d['inboundMaxTransferRaw']='11'
        with self.assertRaisesRegex(ValueError,'paired limit mismatch'):validate_pair(s,d)
    def test_obsolete_rate_fields_rejected(self):
        for field in ('rateCapacityRaw','refillSeconds'):
            for side in (0,1):
                pair=fixture();pair[side][field]='100'
                with self.subTest(field=field,side=side),self.assertRaisesRegex(ValueError,'obsolete rate-limit'):
                    validate_pair(*pair)
    def test_large_positive_limit_without_capacity_ceiling(self):
        s,d=fixture()
        for c in (s,d):c['maxTransferRaw']=c['inboundMaxTransferRaw']=str(2**256-1)
        validate_pair(s,d)
    def test_wrong_remote_domain(self):
        s,d=fixture();d['remoteEvmChain']=999
        with self.assertRaisesRegex(ValueError,'reciprocal'):validate_pair(s,d)
    def test_zero_address_placeholder(self):
        s,d=fixture();s['treasury']='0x'+'0'*40
        with self.assertRaisesRegex(ValueError,'placeholder'):validate_pair(s,d)
    def test_limits_mismatch(self):
        s,d=fixture();d['maxTransferRaw']='9'
        with self.assertRaisesRegex(ValueError,'limit mismatch'):validate_pair(s,d)
    def test_short_timelock(self):
        s,d=fixture();s['governanceDelaySeconds']=1
        with self.assertRaisesRegex(ValueError,'too short'):validate_pair(s,d)
    def test_finality_not_numerically_ordered(self):
        s,d=fixture();s['outboundConsistency']=200;d['inboundConsistency']=201
        with self.assertRaisesRegex(ValueError,'consistency'):validate_pair(s,d)
    def test_canonical_abi(self):
        self.assertEqual(word('0x'+'0'*63+'1'),1)
        with self.assertRaises(ValueError):word('0x1')
    def test_no_shell_address_injection(self):
        with self.assertRaises(ValueError):address('$(cat .env)')
if __name__=='__main__':unittest.main()
