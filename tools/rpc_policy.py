"""Optional finalized-state provider and shared pacing for the keyless NodeFlare RPC."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import time
from urllib.parse import urlsplit


NODEFLARE_INTERVAL = 11.0
PACE_FILE = Path(__file__).resolve().parents[1] / '.tools/rpc-pacing/nodeflare-public.lock'
FINALIZED_ENVS = {'SOURCE_RPC_URL': 'SOURCE_FINALIZED_RPC_URL',
                  'DESTINATION_RPC_URL': 'DESTINATION_FINALIZED_RPC_URL'}


def finalized_url(rpc_env, environ=None):
    environ = os.environ if environ is None else environ
    override = FINALIZED_ENVS.get(rpc_env)
    return environ[override] if override is not None and override in environ else environ[rpc_env]


def is_nodeflare_public(url):
    parsed = urlsplit(url)
    return (parsed.hostname == 'rpc.nodeflare.app'
            and parsed.path.rstrip('/') == '/robinhood/public')


@contextmanager
def public_rpc_slot(url):
    """Space request starts across local processes; never retry or cache a response.

    Hold the lock through the request so concurrent tools cannot burst together.
    Other machines sharing the public IP are outside this local coordination.
    """
    if not is_nodeflare_public(url):
        yield
        return
    PACE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with PACE_FILE.open('a+') as state:
        fcntl.flock(state, fcntl.LOCK_EX)
        try:
            state.seek(0)
            saved = state.read().strip()
            previous = float(saved) if saved else 0.0
            # A backwards wall-clock adjustment must not cause an unbounded wait.
            delay = min(NODEFLARE_INTERVAL, max(0.0, previous + NODEFLARE_INTERVAL - time.time()))
            if delay:
                time.sleep(delay)
            state.seek(0)
            state.truncate()
            state.write(str(time.time()))
            state.flush()
            yield
        finally:
            fcntl.flock(state, fcntl.LOCK_UN)
