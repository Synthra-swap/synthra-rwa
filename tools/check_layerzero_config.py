#!/usr/bin/env python3
"""Validate a proposed Robinhood/Arc pair offline. Does not establish on-chain state or finality."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
UINT256 = 2**256 - 1
UINT64 = 2**64 - 1
ADDRESS = re.compile(r'^0x[0-9a-fA-F]{40}$')

def integer(c, field, maximum=UINT256):
    v = c.get(field)
    if isinstance(v,bool) or not isinstance(v,(int,str)) or not re.fullmatch(r'[0-9]+',str(v)):
        raise ValueError(f'{field}: expected unsigned decimal integer')
    n=int(v)
    if not 0 < n <= maximum: raise ValueError(f'{field}: outside permitted range')
    return n

def address(c, field):
    v=c.get(field)
    if not isinstance(v,str) or not ADDRESS.fullmatch(v) or int(v,16)==0:
        raise ValueError(f'{field}: nonzero EVM address required')
    return v.lower()

def validate_pair(source,destination,networks):
    """Identity registry is a reviewed input, not automatically trusted online metadata."""
    for c,name,other,is_source in ((source,'robinhood','arc',True),(destination,'arc','robinhood',False)):
        n=networks[name]; remote=networks[other]
        if c.get('sourceSide') is not is_source: raise ValueError('sourceSide: wrong side')
        if any(f in c for f in ('core','wormholeChain','remoteWormholeChain','capRaw','rateCapacityRaw','refillSeconds')):
            raise ValueError('obsolete configuration fields are not LayerZero configuration')
        for field,expected in (('evmChain',n['chainId']),('remoteEvmChain',remote['chainId']),
                               ('localEid',n['localEid']),('remoteEid',remote['localEid'])):
            if integer(c,field)!=int(expected): raise ValueError(f'{field}: wrong chain identity')
        for field in ('endpoint','sendLibrary','receiveLibrary'):
            if address(c,field)!=address(n,field): raise ValueError(f'{field}: unreviewed protocol address')
        supplied={address(c,'dvnA'),address(c,'dvnB')}
        expected={address(n,'dvnA'),address(n,'dvnB')}
        if len(supplied)!=2 or supplied!=expected: raise ValueError('DVNs: expected both reviewed operators on this chain')
        for field in ('governance','guardian','treasury','sourceAsset'): address(c,field)
        if address(c,'treasury')==address(c,'sourceAsset'): raise ValueError('treasury cannot be original token')
        if integer(c,'governanceDelaySeconds')<172800: raise ValueError('governance delay below 48 hours')
        for field in ('sendConfirmations','receiveConfirmations'): integer(c,field,UINT64-1)
        if integer(c,'maxTransferRaw')!=integer(c,'inboundMaxTransferRaw'):
            raise ValueError('initial incoming ceiling differs from outgoing maximum')
        integer(c,'metadataMaxAgeSeconds',2592000)
        for field in ('name','symbol'):
            if not isinstance(c.get(field),str) or not c[field].strip() or 'REPLACE' in c[field]:
                raise ValueError(f'{field}: replace placeholder')
    if address(source,'sourceAsset')!=address(destination,'sourceAsset'): raise ValueError('original token mismatch')
    if address(source,'governance')!=address(destination,'governance'): raise ValueError('paired governance mismatch')
    if address(source,'guardian')!=address(destination,'guardian'): raise ValueError('paired guardian mismatch')
    for sender,receiver in ((source,destination),(destination,source)):
        if integer(sender,'sendConfirmations')<integer(receiver,'receiveConfirmations'):
            raise ValueError('sender requests fewer confirmations than receiver requires')
        if integer(sender,'maxTransferRaw')>integer(receiver,'inboundMaxTransferRaw'):
            raise ValueError('outgoing maximum exceeds remote receive ceiling')
    return {'configurationCompatible':True,'productionApproved':False,
            'remaining':['Verify live bytecode, ownership, peers, effective ULN settings and issuer state.',
                         'Verify end-to-end packet verification and manual completion with both selected DVNs.',
                         'Obtain external audit and review the deployment/migration procedure.']}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',required=True,type=Path);p.add_argument('--destination',required=True,type=Path)
    p.add_argument('--networks',type=Path,default=ROOT/'config/layerzero.networks.example.json')
    a=p.parse_args()
    try: result=validate_pair(json.loads(a.source.read_text()),json.loads(a.destination.read_text()),json.loads(a.networks.read_text()))
    except (ValueError,KeyError,OSError) as e: raise SystemExit(f'LayerZero configuration rejected: {e}') from e
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
