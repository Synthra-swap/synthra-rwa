#!/usr/bin/env python3
"""Create deterministic audit archive; omit secrets, real deployment configs, caches and binaries."""
from pathlib import Path
import gzip,hashlib,io,json,tarfile
root=Path(__file__).resolve().parents[1]
allowed={'src','test','integration','script','tools','docs','vendor','.github'}
roots={'README.md','foundry.toml','.gitignore','SECURITY.md','LICENSE'}
reports={'audit-tests.log','unit-tests.log','coverage.log','coverage.lcov','slither.json','slither.log','gas-report.log','demo.log',
         'python-tests.log','mutation-report.json','mutation.log','dependency-verification.json','internal-review-snapshot.json',
         'live-fork-tests.log'}
review_paths = {'audit/READINESS_REVIEW_2026-09-23.md', 'audit/treasury-review-snapshot.json',
                'audit/twelve-asset-review-snapshot.json', 'audit/no-total-cap-review-snapshot.json',
                'audit/mutable-transfer-limit-review-snapshot.json', 'audit/no-rate-limit-review-snapshot.json'}
review_paths.update('audit/readiness-review/' + name for name in (
    'PRODUCT_DECISIONS.md', 'initial-asset-candidates.json', 'selection-assets.json',
    'selection-prices.json', 'selection-dex-pairs.json', 'forge-audit.log',
    'forge-audit-expanded.log', 'forge-audit-assets.log',
    'fork-assets-registry-20260924.json', 'fork-pins-20260924.json',
    'twelve-asset-code-identities.json', 'no-total-cap-fork-pins.json', 'mutable-transfer-limit-fork-pins.json', 'no-rate-limit-fork-pins.json'))
network_reports={'asset-registry.json','observations-both-finalized.json','observations-robinhood-latest.json',
                 'robinhood-finalized-rpc.json','arc-finalized-rpc.json','robinhood-latest-rpc.json',
                 'token-implementation-sourcify.json','token-source-check.json','live-vaa-verification.json'}
paths=[]
for p in sorted(root.rglob('*')):
    if not p.is_file():continue
    rel=p.relative_to(root)
    if any(x in rel.parts for x in ('__pycache__','.git','.tools','out','cache','broadcast')):continue
    if rel.parts[0] in allowed or str(rel) in roots or str(rel) in review_paths or (rel.parts[0]=='config' and p.name.endswith('.example.json')) or (rel.parts[0]=='audit' and p.name in reports) or (rel.parent == Path('audit/network') and p.name in network_reports):
        paths.append(p)
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
encoded=(json.dumps({'schema':1,'files':manifest},indent=2)+'\n').encode()
(root/'audit/RELEASE_MANIFEST.json').write_bytes(encoded)
output=root/'audit/synthra-rwa-bridge-audit.tar.gz'
with output.open('wb') as raw,gzip.GzipFile(fileobj=raw,mode='wb',filename='',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as tar:
    for name,data in [(str(p.relative_to(root)),p.read_bytes()) for p in paths]+[('audit/RELEASE_MANIFEST.json',encoded)]:
        entry=tarfile.TarInfo(name);entry.size=len(data);entry.mode=0o644;entry.mtime=0
        tar.addfile(entry,io.BytesIO(data))
digest=hashlib.sha256(output.read_bytes()).hexdigest()
(root/'audit/SHA256SUMS').write_text(f'{digest}  {output.name}\n')
print(f'{len(manifest)} files packaged: {output.name}\nSHA256 {digest}')
