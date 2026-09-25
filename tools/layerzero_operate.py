#!/usr/bin/env python3
"""Operate a reviewed LayerZero stock pair. Default: simulate an unsigned action.

Governance actions use cast --browser with the configured hardware wallet.
Metadata / approve / deposit / redeem / complete use DEPLOYER_PRIVATE_KEY locally.
Every broadcast has a permanent attempt record. Never automatically retry a send.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import layerzero_deploy as deployment
from layerzero_deploy import CONFIG, ROOT, SENDER, STATE, inputs, inspect, rpc_for, write
from preflight import address, cast, require, ZERO

ZERO_HASH='0x'+'00'*32

def select_asset(symbol):
    global CONFIG, STATE
    deployment.select_asset(symbol)
    CONFIG, STATE = deployment.CONFIG, deployment.STATE

def records():
    return {n:json.loads((CONFIG/(n+'.deployed.json')).read_text()) for n in ('robinhood','arc')}

def raw_call(rpc, target, signature, *args):
    return rpc.request('eth_call',[{'to':target,'data':cast('calldata',signature,*map(str,args))},'latest'])

def word_address(value): return '0x'+format(value,'040x')

def send_command(plan, rpc_url):
    # Cast accepts pre-encoded calldata as its positional SIG argument.
    # There is no `cast send --data` option in the supported Foundry CLI.
    return ['cast','send',plan['to'],plan['data'],'--value',plan['valueRaw'],
            '--gas-limit',str(plan['estimatedGas']*120//100),'--rpc-url',rpc_url,
            '--chain',str(plan['chainId']),'--from',plan['wallet'],'--json']

def packet(chain, tx_hash):
    cs=inputs(); rs=records(); other='arc' if chain=='robinhood' else 'robinhood'
    rpc=rpc_for(chain); c=cs[chain]; r=rs[chain]; dest=rs[other]
    receipt=rpc.request('eth_getTransactionReceipt',[tx_hash])
    require(receipt and int(receipt['status'],16)==1,'Source transaction is not successfully mined')
    require(rpc.request('eth_getBlockByNumber',[receipt['blockNumber'],False])['hash']==receipt['blockHash'],'Source receipt reorganized')
    topic=cast('keccak','MessageSent(bytes32,uint64,bytes)')
    logs=[l for l in receipt['logs'] if address(l['address'])==address(r['endpoint']) and l['topics'][0]==topic]
    require(len(logs)==1,'Expected exactly one message from the configured bridge')
    log=logs[0];require(len(log['topics'])==3 and not log.get('removed',False),'Invalid message log')
    nonce=int(log['topics'][2],16);data=log['data'][2:]
    require(int(data[:64],16)==32,'Noncanonical bytes offset')
    length=int(data[64:128],16);message='0x'+data[128:128+length*2]
    require(length in (320,384),'Unexpected message size')
    require(cast('abi-encode','f(bytes)',message).lower()==log['data'].lower(),'Noncanonical publication')
    sender='0x'+address(r['endpoint'])[2:].zfill(64); receiver=address(dest['endpoint'])[2:].zfill(64)
    path=f'{nonce:016x}{c["localEid"]:08x}'+sender[2:]+f'{c["remoteEid"]:08x}'+receiver
    guid=cast('keccak','0x'+path);require(guid==log['topics'][1],'GUID mismatch')
    return {'sourceChain':chain,'destinationChain':other,'sourceHash':tx_hash,'nonce':nonce,'origin':f'({c["localEid"]},{sender},{nonce})','guid':guid,'header':'0x01'+path,'message':message,'payloadHash':cast('keccak',guid+message[2:]),'sourceBlock':receipt['blockNumber']}

def packet_status(p):
    chain=p['destinationChain']; rpc=rpc_for(chain); c=inputs()[chain]; r=records()[chain]; source=records()[p['sourceChain']]
    if rpc.call(r['endpoint'],'consumedMessages(bytes32)','latest',p['guid']): return 'complete'
    saved=raw_call(rpc,r['endpoint'],'checkpointedPayloads(bytes32)',p['guid'])
    require(saved in (ZERO_HASH,p['payloadHash']),'Checkpoint mismatch')
    if saved==p['payloadHash']: return 'ready'
    sender='0x'+source['endpoint'][2:].zfill(64)
    stored=raw_call(rpc,c['endpoint'],'inboundPayloadHash(address,uint32,bytes32,uint64)',r['endpoint'],c['remoteEid'],sender,p['nonce'])
    if stored==p['payloadHash']: return 'ready'
    require(stored==ZERO_HASH,'Unexpected protocol payload hash')
    for name in ('dvnA','dvnB'):
        vote=raw_call(rpc,c['receiveLibrary'],'hashLookup(bytes32,bytes32,address)',cast('keccak',p['header']),p['payloadHash'],c[name])
        if int(vote[2:66],16)!=1 or int(vote[66:130],16)<c['receiveConfirmations']: return 'attesting'
    return 'ready'

def export_frontend(path):
    rs=records(); cs=inputs()
    for chain in rs: inspect(chain,rs[chain],'active')
    stock=deployment.stock_identity()
    asset={'id':stock['symbol']+'-LZ-1','name':stock['name'],'symbol':stock['symbol'],'wrappedSymbol':cs['arc']['symbol'],'decimals':18,'sourceToken':cs['robinhood']['sourceAsset'],'protocol':'layerzero','configured':True,
           'vault':rs['robinhood']['endpoint'],'bridge':rs['arc']['endpoint'],'wrappedToken':rs['arc']['wrapped'],
           'vaultCodeHash':rs['robinhood']['endpointCodeHash'],'bridgeCodeHash':rs['arc']['endpointCodeHash'],'wrappedCodeHash':rs['arc']['wrappedCodeHash'],
           'sourceDeploymentBlock':rs['robinhood']['deploymentBlock'],'destinationDeploymentBlock':rs['arc']['deploymentBlock']}
    assets=[]
    if path.exists():
        manifest=json.loads(path.read_text())
        require(manifest.get('schema') in (1,2),'Unsupported frontend manifest schema')
        assets=manifest.get('assets',[]) if manifest['schema']==2 else ([manifest['asset']] if manifest.get('asset') else [])
        require(len({a['id'] for a in assets})==len(assets),'Duplicate frontend route identities')
        existing=next((a for a in assets if a['id']==asset['id']),None)
        require(existing is None or existing==asset,'Do not replace an existing route identity; add a new ID to preserve saved transfers')
    if not any(a['id']==asset['id'] for a in assets): assets.append(asset)
    write(path,{'schema':2,'assets':assets});print('Verified active deployment exported to '+str(path))

def operate(a):
    if a.action=='export-frontend': return export_frontend(Path(a.output).resolve())
    require(a.chain is not None,'--chain is required')
    cs=inputs(); rs=records(); c=cs[a.chain]; r=rs[a.chain]; other='arc' if a.chain=='robinhood' else 'robinhood'; rpc=rpc_for(a.chain)
    target=r['endpoint']; value=0; sender=SENDER; hardware=a.action in ('wire','activate')
    if a.action in ('status','complete'):
        require(a.tx,'--tx is the original source transaction hash')
        p=packet(a.chain,a.tx); state=packet_status(p);print(json.dumps({**p,'state':state},indent=2))
        if a.action=='status' or state=='complete': return
        require(state=='ready','Both DVNs have not verified this packet yet. Do not repeat the source transaction.')
        a.chain=other; c=cs[other]; r=rs[other]; target=r['endpoint']; rpc=rpc_for(other)
        inspect(other,r,'active')
        data=cast('calldata','complete((uint32,bytes32,uint64),bytes32,bytes)',p['origin'],p['guid'],p['message'])
    elif a.action=='wire':
        current=rpc.call(target,'peer()','latest');expected=rs[other]['endpoint']
        if current:
            require(current==int(expected,16),'Different immutable peer already set')
            inspect(a.chain,r,'paired');print('Already paired correctly.');return
        inspect(a.chain,r,'deployed'); sender=c['governance']
        token=rs[other]['wrapped'] if a.chain=='robinhood' else c['sourceAsset']
        data=cast('calldata','bootstrapSetPeer(address,address)',expected,token)
    elif a.action=='activate':
        if rpc.call(target,'pausedLanes()','latest')==0:
            inspect(a.chain,r,'active');print('Already active.');return
        # Verify BOTH sides before the first irreversible bootstrap closure.
        for chain in cs:
            phase='active' if rpc_for(chain).call(rs[chain]['endpoint'],'pausedLanes()','latest')==0 else 'paired'
            inspect(chain,rs[chain],phase)
        sender=c['governance'];data=cast('calldata','activate()')
    else:
        inspect(a.chain,r,'active')
        if a.action=='metadata':
            require(a.chain=='robinhood','Metadata must originate on Robinhood')
            value=rpc.call(target,'quoteMetadataFee()','latest');data=cast('calldata','publishMetadata()')
        else:
            require(a.amount_raw and a.amount_raw.isdecimal() and 0<int(a.amount_raw)<2**256,'A positive --amount-raw is required')
            amount=int(a.amount_raw)
            require(amount<=int(c['maxTransferRaw']),'Amount exceeds per-transfer maximum')
            if a.action=='approve':
                require(a.chain=='robinhood','Only the original stock token needs approval')
                target=c['sourceAsset'];data=cast('calldata','approve(address,uint256)',r['endpoint'],str(amount))
            else:
                method='deposit' if a.chain=='robinhood' else 'redeem'
                value=rpc.call(target,'quoteDepositFee(uint256,address)' if method=='deposit' else 'quoteRedeemFee(uint256,address)','latest',amount,SENDER)
                data=cast('calldata',method+'(uint256,address)',str(amount),SENDER)
    tx={'from':sender,'to':target,'data':data,'value':hex(value)}
    gas=int(rpc.request('eth_estimateGas',[tx]),16)
    plan={'action':a.action,'chain':a.chain,'chainId':c['evmChain'],'wallet':sender,'to':target,'data':data,'valueRaw':str(value),'estimatedGas':gas,'signer':'hardware wallet via browser' if hardware else 'local deployer key'}
    print(json.dumps(plan,indent=2),flush=True)
    if not a.broadcast:
        print('Simulation only. Add --broadcast --id <unique-operation-name> to sign this action.');return
    require(a.id and all(ch.isalnum() or ch in '-_' for ch in a.id),'Provide a unique --id using letters, digits, hyphen or underscore')
    folder=STATE/'operations'/a.id
    folder.mkdir(parents=True,exist_ok=True)
    marker=folder/'attempt.json'
    require(not marker.exists(),'Operation already attempted. Check its receipt / wallet activity; never repeat a source send automatically.')
    env={k:v for k,v in os.environ.items() if k!='DEPLOYER_PRIVATE_KEY'}
    cmd=send_command(plan,rpc.url)
    key=os.environ.get('DEPLOYER_PRIVATE_KEY')
    if hardware: cmd+=['--browser']
    else:
        require(key,'Set DEPLOYER_PRIVATE_KEY in your own terminal; never share it')
        require(address(cast('wallet','address','--private-key',key))==address(SENDER),'Wrong signer key')
        cmd+=['--private-key',key]
    with marker.open('x') as f: json.dump(plan,f,indent=2)
    # Hardware signing needs the browser URL visible; never capture / hide its prompt.
    if hardware:
        receipt_file=folder/'receipt.json'
        print('Approve only the displayed contract/action in your hardware wallet.',flush=True)
        process=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,text=True)
        lines=[]
        for line in process.stdout:
            print(line,end='',flush=True);lines.append(line)
        result_code=process.wait();output=''.join(lines)
        receipt_file.write_text(output)
        require(result_code==0,'Signing interrupted; preserve attempt record and reconcile wallet activity')
    else:
        result=subprocess.run(cmd,env=env,capture_output=True,text=True)
        output=result.stdout
        diagnostics=result.stderr
        for secret in (key,rpc.url):
            if secret:
                output=output.replace(secret,'[REDACTED]')
                diagnostics=diagnostics.replace(secret,'[REDACTED]')
        (folder/'receipt.json').write_text(output)
        (folder/'broadcast.stderr.log').write_text(diagnostics)
        if result.returncode != 0 and diagnostics.strip():
            print(diagnostics[-4000:],flush=True)
        require(result.returncode==0,'Broadcast outcome uncertain. Preserve attempt record and inspect wallet activity before any further action.')
    receipt=None
    for i,ch in enumerate(output):
        if ch!='{': continue
        try: candidate,_=json.JSONDecoder().raw_decode(output[i:])
        except ValueError: continue
        if isinstance(candidate,dict) and 'transactionHash' in candidate and 'status' in candidate:
            receipt=candidate;break
    require(receipt is not None,'Receipt output is incomplete. Preserve it and reconcile the transaction hash.')
    write(folder/'receipt.json',receipt)
    require((int(receipt['status'],16) if isinstance(receipt['status'],str) else receipt['status'])==1,'Transaction reverted; inspect receipt')
    print('Transaction: '+receipt['transactionHash']+'\nReceipt: '+str(folder/'receipt.json'))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['wire','activate','metadata','approve','send','status','complete','export-frontend'])
    p.add_argument('--chain',choices=['robinhood','arc']);p.add_argument('--broadcast',action='store_true');p.add_argument('--id');p.add_argument('--amount-raw');p.add_argument('--tx');p.add_argument('--output',default='../data-dex-frontend/src/lib/rwaBridge/layerzero-deployment.json')
    p.add_argument('--asset',choices=list(deployment.stock_catalog()),default='NVDA')
    a=p.parse_args();select_asset(a.asset);operate(a)
if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as e:
        raise SystemExit('LayerZero operation stopped: '+(str(e) if isinstance(e,ValueError) else 'Missing local input or tool failure. Preserve operation receipts.'))
