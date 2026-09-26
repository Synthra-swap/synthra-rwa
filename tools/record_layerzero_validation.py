#!/usr/bin/env python3
"""Record completed internal checks only when logs and mutation inputs match the current candidate."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def summary(path):
    text=(ROOT/path).read_text()
    matches=re.findall(r'(\d+) tests passed, (\d+) failed, (\d+) skipped',text)
    if not matches:raise ValueError(f'No completed test summary: {path}')
    passed,failed,skipped=map(int,matches[-1])
    if failed or skipped or passed==0:raise ValueError(f'Incomplete or failed tests: {path}')
    return passed

def main():
    unit=summary('audit/unit-tests.log');audit=summary('audit/audit-tests.log')
    forks=summary('audit/live-fork-tests.log')
    if unit!=audit:raise ValueError('Default/audit test count mismatch')
    check=(ROOT/'audit/layerzero/check.log').read_text()
    if 'Audit checks passed.' not in check:raise ValueError('Local pipeline did not finish')
    python=int(re.search(r'Ran (\d+) tests in',check).group(1))
    mutation=json.loads((ROOT/'audit/layerzero/mutation-report.json').read_text())
    if not mutation['results'] or any(m['status']!='detected' for m in mutation['results']):raise ValueError('Unresolved mutations')
    for path,sha in mutation['inputSha256'].items():
        if digest(ROOT/path)!=sha:raise ValueError(f'Mutation evidence is stale: {path}')
    slither=json.loads((ROOT/'audit/slither.json').read_text())
    from check_slither import validate
    count=validate(slither,json.loads((ROOT/'tools/slither-reviewed.json').read_text()))
    abi=json.loads((ROOT/'audit/layerzero/abi-verification.json').read_text())
    if abi['localInterfaceSha256']!=digest(ROOT/'src/layerzero/ILayerZero.sol'):raise ValueError('Stale ABI comparison')
    report_paths=[ROOT/'audit'/n for n in ('unit-tests.log','audit-tests.log','coverage.log','coverage.lcov','slither.json','gas-report.log','python-tests.log','live-fork-tests.log')]
    report_paths += [ROOT/'audit/layerzero'/n for n in ('check.log','mutation-report.json','mutation.log','abi-verification.json','network-review.json','build-sizes.log','live-fork-tests.log')]
    report_paths += [ROOT/'audit/layerzero'/n for n in ('confirmation-policy-check.json','robinhood-finality-samples-20260925.json','robinhood-finality-crosscheck-20260925.json','robinhood-confirmations-proposal-20260925.json')]
    report_paths += [ROOT/'audit/layerzero/layerzero-default-confirmations-20260925.json']
    inputs=[p for folder in ('src','test','script','integration','tools','docs','vendor','.github') for p in (ROOT/folder).rglob('*')
            if p.is_file() and '__pycache__' not in p.parts]
    inputs += list((ROOT/'config').glob('*.example.json'))+[ROOT/'config/layerzero.stocks.json',ROOT/'config/layerzero.mainnet.json',ROOT/'foundry.toml',ROOT/'README.md']
    report={'schema':2,'date':datetime.now(timezone.utc).isoformat(),'status':'internal checks recorded for the listed file hashes; deployment observations are separate; external audit in progress',
            'solidityTests':unit,'pythonTests':python,'forkTests':forks,'targetedMutations':len(mutation['results']),
            'comparedFunctionAbis':len(abi['comparedFunctions']),
            'staticAnalysis':{'high':0,'medium':0,'reviewedLow':count},
            'notice':'Finite tests/mutations and simulated fork attestations do not establish production finality, worker liveness, or third-party audit approval.',
            'files':{str(p.relative_to(ROOT)):digest(p) for p in sorted(set(inputs+report_paths))}}
    (ROOT/'audit/layerzero/validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))
if __name__=='__main__':main()
