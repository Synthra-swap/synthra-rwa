#!/usr/bin/env python3
"""Shared simulation environment and redacted Foundry logging for LayerZero deployment."""
from pathlib import Path
import subprocess
from evm_rpc import require

ROOT = Path(__file__).resolve().parents[1]

def simulation_environment(environ, deployment, state):
    # Do not let an inherited compiler/profile override silently change reviewed bytecode.
    env = {k: v for k, v in environ.items()
           if not k.startswith(('FOUNDRY_', 'DAPP_')) and k != 'DEPLOYER_PRIVATE_KEY'}
    env.update(DEPLOY_CONFIG=str(ROOT / deployment), FOUNDRY_PROFILE='deployment',
               FOUNDRY_BROADCAST=str(state / 'foundry'))
    return env

def run_logged(cmd, env, path, secret=None):
    # Do not print argv: it may contain a local signer key or a private RPC URL.
    run = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    output = run.stdout + run.stderr
    for value in (secret, env.get('SOURCE_RPC_URL'), env.get('DESTINATION_RPC_URL'),
                  env.get('SOURCE_FINALIZED_RPC_URL'), env.get('DESTINATION_FINALIZED_RPC_URL')):
        if value:
            output = output.replace(value, '[REDACTED]')
    path.write_text(output)
    path.chmod(0o600)
    require(run.returncode == 0, f'Foundry failed; inspect {path.relative_to(ROOT)}')
    return output
