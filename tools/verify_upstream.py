#!/usr/bin/env python3
"""Read public pinned upstream sources and compare every vendored Solidity dependency byte.

Downloads stay in memory. No remote code is executed and no local content is uploaded.
Run separately from offline checks; a network failure is not a successful verification.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


def archive(package):
    data = fetch(package['source'])
    digest = hashlib.sha256(data).hexdigest()
    if digest != package['archiveSha256']:
        raise ValueError(f"Upstream archive hash mismatch: {package['package']}")
    folder = ROOT / 'vendor' / package['package']
    checked = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
        members = {'/'.join(Path(m.name).parts[1:]): m for m in tar.getmembers() if m.isfile()}
        for local in sorted(folder.rglob('*')):
            if local.is_file():
                relative = str(local.relative_to(folder))
                remote = tar.extractfile(members[relative]).read()
                if remote != local.read_bytes():
                    raise ValueError(f'Vendored file differs from upstream: {local.relative_to(ROOT)}')
                checked += 1
    return {'package': package['package'], 'url': package['source'], 'archiveSha256': digest,
            'verifiedFiles': checked}


def main():
    packages = json.loads((ROOT / 'vendor/PROVENANCE.json').read_text())
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(archive, p) for p in packages]
        results = [future.result() for future in futures]
    report = {'schema': 1, 'results': results, 'notice': 'Byte identity establishes provenance, not absence of vulnerabilities.'}
    (ROOT / 'audit/dependency-verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print('All pinned upstream files match the local vendored copies')


if __name__ == '__main__':
    main()
