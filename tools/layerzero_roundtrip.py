#!/usr/bin/env python3
"""Record pilot balances before sending, then verify a completed mainnet NVDA round trip read-only."""
import argparse
from datetime import datetime, timezone
import json
from urllib.parse import urlparse

from layerzero_deploy import CONFIG, SENDER, inputs, inspect, rpc_for, write
from layerzero_operate import packet, packet_status, records
from preflight import cast, require


def balances():
    cs=inputs();rs=records();rh=rpc_for('robinhood');arc=rpc_for('arc')
    return {'sourceWallet':str(rh.call(cs['robinhood']['sourceAsset'],'balanceOf(address)','latest',SENDER)),
            'feeRecipient':str(rh.call(cs['robinhood']['sourceAsset'],'balanceOf(address)','latest',cs['robinhood']['treasury'])),
            'locked':str(rh.call(rs['robinhood']['endpoint'],'locked()','latest')),
            'wrappedWallet':str(arc.call(rs['arc']['wrapped'],'balanceOf(address)','latest',SENDER)),
            'wrappedSupply':str(arc.call(rs['arc']['wrapped'],'totalSupply()','latest'))}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['snapshot','verify']);p.add_argument('--deposit');p.add_argument('--redemption');a=p.parse_args()
    rs=records()
    for chain in rs:inspect(chain,rs[chain],'active')
    initial=CONFIG/'roundtrip-before.json'
    if a.action=='snapshot':
        require(not initial.exists(),'Initial snapshot already exists. Preserve it; do not overwrite after sending.')
        write(initial,{'wallet':SENDER,'observedAtUTC':datetime.now(timezone.utc).isoformat(),'balances':balances()})
        print('Initial snapshot: '+str(initial));return
    require(a.deposit and a.redemption,'Provide both original source transaction hashes')
    before=json.loads(initial.read_text())['balances'];after=balances()
    deposit=packet('robinhood',a.deposit);redemption=packet('arc',a.redemption)
    for packet_,action in [(deposit,1),(redemption,2)]:
        require(packet_status(packet_)=='complete','Both application claims must be consumed before verification')
        data=packet_['message'][2:]
        require(len(data)==640 and int(data[128:192],16)==action,'Wrong asset message action')
        require(int(data[512:576],16)==int(SENDER,16),'Pilot recipient is not the reviewed wallet')
    amount=int(deposit['message'][-64:],16)
    require(int(redemption['message'][-64:],16)==amount,'Return amount differs from the deposit net amount')
    receipt=rpc_for('robinhood').request('eth_getTransactionReceipt',[a.deposit])
    topic=cast('keccak','Deposited(uint64,address,address,uint256,uint256,uint256)')
    events=[l for l in receipt['logs'] if l['address'].lower()==rs['robinhood']['endpoint'].lower() and l['topics'][0]==topic]
    require(len(events)==1,'Deposit event missing')
    event=events[0];require(int(event['topics'][2],16)==int(SENDER,16),'Unexpected deposit sender')
    values=event['data'][2:];gross=int(values[:64],16);net=int(values[64:128],16);fee=int(values[128:192],16)
    require(net==amount and fee==gross*50//10000 and net+fee==gross,'Unexpected fee or minted amount')
    require(int(after['sourceWallet'])==int(before['sourceWallet'])-fee,'Original balance delta differs from fee; inspect intervening wallet activity')
    require(int(after['feeRecipient'])==int(before['feeRecipient'])+fee,'Fee recipient delta mismatch; inspect intervening activity')
    for field in ('locked','wrappedWallet','wrappedSupply'):
        require(after[field]==before[field],field+' did not return to its initial value')
    local_fork=any(urlparse(rpc_for(chain).url).hostname in ('localhost','127.0.0.1','::1') for chain in rs)
    report={'mainnetRoundTripVerified':not local_fork,'localForkRoundTripVerified':local_fork,'wallet':SENDER,'checkedAtUTC':datetime.now(timezone.utc).isoformat(),'deposit':a.deposit,'redemption':a.redemption,'rawGross':str(gross),'rawReturned':str(amount),'rawFee':str(fee),'before':before,'after':after,'notice':'This report verifies one round trip against the configured RPCs; local forks are explicitly distinguished. It is not an external security audit.'}
    write(CONFIG/'roundtrip-verified.json',report);print(json.dumps(report,indent=2))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,OSError) as e:raise SystemExit('Round-trip verification stopped: '+str(e))
