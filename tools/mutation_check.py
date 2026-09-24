#!/usr/bin/env python3
"""Challenge security tests by changing one rule at a time in a disposable local copy.

Never modifies production sources. Compilation failures are errors, not detected mutations.
This finite mutation set measures test sensitivity, not security completeness.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MUTATIONS = [
    ('vaa_validity', 'src/WormholeEndpoint.sol', 'if (!valid) revert InvalidVAA();', ''),
    ('emitter_chain', 'src/WormholeEndpoint.sol', 'message.emitterChainId != remoteWormholeChain', 'false'),
    ('source_domain', 'src/WormholeEndpoint.sol', '|| h.sourceEvmChain != remoteEvmChain', ''),
    ('destination_binding', 'src/WormholeEndpoint.sol', '|| h.destinationBridge != address(this)', ''),
    ('replay', 'src/WormholeEndpoint.sol', 'if (consumedMessages[id]) revert MessageAlreadyConsumed();', ''),
    ('inbound_pause', 'src/WormholeEndpoint.sol', '_checkLane(INBOUND);', ''),
    ('outbound_maximum', 'src/WormholeEndpoint.sol', 'if (amount > maxTransfer) revert TransferTooLarge();', ''),
    ('resume_authority', 'src/WormholeEndpoint.sol', 'function unpause(uint8 lanes) external onlyOwner', 'function unpause(uint8 lanes) external'),
    ('fee', 'src/SourceVault.sol', 'FEE_BPS = 50;', 'FEE_BPS = 51;'),
    ('treasury_authority', 'src/SourceVault.sol', 'function setFeeRecipient(address next) external onlyOwner nonReentrant', 'function setFeeRecipient(address next) external nonReentrant'),
    ('treasury_reentrancy', 'src/SourceVault.sol', 'function setFeeRecipient(address next) external onlyOwner nonReentrant', 'function setFeeRecipient(address next) external onlyOwner'),
    ('limit_authority', 'src/WormholeEndpoint.sol', 'function setMaxTransfer(uint256 next) external onlyOwner nonReentrant', 'function setMaxTransfer(uint256 next) external nonReentrant'),
    ('limit_reentrancy', 'src/WormholeEndpoint.sol', 'function setMaxTransfer(uint256 next) external onlyOwner nonReentrant', 'function setMaxTransfer(uint256 next) external onlyOwner'),
    ('inbound_limit_nondecreasing', 'src/WormholeEndpoint.sol', 'if (next <= inboundMaxTransfer) revert InvalidConfiguration();', 'if (next == 0) revert InvalidConfiguration();'),
    ('inbound_maximum', 'src/WormholeEndpoint.sol', 'if (transfer.amount > inboundMaxTransfer) revert TransferTooLarge();', ''),
    ('inbound_limit_authority', 'src/WormholeEndpoint.sol', 'function prepareInboundMaxTransfer(uint256 next) external onlyOwner nonReentrant', 'function prepareInboundMaxTransfer(uint256 next) external nonReentrant'),
    ('inbound_limit_reentrancy', 'src/WormholeEndpoint.sol', 'function prepareInboundMaxTransfer(uint256 next) external onlyOwner nonReentrant', 'function prepareInboundMaxTransfer(uint256 next) external onlyOwner'),
    ('net_backing', 'src/SourceVault.sol', 'locked += net;', 'locked += gross;'),
    ('exact_credit', 'src/SourceVault.sol', '|| asset.balanceOf(recipient) != beforeRecipient + amount', ''),
    ('mint_amount', 'src/DestinationBridge.sol', 'wrappedAsset.bridgeMint(t.recipient, t.amount);', 'wrappedAsset.bridgeMint(t.recipient, t.amount + 1);'),
    ('burn', 'src/DestinationBridge.sol', 'wrappedAsset.bridgeBurn(msg.sender, amount);', ''),
    ('metadata_freshness', 'src/WrappedAsset.sol', 'if (!metadataFresh()) revert StaleMetadata();', ''),
    ('metadata_ordering', 'src/WrappedAsset.sol', 'if (hasSnapshot && sequence <= snapshotSequence)', 'if (false)'),
]


def main():
    compiler = ROOT / '.tools/solc-0.8.28'
    command = ['forge', 'test', '--use', str(compiler) if compiler.exists() else '0.8.28', '--offline',
               '--match-contract', '^(BridgeTest|MetadataTest|InternalAuditTest|SignedVAATest|TreasuryGovernanceTest|TransferLimitGovernanceTest)$']
    env = dict(os.environ, FOUNDRY_PROFILE='default', FOUNDRY_FUZZ_RUNS='256', FOUNDRY_FUZZ_SEED='0x73796e74687261')
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
              for folder in ('src', 'test', 'vendor') for p in sorted((ROOT / folder).rglob('*')) if p.is_file()}
    hashes['foundry.toml'] = hashlib.sha256((ROOT / 'foundry.toml').read_bytes()).hexdigest()
    results = []
    with tempfile.TemporaryDirectory(prefix='synthra-mutation-') as temporary:
        work = Path(temporary)
        for folder in ('src', 'test', 'script', 'vendor', 'config'):
            shutil.copytree(ROOT / folder, work / folder, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copyfile(ROOT / 'foundry.toml', work / 'foundry.toml')
        baseline = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True, timeout=180)
        if baseline.returncode != 0:
            raise SystemExit('Mutation baseline failed:\n' + baseline.stdout + baseline.stderr)
        print('Mutation baseline passed', flush=True)
        for name, path, old, new in MUTATIONS:
            target = work / path
            original = (ROOT / path).read_text()
            if original.count(old) != 1:
                raise SystemExit(f'Mutation anchor is not unique: {name}')
            target.write_text(original.replace(old, new, 1))
            try:
                run = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            finally:
                target.write_text(original)
            failures = re.findall(r'^\[FAIL[^\n]*', run.stdout, re.MULTILINE)
            status = 'detected' if run.returncode != 0 and failures else 'survived' if run.returncode == 0 else 'error'
            results.append({'name': name, 'file': path, 'status': status, 'failingTests': failures})
            print(f'{name}: {status} ({len(failures)} failing tests)', flush=True)
            if status == 'error':
                print((run.stdout + run.stderr)[-4000:], flush=True)
    output = ROOT / 'audit/mutation-report.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps({'schema': 1, 'inputSha256': hashes, 'results': results}, indent=2) + '\n')
    if any(result['status'] != 'detected' for result in results):
        raise SystemExit('Mutation campaign incomplete; inspect audit/mutation-report.json')
    print(f'All {len(results)} targeted mutations detected', flush=True)


if __name__ == '__main__':
    main()
