#!/usr/bin/env python3
"""Read public chain state and runtime identities; never signs or sends transactions."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
RPC={'robinhood':'https://rpc.mainnet.chain.robinhood.com','arc':'https://rpc.mainnet.arc.io'}

def rpc(url,method,params):
    encoded=[json.dumps(p) if isinstance(p,(dict,list,bool)) else str(p) for p in params]
    run=subprocess.run(['cast','rpc','--rpc-url',url,method,*encoded],capture_output=True,text=True,timeout=45)
    if run.returncode:raise ValueError(run.stderr.strip())
    return json.loads(run.stdout)

def call(url,contract,signature,args=()):
    data=subprocess.run(['cast','calldata',signature,*args],capture_output=True,text=True,check=True).stdout.strip()
    return rpc(url,'eth_call',[{'to':contract,'data':data},'latest'])

def main():
    registry=json.loads((ROOT/'config/layerzero.networks.example.json').read_text())
    result={'schema':1,'scope':'Read-only public latest state. Runtime hashes establish observed identities, not audited implementation equivalence or operator finality behavior.','chains':{}}
    for name,url in RPC.items():
        c=registry[name]
        chain=int(rpc(url,'eth_chainId',[]),16)
        if chain!=c['chainId']:raise SystemExit(f'{name}: wrong chain')
        latest=rpc(url,'eth_getBlockByNumber',['latest',False])
        report={'rpc':url,'chainId':chain,'latest':{k:latest[k] for k in ('number','hash','timestamp')},'contracts':{}}
        try:
            f=rpc(url,'eth_getBlockByNumber',['finalized',False])
            report['finalized']={k:f[k] for k in ('number','hash','timestamp')}
            report['latestMinusFinalizedSeconds']=int(latest['timestamp'],16)-int(f['timestamp'],16)
        except (ValueError,TypeError,KeyError) as e:report['finalizedUnavailable']=str(e)
        eid=int(call(url,c['endpoint'],'eid()(uint32)'),16)
        if eid!=c['localEid']:raise SystemExit(f'{name}: EID mismatch')
        report['endpointEid']=eid
        for role in ('endpoint','sendLibrary','receiveLibrary','dvnA','dvnB'):
            code=rpc(url,'eth_getCode',[c[role],'latest'])
            if code in ('0x','0x0'):raise SystemExit(f'{name}: missing code for {role}')
            digest=subprocess.run(['cast','keccak',code],capture_output=True,text=True,check=True).stdout.strip()
            report['contracts'][role]={'address':c[role],'runtimeKeccak256':digest,'bytes':(len(code)-2)//2}
        result['chains'][name]=report
        print(f'{name}: chain ID, endpoint EID and five runtime identities checked',flush=True)
    result['registrySha256']=hashlib.sha256((ROOT/'config/layerzero.networks.example.json').read_bytes()).hexdigest()
    (ROOT/'audit/layerzero/network-review.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
