#!/usr/bin/env python3
"""Read-only paired-deployment validation at finalized, rechecked block snapshots. No signing."""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ZERO = '0x' + '0' * 40

def require(condition, message):
    if not condition:
        raise ValueError(message)

def address(value):
    require(isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value), 'invalid address')
    require(value.lower() != ZERO, 'zero address placeholder')
    return value.lower()

def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip()

def word(value):
    require(isinstance(value,str) and re.fullmatch(r'0x[0-9a-fA-F]{64}',value), 'noncanonical ABI word')
    return int(value,16)

def uint(value, bits=256):
    """Reject JSON floats/bools and non-decimal strings rather than coercing them."""
    require(type(value) is int or (isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]*', value)),
            'expected unsigned decimal integer')
    result = int(value)
    require(0 <= result < 2**bits, f'uint{bits} overflow')
    return result

def validate_pair(source, destination):
    require(source['sourceSide'] is True and destination['sourceSide'] is False, 'sourceSide mismatch')
    for c in (source,destination):
        require('capRaw' not in c, 'obsolete capRaw field; total caps were removed')
        require('rateCapacityRaw' not in c and 'refillSeconds' not in c, 'obsolete rate-limit fields')
        for name in ('evmChain','remoteEvmChain','governanceDelaySeconds','metadataMaxAgeSeconds',
                     'maxTransferRaw','inboundMaxTransferRaw'):
            uint(c[name])
        for name in ('wormholeChain','remoteWormholeChain'):
            uint(c[name], 16)
        for name in ('outboundConsistency','inboundConsistency'):
            uint(c[name], 8)
        for name in ('core','sourceAsset','governanceSafe','guardian','treasury'):
            address(c[name])
        require(c['governanceSafe'].lower()!=c['guardian'].lower(),'guardian must differ from governance')
        require(0<int(c['wormholeChain'])<=65535 and 0<int(c['remoteWormholeChain'])<=65535,'invalid Wormhole domain')
        require(int(c['wormholeChain']) != int(c['remoteWormholeChain']), 'same Wormhole domain')
        require(0<int(c['evmChain'])!=int(c['remoteEvmChain'])>0,'invalid EVM domains')
        require(0<int(c['maxTransferRaw'])<=int(c['inboundMaxTransferRaw']),'invalid amount limits')
        require(int(c['governanceDelaySeconds'])>=172800,'governance delay too short')
        require(0<int(c['metadataMaxAgeSeconds'])<=7*86400,'invalid metadata age')
        for k in ('outboundConsistency','inboundConsistency'):
            require(0<=int(c[k])<=255,'invalid consistency enum')
    for a,b in ((source,destination),(destination,source)):
        require(int(a['remoteEvmChain'])==int(b['evmChain']),'EVM reciprocal mismatch')
        require(int(a['remoteWormholeChain'])==int(b['wormholeChain']),'Wormhole reciprocal mismatch')
        require(int(a['outboundConsistency'])==int(b['inboundConsistency']),'consistency mismatch')
    require(int(source['wormholeChain'])!=int(destination['wormholeChain']),'same Wormhole domain')
    require(source['sourceAsset'].lower()==destination['sourceAsset'].lower(),'origin asset mismatch')
    for k in ('maxTransferRaw','inboundMaxTransferRaw'):
        require(int(source[k])==int(destination[k]),f'paired limit mismatch: {k}')

class RPC:
    def __init__(self,url):
        require(url.startswith(('https://','http://')),'invalid RPC protocol')
        self.url=url
    def request(self,method,params):
        payload=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode()
        try:
            req=urllib.request.Request(self.url,payload,{'Content-Type':'application/json',
                'User-Agent':'Synthra-ReadOnly-Integration-Review/1.0'})
            with urllib.request.urlopen(req,timeout=30) as result:
                data=json.load(result)
        except Exception as error:
            raise ValueError('RPC transport failed (URL omitted)') from error
        require(data.get('jsonrpc') == '2.0' and data.get('id') == 1, 'RPC response identity mismatch')
        require('error' not in data, f'RPC {method} rejected; inspect provider separately')
        require('result' in data,'RPC missing result')
        return data['result']
    def call(self,target,signature,block,*args):
        data=cast('calldata',signature,*[str(a) for a in args])
        return word(self.request('eth_call',[{'to':target,'data':data},block]))

def inspect(c,meta,remote_meta,phase):
    rpc=RPC(os.environ[meta['rpcEnv']]);endpoint=address(meta['endpoint']);governor=address(meta['timelock'])
    require(int(rpc.request('eth_chainId',[]),16)==int(c['evmChain']),'RPC on wrong chain')
    block=rpc.request('eth_getBlockByNumber',['finalized',False]);require(block is not None,'finalized block unavailable')
    pin=block['number']
    def call(target,signature,*args): return rpc.call(target,signature,pin,*args)
    def eq(signature,expected): require(call(endpoint,signature)==int(expected),f'endpoint mismatch: {signature}')
    def verify_code(target, expected_hash):
        require(re.fullmatch(r'0x[0-9a-fA-F]{64}',expected_hash),'missing approved code hash')
        code=rpc.request('eth_getCode',[target,pin]);require(code!='0x','missing code')
        require(cast('keccak',code).lower()==expected_hash.lower(),'approved runtime hash mismatch')
    for target,expected_hash in ((endpoint,meta['endpointCodeHash']),(c['core'],meta['coreCodeHash']),
                                 (governor,meta['timelockCodeHash'])):
        verify_code(target, expected_hash)
    eq('owner()',int(governor,16));eq('peer()',int(address(remote_meta['endpoint']),16))
    eq('pendingOwner()',0)
    eq('wormhole()',int(c['core'],16));eq('guardian()',int(c['guardian'],16))
    eq('deploymentChainId()',c['evmChain']);eq('remoteEvmChain()',c['remoteEvmChain'])
    eq('localWormholeChain()',c['wormholeChain']);eq('remoteWormholeChain()',c['remoteWormholeChain'])
    eq('outboundConsistency()',c['outboundConsistency']);eq('inboundConsistency()',c['inboundConsistency'])
    for getter,key in [('maxTransfer()','maxTransferRaw'),('inboundMaxTransfer()','inboundMaxTransferRaw')]: eq(getter,c[key])
    paused = call(endpoint,'pausedLanes()')
    if phase == 'maintenance':
        require(paused in (1,3), 'maintenance requires outbound paused')
    else:
        require(paused == (3 if phase == 'prepared' else 0), 'endpoint mismatch: pausedLanes()')
    require(call(c['core'],'chainId()')==int(c['wormholeChain']),'Core Wormhole domain mismatch')
    require(call(c['core'],'evmChainId()')==int(c['evmChain']),'Core EVM domain mismatch')
    require(call(governor,'getMinDelay()')>=int(c['governanceDelaySeconds']),'timelock delay mismatch')
    for role in ('PROPOSER_ROLE','EXECUTOR_ROLE','CANCELLER_ROLE'):
        require(call(governor,'hasRole(bytes32,address)',cast('keccak',role),c['governanceSafe'])==1,'governance role missing')
        require(call(governor,'hasRole(bytes32,address)',cast('keccak',role),ZERO)==0,'open governance role')
    require(call(governor,'hasRole(bytes32,address)','0x'+'0'*64,c['governanceSafe'])==0,'Safe has direct admin role')
    require(call(governor,'hasRole(bytes32,address)','0x'+'0'*64,governor)==1,'timelock self-admin missing')
    require(call(governor,'hasRole(bytes32,address)','0x'+'0'*64,ZERO)==0,'zero address has admin role')
    for target in (c['governanceSafe'],c['guardian']):
        require(rpc.request('eth_getCode',[target,pin])!='0x','governance/guardian contract missing')
    state={'block':pin,'blockHash':block['hash'],'timestamp':int(block['timestamp'],16),'endpoint':endpoint,'pausedLanes':paused}
    state['remoteToken']='0x'+format(call(endpoint,'remoteToken()'),'040x')
    if c['sourceSide']:
        verify_code(c['sourceAsset'],meta['assetCodeHash'])
        eq('asset()',int(c['sourceAsset'],16));eq('feeRecipient()',int(c['treasury'],16));eq('FEE_BPS()',50)
        require(call(c['sourceAsset'],'decimals()')==18,'asset decimals mismatch')
        state['lockedRaw']=str(call(endpoint,'locked()'));state['balanceRaw']=str(call(c['sourceAsset'],'balanceOf(address)',endpoint))
        require(int(state['balanceRaw'])>=int(state['lockedRaw']),'local escrow backing deficit')
        require(call(c['sourceAsset'],'uiMultiplier()')>0,'invalid original multiplier')
        call(c['sourceAsset'],'newUIMultiplier()');call(c['sourceAsset'],'effectiveAt()')
    else:
        eq('originToken()',int(c['sourceAsset'],16))
        wrapped='0x'+format(call(endpoint,'wrappedAsset()'),'040x');state['wrapped']=wrapped
        verify_code(wrapped,meta['wrappedCodeHash'])
        eq('remoteToken()',int(c['sourceAsset'],16))
        require(call(wrapped,'bridge()')==int(endpoint,16),'wrapped bridge mismatch')
        require(call(wrapped,'originToken()')==int(c['sourceAsset'],16),'wrapped origin mismatch')
        require(call(wrapped,'originWormholeChain()')==int(c['remoteWormholeChain']),'wrapped origin domain mismatch')
        require(call(wrapped,'decimals()')==18,'wrapped decimals mismatch')
        require(call(wrapped,'metadataMaxAge()')==int(c['metadataMaxAgeSeconds']),'metadata age mismatch')
        state['supplyRaw']=str(call(wrapped,'totalSupply()'));state['metadataFresh']=bool(call(wrapped,'metadataFresh()'))
        if phase == 'active':
            require(state['metadataFresh'], 'stale wrapped metadata')
    check=rpc.request('eth_getBlockByNumber',[pin,False]);require(check is not None and check['hash']==block['hash'],'pinned block changed')
    return state

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--pair',required=True);parser.add_argument('--phase',choices=['prepared','maintenance','active'],default='prepared');parser.add_argument('--config-only',action='store_true');args=parser.parse_args()
    pair=json.loads(Path(args.pair).read_text());source=json.loads(Path(pair['source']['deployment']).read_text());destination=json.loads(Path(pair['destination']['deployment']).read_text())
    validate_pair(source,destination)
    if args.config_only:
        print(json.dumps({'configValid':True,'networkChecked':False}));return
    results={name:inspect(c,pair[name],pair[other],args.phase) for name,other,c in [('source','destination',source),('destination','source',destination)]}
    require(results['source']['remoteToken']==results['destination']['wrapped'],'source remote token mismatch')
    results['notice']='Separate finalized snapshots, not an atomic proof of cross-chain solvency. Core proxy implementation/governance and emitter provenance require separate review.'
    print(json.dumps(results,indent=2))
if __name__=='__main__':
    try: main()
    except (ValueError,KeyError,OSError,subprocess.CalledProcessError) as error:
        print(f'Preflight failed: {error}',file=sys.stderr);sys.exit(1)
