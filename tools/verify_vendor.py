#!/usr/bin/env python3
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]/'vendor'
expected=json.loads((root/'SHA256SUMS.json').read_text())
actual={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file() and p.name!='SHA256SUMS.json'}
if actual!=expected:
    raise SystemExit('Vendored files changed: review upstream provenance and update lock intentionally.')
print(f'Verified {len(actual)} dependency files')
