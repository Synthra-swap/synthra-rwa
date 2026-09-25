#!/usr/bin/env python3
"""Compare the local ABI subset with pinned official interfaces using Solidity's ABI encoder.
Downloads are compiled for ABI output only; no downloaded code is executed or deployed.
"""
import hashlib
import json
from pathlib import Path
import posixpath
import re
import subprocess
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
COMMIT='9c741e7f9790639537b1710a203bcdfd73b0b9ac'
BASE=f'https://raw.githubusercontent.com/LayerZero-Labs/LayerZero-v2/{COMMIT}/'
PROTOCOL='packages/layerzero-v2/evm/protocol/contracts/interfaces/'
ULN='packages/layerzero-v2/evm/messagelib/contracts/uln/'

def read_remote(path):
    with urllib.request.urlopen(BASE+path,timeout=45) as response:return response.read().decode()

def abi_type(item):
    t=item['type']
    return '('+','.join(abi_type(c) for c in item['components'])+')'+t[5:] if t.startswith('tuple') else t

def shape(item):
    return (tuple(abi_type(i) for i in item['inputs']),tuple(abi_type(i) for i in item.get('outputs',[])),item['stateMutability'])

def functions(abi):return {a['name']:a for a in abi if a['type']=='function'}

def main():
    sources={}; hashes={}
    def visit(path):
        if path in sources:return
        if path.startswith('@openzeppelin/contracts/'):
            content=(ROOT/'vendor/openzeppelin-contracts/contracts'/path.removeprefix('@openzeppelin/contracts/')).read_text()
        else:content=read_remote(path);hashes[path]=hashlib.sha256(content.encode()).hexdigest()
        sources[path]={'content':content}
        for imported in re.findall(r'import\s+[^;]*?[\"\']([^\"\']+)[\"\']\s*;',content):
            visit(imported if imported.startswith('@') else posixpath.normpath(posixpath.join(posixpath.dirname(path),imported)))
    visit(PROTOCOL+'ILayerZeroEndpointV2.sol');visit(PROTOCOL+'ILayerZeroReceiver.sol')
    base=read_remote(ULN+'UlnBase.sol');receive=read_remote(ULN+'uln302/ReceiveUln302.sol')
    for path,content in [(ULN+'UlnBase.sol',base),(ULN+'uln302/ReceiveUln302.sol',receive)]: hashes[path]=hashlib.sha256(content.encode()).hexdigest()
    struct=re.search(r'struct UlnConfig\s*\{[^}]+\}',base).group()
    declarations=[]
    for name,content in [('getUlnConfig',base),('getAppUlnConfig',base),('verify',receive),('commitVerification',receive)]:
        declaration=re.search(r'function '+name+r'\b[^\{]+',content).group().strip()
        declarations.append(re.sub(r'\bpublic\b','external',declaration)+';')
    sources['ReferenceUln.sol']={'content':'pragma solidity 0.8.28;\n'+struct+'\ninterface IReferenceUln {\n'+'\n'.join(declarations)+'\n}'}
    local=ROOT/'src/layerzero/ILayerZero.sol'
    sources['Local.sol']={'content':local.read_text()}
    request={'language':'Solidity','sources':sources,'settings':{'outputSelection':{'*':{'*':['abi']}}}}
    run=subprocess.run([str(ROOT/'.tools/solc-0.8.28'),'--standard-json'],input=json.dumps(request),capture_output=True,text=True,check=True)
    out=json.loads(run.stdout)
    errors=[e for e in out.get('errors',[]) if e['severity']=='error']
    if errors:raise SystemExit(json.dumps(errors,indent=2))
    contracts=out['contracts']; comparisons=[]
    for local_name,path,reference in [('ILayerZeroEndpoint',PROTOCOL+'ILayerZeroEndpointV2.sol','ILayerZeroEndpointV2'),('ILayerZeroUln','ReferenceUln.sol','IReferenceUln')]:
        expected=functions(contracts[path][reference]['abi'])
        for name,actual in functions(contracts['Local.sol'][local_name]['abi']).items():
            if name not in expected or shape(actual)!=shape(expected[name]):raise SystemExit(f'ABI mismatch: {local_name}.{name}')
            comparisons.append(local_name+'.'+name)
    expected=functions(contracts[PROTOCOL+'ILayerZeroReceiver.sol']['ILayerZeroReceiver']['abi'])
    # Receiver ABI comes from the locally compiled candidate, including inherited public functions.
    artifact=ROOT/'out/LayerZeroSourceVault.sol/LayerZeroSourceVault.json'
    actual=functions(json.loads(artifact.read_text())['abi'])
    for name in ('allowInitializePath','nextNonce','lzReceive'):
        a,b=shape(actual[name]),shape(expected[name])
        if a[:2]!=b[:2] or not (a[2]==b[2] or (a[2]=='pure' and b[2]=='view')):raise SystemExit(f'Receiver ABI mismatch: {name}')
        comparisons.append('Receiver.'+name)
    report={'schema':1,'upstreamCommit':COMMIT,'comparedFunctions':comparisons,'upstreamSha256':hashes,
            'localInterfaceSha256':hashlib.sha256(local.read_bytes()).hexdigest(),
            'notice':'ABI compatibility and pinned-source provenance only, not proof that a live deployment matches this upstream implementation.'}
    (ROOT/'audit/layerzero/abi-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'{len(comparisons)} function ABIs match pinned upstream definitions (including tuple layouts and mutability)')
if __name__=='__main__':main()
