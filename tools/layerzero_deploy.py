#!/usr/bin/env python3
"""Deploy reviewed LayerZero stocks, reconcile actual receipts, export public identities.

Simulation is the default. Broadcast uses DEPLOYER_PRIVATE_KEY from the operator's
terminal. A permanent per-chain attempt marker prevents accidental duplicate deploys.
Reconciliation is read-only and can be rerun after an interrupted broadcast.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from check_layerzero_config import validate_pair
from deploy_asset import run_logged, simulation_environment
from preflight import RPC, address, cast, require, ZERO

ROOT = Path(__file__).resolve().parents[1]
ASSET = 'NVDA'
CONFIG = ROOT / 'config/deployments/layerzero-mainnet/NVDA'
STATE = ROOT / '.tools/layerzero-deployment-runs/NVDA'
SENDER = '0xfd2301819C2064b7Bd06212D22594CEB172c07bf'
URLS = {'robinhood': 'https://rpc.mainnet.chain.robinhood.com', 'arc': 'https://rpc.mainnet.arc.io'}
ENVS = {'robinhood': 'SOURCE_RPC_URL', 'arc': 'DESTINATION_RPC_URL'}

def stock_catalog():
    return {a['symbol']:a for a in json.loads((ROOT/'config/layerzero.stocks.json').read_text())['assets']}

def select_asset(symbol):
    global ASSET, CONFIG, STATE
    require(symbol in stock_catalog(), 'Unknown reviewed stock')
    ASSET = symbol
    CONFIG = ROOT / 'config/deployments/layerzero-mainnet' / symbol
    STATE = ROOT / '.tools/layerzero-deployment-runs' / symbol

def stock_identity():
    return stock_catalog()[ASSET]

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)

def prepare():
    reviewed=json.loads((ROOT/'config/layerzero.nvda-pilot.example.json').read_text())
    require(address(reviewed['deployer'])==address(SENDER),'Unexpected reviewed deployer')
    stock=stock_identity()
    for chain in URLS:
        config=json.loads((ROOT/f'config/layerzero.{chain}.example.json').read_text())
        config.update(reviewed['overrides'])
        if ASSET != 'NVDA':
            config.update(sourceAsset=stock['token'], name='Synthra '+stock['name'], symbol='s'+ASSET,
                          maxTransferRaw=stock['maxTransferRaw'], inboundMaxTransferRaw=stock['maxTransferRaw'],
                          notes='Reviewed stock rollout using the same LayerZero policy and roles as NVDA. Fixed raw ceiling from September 24, 2026; not a live USD limit.')
        path=CONFIG/(chain+'.json')
        if path.exists():
            require(json.loads(path.read_text())==config,'Existing configuration differs; preserve and review it')
        else: write(path,config)
    inputs()
    print(ASSET+' configurations prepared; no transactions sent.')

def inputs():
    configs = {n: json.loads((CONFIG / (n + '.json')).read_text()) for n in URLS}
    validate_pair(configs['robinhood'], configs['arc'], json.loads((ROOT / 'config/layerzero.networks.example.json').read_text()))
    for c in configs.values():
        require(address(c['sourceAsset'])==address(stock_identity()['token']), 'Configuration does not match selected stock')
        require(c['symbol']=='s'+ASSET, 'Wrapped symbol does not match selected stock')
    return configs

def rpc_for(chain):
    rpc = RPC(os.environ.get(ENVS[chain], URLS[chain]))
    require(int(rpc.request('eth_chainId', []), 16) == inputs()[chain]['evmChain'], 'RPC chain mismatch')
    return rpc

def verify_runtime(rpc, target, contract, block='latest'):
    code = rpc.request('eth_getCode', [address(target), block])
    artifact = json.loads((ROOT / 'out' / (contract + '.sol') / (contract + '.json')).read_text())['deployedBytecode']
    actual = bytearray.fromhex(code[2:]); expected = bytearray.fromhex(artifact['object'].removeprefix('0x'))
    require(len(actual) == len(expected) and len(actual) > 0, contract + ': runtime size mismatch')
    for refs in artifact.get('immutableReferences', {}).values():
        for ref in refs:
            start, size = ref['start'], ref['length']
            actual[start:start+size] = bytes(size); expected[start:start+size] = bytes(size)
    require(actual == expected, contract + ': runtime differs from local build')
    return cast('keccak', code)

def inspect(chain, record, phase='deployed'):
    c = inputs()[chain]; rpc = rpc_for(chain)
    require(record['configSha256'] == hashlib.sha256((CONFIG/(chain+'.json')).read_bytes()).hexdigest(), 'Configuration changed since deployment')
    block = rpc.request('eth_getBlockByNumber', ['latest', False]); pin = block['number']
    endpoint, governor = address(record['endpoint']), address(record['timelock'])
    def call(target, signature, *args): return rpc.call(target, signature, pin, *args)
    def eq(signature, expected):
        require(call(endpoint, signature) == (int(expected, 16) if isinstance(expected, str) and expected.startswith('0x') else int(expected)), 'Mismatch: ' + signature)
    record['endpointCodeHash'] = verify_runtime(rpc, endpoint, 'LayerZeroSourceVault' if c['sourceSide'] else 'LayerZeroDestinationBridge', pin)
    record['timelockCodeHash'] = verify_runtime(rpc, governor, 'TimelockController', pin)
    for field in ('endpoint', 'sendLibrary', 'receiveLibrary', 'dvnA', 'dvnB', 'sendConfirmations', 'receiveConfirmations', 'localEid', 'remoteEid', 'remoteEvmChain', 'guardian'):
        eq(field + '()', c[field])
    eq('deploymentChainId()', c['evmChain']); eq('owner()', governor); eq('pendingOwner()', 0)
    eq('maxTransfer()', c['maxTransferRaw']); eq('inboundMaxTransfer()', c['inboundMaxTransferRaw'])
    require(call(governor, 'getMinDelay()') == c['governanceDelaySeconds'], 'Timelock delay mismatch')
    for role in ('PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE'):
        role_id = cast('keccak', role)
        require(call(governor, 'hasRole(bytes32,address)', role_id, c['governance']) == 1, 'Missing governance role')
        require(call(governor, 'hasRole(bytes32,address)', role_id, ZERO) == 0, 'Open timelock role')
    require(call(governor, 'hasRole(bytes32,address)', '0x'+'00'*32, c['governance']) == 0, 'Governance has direct admin role')
    require(call(governor, 'hasRole(bytes32,address)', '0x'+'00'*32, SENDER) == 0, 'Deployer retains timelock admin')
    require(call(governor, 'hasRole(bytes32,address)', '0x'+'00'*32, governor) == 1, 'Timelock self admin missing')
    if c['sourceSide']:
        eq('asset()', c['sourceAsset']); eq('feeRecipient()', c['treasury'])
        require(call(c['sourceAsset'], 'decimals()') == 18, 'Original token decimals changed')
        require(call(c['sourceAsset'], 'uid()') == int(stock_identity()['uid'], 16), 'Wrong stock UID')
    else:
        eq('originToken()', c['sourceAsset'])
        wrapped = '0x' + format(call(endpoint, 'wrappedAsset()'), '040x')
        record['wrapped'] = wrapped
        record['wrappedCodeHash'] = verify_runtime(rpc, wrapped, 'LayerZeroWrappedAsset', pin)
        for sig, val in [('bridge()', endpoint), ('originToken()', c['sourceAsset']), ('originEid()', c['remoteEid']), ('metadataMaxAge()', c['metadataMaxAgeSeconds'])]:
            require(call(wrapped, sig) == (int(val,16) if isinstance(val,str) and val.startswith('0x') else int(val)), 'Wrapped mismatch: '+sig)
    # Compare the effective (not default) ULN configuration in both directions.
    dvns = sorted([c['dvnA'], c['dvnB']], key=lambda x: int(x,16))
    for lib, confirmations in [(c['sendLibrary'], c['sendConfirmations']), (c['receiveLibrary'], c['receiveConfirmations'])]:
        result = rpc.request('eth_call', [{'to':lib,'data':cast('calldata','getUlnConfig(address,uint32)',endpoint,str(c['remoteEid']))},pin])
        expected = cast('abi-encode', 'f((uint64,uint8,uint8,uint8,address[],address[]))', f'({confirmations},2,0,0,[{dvns[0]},{dvns[1]}],[])')
        require(result.lower() == expected.lower(), 'Effective ULN configuration mismatch')
    require(call(c['endpoint'], 'getSendLibrary(address,uint32)', endpoint, c['remoteEid']) == int(c['sendLibrary'],16), 'Wrong effective send library')
    receive = rpc.request('eth_call',[{'to':c['endpoint'],'data':cast('calldata','getReceiveLibrary(address,uint32)',endpoint,str(c['remoteEid']))},pin])
    require(int(receive[2:66],16)==int(c['receiveLibrary'],16) and int(receive[66:130],16)==0, 'Wrong/default receive library')
    require(call(c['endpoint'],'delegates(address)',endpoint)==0,'Unexpected LayerZero delegate')
    if phase == 'deployed':
        eq('peer()', 0); eq('remoteToken()', 0); eq('pausedLanes()', 3); eq('bootstrapper()', c['governance'])
    else:
        other = 'arc' if chain == 'robinhood' else 'robinhood'
        remote = json.loads((CONFIG / (other+'.deployed.json')).read_text())
        eq('peer()', remote['endpoint']); eq('remoteToken()', remote['wrapped'] if c['sourceSide'] else c['sourceAsset'])
        eq('pausedLanes()', 0 if phase=='active' else 3)
        eq('bootstrapper()', 0 if phase=='active' else c['governance'])
    require(rpc.request('eth_getBlockByNumber',[pin,False])['hash']==block['hash'], 'Snapshot changed; rerun read-only check')
    record['checkedBlock'] = {'number':pin,'hash':block['hash']}
    record['phase'] = phase
    return record

def reconcile(chain):
    c=inputs()[chain]; state=STATE/chain; marker=json.loads((state/'attempt.json').read_text())
    require(marker['configSha256']==hashlib.sha256((CONFIG/(chain+'.json')).read_bytes()).hexdigest(),'Configuration changed since broadcast attempt')
    path=state/'foundry'/'DeployLayerZero.s.sol'/str(c['evmChain'])/'run-latest.json'
    result=json.loads(path.read_text()); rpc=rpc_for(chain)
    creations=[t for t in result.get('transactions',[]) if t.get('transactionType')=='CREATE']
    require(len(creations)==2,'Expected exactly two contract creation transactions; preserve all receipts')
    names=['TimelockController','LayerZeroSourceVault' if c['sourceSide'] else 'LayerZeroDestinationBridge']
    record={'chainId':c['evmChain'],'deployer':SENDER,'configSha256':marker['configSha256'],'receipts':[]}
    for tx, name, label in zip(creations,names,['timelock','endpoint']):
        require(tx.get('contractName')==name,'Unexpected deployed contract')
        receipt=rpc.request('eth_getTransactionReceipt',[tx['hash']]); require(receipt and int(receipt['status'],16)==1,'Broadcast unmined or reverted; never redeploy automatically')
        live=rpc.request('eth_getTransactionByHash',[tx['hash']])
        require(address(live['from'])==address(SENDER) and live['to'] is None,'Unexpected deployment sender/target')
        require(address(receipt['contractAddress'])==address(tx['contractAddress']),'Receipt address mismatch')
        require(rpc.request('eth_getBlockByNumber',[receipt['blockNumber'],False])['hash']==receipt['blockHash'],'Deployment receipt reorganized')
        record[label]=address(receipt['contractAddress']); record['receipts'].append(receipt)
    record=inspect(chain,record)
    record['deploymentBlock']=int(record['receipts'][-1]['blockNumber'],16)
    write(CONFIG/(chain+'.deployed.json'),record)
    print(json.dumps({k:v for k,v in record.items() if k!='receipts'},indent=2))

def deploy(chain, broadcast=False):
    c=inputs()[chain]; rpc=rpc_for(chain); state=STATE/chain; state.mkdir(parents=True,exist_ok=True)
    require(not (state/'attempt.json').exists(),'Broadcast previously attempted. Run reconcile; never delete the marker to retry.')
    for field in ('endpoint','sendLibrary','receiveLibrary','dvnA','dvnB'):
        require(rpc.request('eth_getCode',[c[field],'latest'])!='0x','Missing protocol code: '+field)
    require(rpc.call(c['endpoint'],'eid()','latest')==c['localEid'],'LayerZero domain mismatch')
    if chain=='robinhood':
        require(rpc.call(c['sourceAsset'],'uid()','latest')==int(stock_identity()['uid'],16),'Wrong stock identity')
    env=simulation_environment(os.environ,str(CONFIG/(chain+'.json')),state)
    key=os.environ.get('DEPLOYER_PRIVATE_KEY')
    if broadcast:
        require(key is not None,'Set DEPLOYER_PRIVATE_KEY in your terminal; never send it in chat')
        require(address(cast('wallet','address','--private-key',key))==address(SENDER),'Wrong deployer key')
    cmd=['forge','script','script/DeployLayerZero.s.sol:DeployLayerZero','--rpc-url',rpc.url,'--sender',SENDER,'--use',str(ROOT/'.tools/solc-0.8.28'),'--offline','--non-interactive']
    stamp=str(time.time_ns())
    output=run_logged(cmd,env,state/(stamp+'-simulation.log'),secret=key)
    print(chain+': simulation passed.',flush=True)
    for line in output.splitlines():
        if any(s in line for s in ('Timelock:','Endpoint:','Wrapped:','Estimated total gas','Amount required')): print(line,flush=True)
    if broadcast:
        with (state/'attempt.json').open('x') as f:
            json.dump({'chain':chain,'configSha256':hashlib.sha256((CONFIG/(chain+'.json')).read_bytes()).hexdigest(),'createdAt':stamp,'status':'preserve marker and reconcile receipts'},f,indent=2)
        run_logged(cmd+['--broadcast','--slow','--private-key',key],env,state/(stamp+'-broadcast.log'),secret=key)
        reconcile(chain)
        print('Deployment verified and paused. Hardware wallet must bind peers and activate.')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['prepare','deploy','reconcile','check']);p.add_argument('--chain',choices=list(URLS));p.add_argument('--broadcast',action='store_true');p.add_argument('--phase',choices=['deployed','paired','active'],default='deployed');p.add_argument('--asset',choices=list(stock_catalog()),default='NVDA');a=p.parse_args()
    select_asset(a.asset)
    require(not a.broadcast or a.action=='deploy','Broadcast is only accepted for deploy')
    if a.action=='prepare': return prepare()
    require(a.chain is not None,'--chain is required')
    if a.action=='deploy': deploy(a.chain,a.broadcast)
    elif a.action=='reconcile': reconcile(a.chain)
    else:
        record=json.loads((CONFIG/(a.chain+'.deployed.json')).read_text());print(json.dumps(inspect(a.chain,record,a.phase),indent=2))

if __name__=='__main__':
    try: main()
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as e:
        raise SystemExit('LayerZero deployment stopped: '+(str(e) if isinstance(e,ValueError) else 'Missing local input or tool failure. Preserve receipts and attempt markers.'))
