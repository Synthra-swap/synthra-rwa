#!/usr/bin/env python3
"""Finite security mutation campaign in a disposable copy. Compile errors are never kills."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
E = 'src/layerzero/LayerZeroEndpoint.sol'
S = 'src/layerzero/LayerZeroSourceVault.sol'
D = 'src/layerzero/LayerZeroDestinationBridge.sol'
W = 'src/layerzero/LayerZeroWrappedAsset.sol'
DEP = 'script/DeployLayerZero.s.sol'
MUTATIONS = [
 ('endpoint_authentication',E,'if (msg.sender != address(endpoint)) revert OnlyEndpoint();',''),
 ('source_eid',E,'origin.srcEid != remoteEid ||','false ||'),
 ('peer_sender',E,'origin.sender != bytes32(uint256(uint160(peer)))','false'),
 ('nonce_zero',E,'if (origin.nonce == 0) revert InvalidMessage();',''),
 ('evm_domain',E,'if (block.chainid != deploymentChainId) revert WrongEvmChain();',''),
 ('replay',E,'if (consumedMessages[guid]) revert MessageAlreadyConsumed();',''),
 ('record_consumption',E,'if (msg.value != 0) revert InvalidMessage();\n        consumedMessages[guid] = true;','if (msg.value != 0) revert InvalidMessage();\n        consumedMessages[guid] = false;'),
 ('receive_native_value',E,'if (msg.value != 0) revert InvalidMessage();',''),
 ('outbound_maximum',E,'if (amount > maxTransfer) revert TransferTooLarge();',''),
 ('inbound_maximum',E,'if (t.amount > inboundMaxTransfer) revert TransferTooLarge();',''),
 ('pause_effect',E,'if (pausedLanes & lane != 0) revert LanePaused(lane);',''),
 ('guardian_authority',E,'msg.sender != guardian && msg.sender != owner()','false'),
 ('resume_authority',E,'function unpause(uint8 lanes) external onlyOwner','function unpause(uint8 lanes) external'),
 ('bootstrap_authority',E,'bootstrapper == address(0) || msg.sender != bootstrapper','false'),
 ('bootstrap_closure',E,'bootstrapper = address(0);','bootstrapper = previous;'),
 ('partial_unpause_closure',E,'_closeBootstrap();\n        pausedLanes &= ~lanes;','pausedLanes &= ~lanes;'),
 ('ownership_bootstrap_closure',E,'_closeBootstrap();\n        super.transferOwnership(newOwner);','super.transferOwnership(newOwner);'),
 ('peer_once',E,'if (peer != address(0)) revert PeerAlreadySet();',''),
 ('peer_asset_binding',D,'if (token != originToken) revert InvalidConfiguration();',''),
 ('limit_owner',E,'function setMaxTransfer(uint256 next) external onlyOwner nonReentrant','function setMaxTransfer(uint256 next) external nonReentrant'),
 ('limit_reentrancy',E,'function setMaxTransfer(uint256 next) external onlyOwner nonReentrant','function setMaxTransfer(uint256 next) external onlyOwner'),
 ('ceiling_owner',E,'function prepareInboundMaxTransfer(uint256 next) external onlyOwner nonReentrant','function prepareInboundMaxTransfer(uint256 next) external nonReentrant'),
 ('ceiling_reentrancy',E,'function prepareInboundMaxTransfer(uint256 next) external onlyOwner nonReentrant','function prepareInboundMaxTransfer(uint256 next) external onlyOwner'),
 ('ceiling_monotonic',E,'if (next <= inboundMaxTransfer) revert InvalidConfiguration();','if (next == 0) revert InvalidConfiguration();'),
 ('header_domain',E,'h.domain != Message.DOMAIN ||','false ||'),
 ('header_version',E,'h.version != Message.VERSION ||','false ||'),
 ('header_action',E,'h.action != action','false'),
 ('header_source_evm',E,'h.sourceEvmChain != remoteEvmChain','false'),
 ('header_destination_evm',E,'h.destinationEvmChain != deploymentChainId','false'),
 ('header_destination_eid',E,'h.destinationChain != localEid','false'),
 ('header_destination_app',E,'h.destinationBridge != address(this)','false'),
 ('header_asset',E,'h.originToken != token','false'),
 ('payload_length',E,'if (message.length != length) revert InvalidMessage();',''),
 ('required_dvn_count',E,'UlnConfig(c.receiveConfirmations, 2, 255, 0, dvns, new address[](0))','UlnConfig(c.receiveConfirmations, 1, 255, 0, dvns, new address[](0))'),
 ('optional_default_inheritance',E,'UlnConfig(c.sendConfirmations, 2, 255, 0, dvns, new address[](0))','UlnConfig(c.sendConfirmations, 2, 0, 0, dvns, new address[](0))'),
 ('send_confirmations',E,'UlnConfig(c.sendConfirmations, 2, 255, 0, dvns, new address[](0))','UlnConfig(1, 2, 255, 0, dvns, new address[](0))'),
 ('metadata_message_size',E,'uint32(Message.METADATA_LENGTH)','uint32(Message.TRANSFER_LENGTH)'),
 ('commit_verification',E,'ILayerZeroUln(receiveLibrary).commitVerification(header, payloadHash);',''),
 ('batch_verification',E,'ILayerZeroUln(receiveLibrary).commitVerification(header, v.payloadHash);',''),
 ('batch_consumed_race',E,'if (consumedMessages[guid] || checkpointedPayloads[guid] != bytes32(0)) continue;',''),
 ('fee_rate',S,'FEE_BPS = 50;','FEE_BPS = 51;'),
 ('net_reserves',S,'locked += net;','locked += gross;'),
 ('exact_deposit',S,'if (asset.balanceOf(address(this)) != beforeBalance + gross) revert UnsupportedTransfer();',''),
 ('exact_debit',S,'asset.balanceOf(address(this)) != beforeBalance - amount','false'),
 ('exact_credit',S,'|| asset.balanceOf(recipient) != beforeRecipient + amount',''),
 ('backing_before_deposit',S,'if (beforeBalance < locked) revert InsufficientBacking();',''),
 ('fee_owner',S,'function setFeeRecipient(address next) external onlyOwner nonReentrant','function setFeeRecipient(address next) external nonReentrant'),
 ('fee_reentrancy',S,'function setFeeRecipient(address next) external onlyOwner nonReentrant','function setFeeRecipient(address next) external onlyOwner'),
 ('mint_amount',D,'wrappedAsset.bridgeMint(t.recipient, t.amount);','wrappedAsset.bridgeMint(t.recipient, t.amount + 1);'),
 ('burn',D,'wrappedAsset.bridgeBurn(msg.sender, amount);',''),
 ('burn_holder',D,'wrappedAsset.bridgeBurn(msg.sender, amount);','wrappedAsset.bridgeBurn(recipient, amount);'),
 ('wrapped_authority',W,'if (msg.sender != bridge) revert OnlyBridge();',''),
 ('metadata_freshness',W,'if (!metadataFresh()) revert StaleMetadata();',''),
 ('metadata_ordering',W,'if (hasSnapshot && sequence <= snapshotSequence)','if (false)'),
 ('metadata_future',W,'observed > block.timestamp + MAX_CLOCK_SKEW','false'),
 ('metadata_age',W,'block.timestamp > observed + metadataMaxAge','false'),
 ('metadata_zero',W,'current == 0 || next == 0','false'),
 ('metadata_schedule',W,'(effective != 0 && effective <= observed)','false'),
 ('timelock_owner',DEP,'p.endpoint.owner = governor;','p.endpoint.owner = p.governance;'),
 ('timelock_admin',DEP,'new TimelockController(p.delay, members, members, address(0))','new TimelockController(p.delay, members, members, p.governance)'),
 ('timelock_delay',DEP,'p.delay >= 2 days','p.delay >= 0'),
 ('deploy_bootstrap',DEP,'p.endpoint.bootstrapper = p.governance;','p.endpoint.bootstrapper = address(0);'),
 ('checkpoint_store',E,'checkpointedPayloads[guid] = hash;','checkpointedPayloads[guid] = bytes32(0);'),
 ('checkpoint_authentication',E,'checkpointedPayloads[guid] != keccak256(abi.encodePacked(guid, message))','false'),
 ('checkpoint_protocol_clear',E,'endpoint.clear(address(this), origin, guid, message);',''),
 ('checkpoint_reentrancy',E,'function checkpoint(Origin calldata origin, bytes32 guid, bytes calldata message) external nonReentrant','function checkpoint(Origin calldata origin, bytes32 guid, bytes calldata message) external'),
]
# Delete canonical-GUID validation without changing the independent replay check.
endpoint_source = (ROOT / E).read_text()
a = endpoint_source.index('        if (\n', endpoint_source.index('function _checkGuid'))
b = endpoint_source.index('        if (consumedMessages[guid]) revert', a)
MUTATIONS.append(('canonical_guid', E, endpoint_source[a:b], ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', action='append', default=[])
    args = parser.parse_args()
    selected = [m for m in MUTATIONS if not args.only or m[0] in args.only]
    if not selected or set(args.only) - {m[0] for m in MUTATIONS}:
        raise SystemExit('Unknown mutation name')
    for name, path, old, _ in selected:
        if (ROOT/path).read_text().count(old) != 1:
            raise SystemExit(f'Non-unique mutation anchor: {name}')
    compiler = ROOT / '.tools/solc-0.8.28'
    command = ['forge','test','--use',str(compiler) if compiler.exists() else '0.8.28','--offline',
               '--match-contract','^LayerZero(Bridge|Metadata|Deployment|HardwareWalletGovernance|Security|Verification)Test$']
    env = dict(os.environ,FOUNDRY_PROFILE='default',FOUNDRY_FUZZ_RUNS='256',FOUNDRY_FUZZ_SEED='0x73796e74687261')
    inputs = [p for folder in ('src','test','script','vendor') for p in sorted((ROOT/folder).rglob('*')) if p.is_file()]
    inputs += list((ROOT/'config').glob('*.example.json')) + [ROOT/'foundry.toml',Path(__file__)]
    hashes = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    results=[]
    with tempfile.TemporaryDirectory(prefix='synthra-lz-mutation-') as temporary:
        work=Path(temporary)
        for folder in ('src','test','script','vendor'):
            shutil.copytree(ROOT/folder,work/folder,ignore=shutil.ignore_patterns('__pycache__'))
        (work/'config').mkdir()
        for p in (ROOT/'config').glob('*.example.json'): shutil.copyfile(p,work/'config'/p.name)
        shutil.copyfile(ROOT/'foundry.toml',work/'foundry.toml')
        baseline=subprocess.run(command,cwd=work,env=env,capture_output=True,text=True,timeout=240)
        if baseline.returncode != 0: raise SystemExit('Baseline failed:\n'+baseline.stdout+baseline.stderr)
        print('LayerZero mutation baseline passed',flush=True)
        for name,path,old,new in selected:
            target=work/path; original=(ROOT/path).read_text(); target.write_text(original.replace(old,new,1))
            try: run=subprocess.run(command,cwd=work,env=env,capture_output=True,text=True,timeout=240)
            finally: target.write_text(original)
            failures=re.findall(r'^\[FAIL[^\n]*',run.stdout,re.MULTILINE)
            status='detected' if run.returncode and failures else 'survived' if run.returncode == 0 else 'error'
            results.append({'name':name,'file':path,'status':status,'failingTests':failures})
            print(f'{name}: {status} ({len(failures)} failing tests)',flush=True)
            if status=='error': print((run.stdout+run.stderr)[-3000:],flush=True)
    if any(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h for p,h in hashes.items()):
        raise SystemExit('Input changed during campaign; rerun before treating this result as current')
    out=ROOT/'audit/layerzero'/('mutation-partial.json' if args.only else 'mutation-report.json')
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps({'schema':1,'scope':'finite targeted mutations; not proof of security completeness','inputSha256':hashes,'results':results},indent=2)+'\n')
    if any(r['status']!='detected' for r in results): raise SystemExit(f'Mutation campaign incomplete: {out}')
    print(f'All {len(results)} targeted LayerZero mutations detected',flush=True)

if __name__=='__main__': main()
