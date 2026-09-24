#!/usr/bin/env python3
"""Prepare and simulate an unsigned relay transaction. Never signs or submits."""
import argparse
import json
import os
import sys
from pathlib import Path
from preflight import RPC,address,cast,require

def main():
    p=argparse.ArgumentParser();p.add_argument('--kind',choices=['deposit','redemption','metadata'],required=True)
    p.add_argument('--vaa',required=True);p.add_argument('--endpoint',required=True);p.add_argument('--sender',required=True)
    p.add_argument('--rpc-env',required=True);p.add_argument('--chain-id',type=int,required=True);a=p.parse_args()
    vaa=Path(a.vaa).read_text().strip();raw=bytes.fromhex(vaa.removeprefix('0x'));require(0<len(raw)<=65536,'invalid VAA size')
    signatures={'deposit':'completeDeposit(bytes)','redemption':'completeRedemption(bytes)','metadata':'completeMetadata(bytes)'}
    data=cast('calldata',signatures[a.kind],'0x'+raw.hex())
    tx={'to':address(a.endpoint),'from':address(a.sender),'data':data,'value':'0x0'}
    rpc=RPC(os.environ[a.rpc_env]);require(int(rpc.request('eth_chainId',[]),16)==a.chain_id,'wrong chain')
    require(rpc.request('eth_getCode',[tx['to'],'latest'])!='0x','endpoint has no code')
    rpc.request('eth_call',[tx,'latest']);gas=int(rpc.request('eth_estimateGas',[tx]),16)
    tx['chainId']=hex(a.chain_id);tx['gas']=hex((gas*120+99)//100)
    print(json.dumps({'unsignedTransaction':tx,'simulation':'passed','note':'Re-simulate at signing time. Simulation does not guarantee later inclusion or completion.'},indent=2))
if __name__=='__main__':
    try:main()
    except Exception as e:
        print(f'Relay preparation failed: {e}',file=sys.stderr);sys.exit(1)
