#!/usr/bin/env python3
"""Exercise the exact deployment/reconciliation/bootstrap/metadata/asset tools on LOCAL forks only.
Requires anvil forks on 127.0.0.1:18546 (Robinhood) / :18547 (Arc), auto-impersonation.
Never connects a transaction sender to a mainnet URL. All mutations remain inside anvil.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import sys

import layerzero_deploy as deploy
import layerzero_operate as operate
import layerzero_roundtrip as roundtrip
from preflight import cast, require


def main():
    original=deploy.CONFIG
    directory=deploy.ROOT/'config/deployments/layerzero-operations-fork'/str(time.time_ns())
    directory.mkdir(parents=True)
    for chain in deploy.URLS: shutil.copyfile(original/(chain+'.json'),directory/(chain+'.json'))
    deploy.CONFIG=directory;operate.CONFIG=directory;roundtrip.CONFIG=directory
    deploy.STATE=deploy.ROOT/'.tools/layerzero-operations-fork'/directory.name
    operate.STATE=deploy.STATE
    os.environ['SOURCE_RPC_URL']='http://127.0.0.1:18546'
    os.environ['DESTINATION_RPC_URL']='http://127.0.0.1:18547'
    # Hard fail if a production URL can reach the local transaction path.
    def local(chain):
        rpc=deploy.rpc_for(chain)
        require(rpc.url in ('http://127.0.0.1:18546','http://127.0.0.1:18547'),'LOCAL FORKS ONLY')
        require('anvil' in rpc.request('web3_clientVersion',[]).lower(),'Expected local anvil')
        return rpc
    def send(chain,sender,to,data,value=0):
        rpc=local(chain)
        request={'from':sender,'to':to,'data':data,'value':hex(value)}
        gas=int(rpc.request('eth_estimateGas',[request]),16)
        request['gas']=hex(gas*120//100)
        h=rpc.request('eth_sendTransaction',[request])
        receipt=None
        for _ in range(100):
            receipt=rpc.request('eth_getTransactionReceipt',[h])
            if receipt: break
            time.sleep(0.1)
        require(receipt and int(receipt['status'],16)==1,'Local fork transaction failed: '+h)
        return h
    for chain in deploy.URLS:
        rpc=local(chain);state=deploy.STATE/chain;state.mkdir(parents=True)
        env=deploy.simulation_environment(os.environ,str(directory/(chain+'.json')),state)
        cmd=['forge','script','script/DeployLayerZero.s.sol:DeployLayerZero','--rpc-url',rpc.url,'--sender',deploy.SENDER,'--use',str(deploy.ROOT/'.tools/solc-0.8.28'),'--offline','--non-interactive','--broadcast','--unlocked','--slow']
        deploy.write(state/'attempt.json',{'configSha256':hashlib.sha256((directory/(chain+'.json')).read_bytes()).hexdigest()})
        deploy.run_logged(cmd,env,state/'local-deploy.log')
        deploy.reconcile(chain)
    cs=deploy.inputs();rs=operate.records()
    for chain in cs:
        for field in ('dvnA','dvnB'):
            local(chain).request('anvil_setBalance',[cs[chain][field],hex(10**21)])
    for chain in cs:
        other='arc' if chain=='robinhood' else 'robinhood'
        token=rs[other]['wrapped'] if chain=='robinhood' else cs[chain]['sourceAsset']
        send(chain,cs[chain]['governance'],rs[chain]['endpoint'],cast('calldata','bootstrapSetPeer(address,address)',rs[other]['endpoint'],token))
    for chain in cs: deploy.inspect(chain,rs[chain],'paired')
    for chain in cs:
        send(chain,cs[chain]['governance'],rs[chain]['endpoint'],cast('calldata','activate()'))
        deploy.inspect(chain,rs[chain],'active')
    operate.export_frontend(directory/'frontend.json')
    def deliver(chain,tx):
        p=operate.packet(chain,tx);dest=p['destinationChain'];rpc=local(dest)
        require(operate.packet_status(p)=='attesting','Local packet should not already have DVN votes')
        for dvn in ('dvnA','dvnB'):
            send(dest,cs[dest][dvn],cs[dest]['receiveLibrary'],cast('calldata','verify(bytes,bytes32,uint64)',p['header'],p['payloadHash'],str(cs[dest]['receiveConfirmations'])))
        require(operate.packet_status(p)=='ready','Both local DVN votes must make packet ready')
        result=send(dest,deploy.SENDER,rs[dest]['endpoint'],cast('calldata','complete((uint32,bytes32,uint64),bytes32,bytes)',p['origin'],p['guid'],p['message']))
        require(operate.packet_status(p)=='complete','Application did not consume packet')
        return result
    rh=local('robinhood');arc=local('arc');vault=rs['robinhood']['endpoint'];bridge=rs['arc']['endpoint'];wrapped=rs['arc']['wrapped'];token=cs['robinhood']['sourceAsset']
    fee=rh.call(vault,'quoteMetadataFee()','latest')
    metadata=send('robinhood',deploy.SENDER,vault,cast('calldata','publishMetadata()'),fee)
    deliver('robinhood',metadata)
    require(arc.call(wrapped,'metadataFresh()','latest')==1,'Metadata not fresh')
    sys.argv=['layerzero_roundtrip.py','snapshot'];roundtrip.main()
    amount=10**16;net=amount-amount*50//10000
    before=rh.call(token,'balanceOf(address)','latest',deploy.SENDER)
    send('robinhood',deploy.SENDER,token,cast('calldata','approve(address,uint256)',vault,str(amount)))
    fee=rh.call(vault,'quoteDepositFee(uint256,address)','latest',amount,deploy.SENDER)
    deposit=send('robinhood',deploy.SENDER,vault,cast('calldata','deposit(uint256,address)',str(amount),deploy.SENDER),fee)
    deliver('robinhood',deposit)
    require(arc.call(wrapped,'balanceOf(address)','latest',deploy.SENDER)==net,'Mint amount mismatch')
    fee=arc.call(bridge,'quoteRedeemFee(uint256,address)','latest',net,deploy.SENDER)
    redemption=send('arc',deploy.SENDER,bridge,cast('calldata','redeem(uint256,address)',str(net),deploy.SENDER),fee)
    deliver('arc',redemption)
    require(rh.call(token,'balanceOf(address)','latest',deploy.SENDER)==before-(amount-net),'Round-trip loss differs from configured fee')
    require(rh.call(vault,'locked()','latest')==0 and arc.call(wrapped,'totalSupply()','latest')==0,'Residual pilot liabilities')
    sys.argv=['layerzero_roundtrip.py','verify','--deposit',deposit,'--redemption',redemption];roundtrip.main()
    proof=json.loads((directory/'roundtrip-verified.json').read_text())
    require(proof['mainnetRoundTripVerified'] is False and proof['localForkRoundTripVerified'] is True,'Local evidence must never be labeled as mainnet')
    report={'verificationMode':'DVN addresses impersonated on local forks; no mainnet delivery timing measured','kind':'local-fork-operations','notMainnetTransactions':True,'deploymentReceiptsReconciled':True,'pairedAndActivated':True,'metadataDelivered':True,'roundTripComplete':True,'rawGross':str(amount),'rawReturned':str(net),'rawFee':str(amount-net),'evidenceDirectory':str(directory)}
    deploy.write(deploy.STATE/'result.json',report)
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
