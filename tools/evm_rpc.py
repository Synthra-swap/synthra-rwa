#!/usr/bin/env python3
"""Shared address/ABI validation and credential-safe RPC transport for LayerZero tools."""
import json
import re
import subprocess
import urllib.request
from rpc_policy import public_rpc_slot

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

class RPC:
    def __init__(self,url):
        require(url.startswith(('https://','http://')),'invalid RPC protocol')
        self.url=url
    def request(self,method,params):
        payload=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode()
        try:
            req=urllib.request.Request(self.url,payload,{'Content-Type':'application/json',
                'User-Agent':'Synthra-ReadOnly-Integration-Review/1.0'})
            with public_rpc_slot(self.url):
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
