"""Adversarial RPC fixtures; these exercise validation, not a live network."""
import unittest
from unittest.mock import patch
from preflight import inspect, ZERO
from test_preflight import fixture

HASH = '0x' + 'a' * 64
ENDPOINT = '0x' + '6' * 40
REMOTE = '0x' + '7' * 40
GOVERNOR = '0x' + '8' * 40
WRAPPED = '0x' + '9' * 40
PIN = '0x20'


class FakeRPC:
    def __init__(self, config):
        self.c = config
        self.overrides = {}
        self.codes = {}
        self.reorg = False
        self.finalized = True

    def request(self, method, params):
        if method == 'eth_chainId':
            return hex(self.c['evmChain'])
        if method == 'eth_getBlockByNumber':
            if params[0] == 'finalized' and not self.finalized:
                return None
            return {'number': PIN, 'hash': 'changed' if self.reorg and params[0] == PIN else HASH,
                    'timestamp': '0x1234'}
        if method == 'eth_getCode':
            assert params[1] == PIN, 'unpinned code read'
            return self.codes.get(params[0], '0x6000')
        raise AssertionError(f'unexpected RPC method: {method}')

    def call(self, target, signature, block, *args):
        assert block == PIN, 'unpinned state read'
        if (target, signature, args) in self.overrides:
            return self.overrides[target, signature, args]
        c = self.c
        if signature == 'hasRole(bytes32,address)':
            role, account = args
            if role == '0x' + '0' * 64:
                return int(account == GOVERNOR)
            return int(account == c['governanceSafe'])
        common = {'getMinDelay()': 172800, 'chainId()': c['wormholeChain'],
                  'evmChainId()': c['evmChain'], 'decimals()': 18, 'balanceOf(address)': 995,
                  'uiMultiplier()': 10**18, 'newUIMultiplier()': 10**18, 'effectiveAt()': 0}
        if signature in common:
            return common[signature]
        values = {
            'owner()': int(GOVERNOR, 16), 'pendingOwner()': 0, 'peer()': int(REMOTE, 16),
            'wormhole()': int(c['core'], 16), 'guardian()': int(c['guardian'], 16),
            'deploymentChainId()': c['evmChain'], 'remoteEvmChain()': c['remoteEvmChain'],
            'localWormholeChain()': c['wormholeChain'], 'remoteWormholeChain()': c['remoteWormholeChain'],
            'outboundConsistency()': c['outboundConsistency'], 'inboundConsistency()': c['inboundConsistency'],
            'maxTransfer()': c['maxTransferRaw'], 'inboundMaxTransfer()': c['inboundMaxTransferRaw'], 'pausedLanes()': 3,
            'remoteToken()': int(WRAPPED if c['sourceSide'] else c['sourceAsset'], 16),
            'asset()': int(c['sourceAsset'], 16), 'feeRecipient()': int(c['treasury'], 16),
            'FEE_BPS()': 50, 'locked()': 995,
            'originToken()': int(c['sourceAsset'], 16),
            'wrappedAsset()': int(WRAPPED, 16), 'bridge()': int(ENDPOINT, 16),
            'originWormholeChain()': c['remoteWormholeChain'],
            'metadataMaxAge()': c['metadataMaxAgeSeconds'], 'totalSupply()': 995, 'metadataFresh()': 1,
        }
        return int(values[signature])


class NetworkPreflightTests(unittest.TestCase):
    def check(self, rpc, phase='prepared'):
        meta = dict(endpoint=ENDPOINT, timelock=GOVERNOR, rpcEnv='AUDIT_TEST_RPC',
                    **{key: HASH for key in ('endpointCodeHash', 'coreCodeHash', 'timelockCodeHash',
                                            'assetCodeHash', 'wrappedCodeHash')})
        def fake_cast(command, value):
            self.assertEqual(command, 'keccak')
            return HASH if value == '0x6000' else value
        with patch.dict('os.environ', {'AUDIT_TEST_RPC': 'https://example.invalid'}), \
             patch('preflight.RPC', return_value=rpc), patch('preflight.cast', side_effect=fake_cast):
            return inspect(rpc.c, meta, {'endpoint': REMOTE}, phase)

    def test_valid_pinned_source_and_destination(self):
        for c in fixture():
            with self.subTest(sourceSide=c['sourceSide']):
                self.assertEqual(self.check(FakeRPC(c))['block'], PIN)

    def test_finalized_snapshot_required(self):
        rpc = FakeRPC(fixture()[0]); rpc.finalized = False
        with self.assertRaisesRegex(ValueError, 'finalized block'): self.check(rpc)

    def test_reorganized_snapshot_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.reorg = True
        with self.assertRaisesRegex(ValueError, 'pinned block changed'): self.check(rpc)

    def test_pending_ownership_migration_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'pendingOwner()', ()] = 123
        with self.assertRaisesRegex(ValueError, 'pendingOwner'): self.check(rpc)

    def test_unreviewed_governance_code_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.codes[GOVERNOR] = '0x6001'
        with self.assertRaisesRegex(ValueError, 'runtime hash mismatch'): self.check(rpc)

    def test_missing_cancellation_role_rejected(self):
        rpc = FakeRPC(fixture()[0])
        rpc.overrides[GOVERNOR, 'hasRole(bytes32,address)', ('CANCELLER_ROLE', rpc.c['governanceSafe'])] = 0
        with self.assertRaisesRegex(ValueError, 'governance role missing'): self.check(rpc)

    def test_open_executor_rejected_by_closed_role_policy(self):
        rpc = FakeRPC(fixture()[0])
        rpc.overrides[GOVERNOR, 'hasRole(bytes32,address)', ('EXECUTOR_ROLE', ZERO)] = 1
        with self.assertRaisesRegex(ValueError, 'open governance role'): self.check(rpc)

    def test_source_deficit_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[rpc.c['sourceAsset'], 'balanceOf(address)', (ENDPOINT,)] = 994
        with self.assertRaisesRegex(ValueError, 'backing deficit'): self.check(rpc)

    def test_unreviewed_asset_or_wrapped_code_rejected(self):
        for c in fixture():
            rpc = FakeRPC(c); rpc.codes[c['sourceAsset'] if c['sourceSide'] else WRAPPED] = '0x6001'
            with self.subTest(sourceSide=c['sourceSide']), self.assertRaisesRegex(ValueError, 'runtime hash mismatch'):
                self.check(rpc)

    def test_wrong_wrapped_origin_rejected(self):
        rpc = FakeRPC(fixture()[1]); rpc.overrides[WRAPPED, 'originToken()', ()] = 123
        with self.assertRaisesRegex(ValueError, 'wrapped origin mismatch'): self.check(rpc)

    def test_emergency_guardian_must_still_have_code(self):
        rpc = FakeRPC(fixture()[0]); rpc.codes[rpc.c['guardian']] = '0x'
        with self.assertRaisesRegex(ValueError, 'guardian contract missing'): self.check(rpc)

    def test_changed_fee_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'FEE_BPS()', ()] = 100
        with self.assertRaisesRegex(ValueError, 'FEE_BPS'): self.check(rpc)

    def test_unapproved_treasury_rotation_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'feeRecipient()', ()] = int('0x' + 'a' * 40, 16)
        with self.assertRaisesRegex(ValueError, 'feeRecipient'): self.check(rpc)

    def test_approved_rotated_treasury_matches_updated_configuration(self):
        c = fixture()[0]; c['treasury'] = '0x' + 'a' * 40
        rpc = FakeRPC(c)
        rpc.overrides[ENDPOINT, 'feeRecipient()', ()] = int(c['treasury'], 16)
        self.assertEqual(self.check(rpc)['block'], PIN)

    def test_unapproved_transfer_maximum_change_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'maxTransfer()', ()] = 20
        with self.assertRaisesRegex(ValueError, 'maxTransfer'): self.check(rpc)

    def test_unapproved_inbound_ceiling_change_rejected(self):
        rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'inboundMaxTransfer()', ()] = 20
        with self.assertRaisesRegex(ValueError, 'inboundMaxTransfer'): self.check(rpc)

    def test_approved_lowered_maximum_and_legacy_ceiling(self):
        for c in fixture():
            c['maxTransferRaw'] = '5'
            rpc = FakeRPC(c)
            self.assertEqual(self.check(rpc)['block'], PIN)

    def test_maintenance_accepts_only_outbound_paused_or_both_paused(self):
        for c in fixture():
            for mask in (1,3):
                rpc = FakeRPC(c); rpc.overrides[ENDPOINT, 'pausedLanes()', ()] = mask
                self.assertEqual(self.check(rpc, 'maintenance')['pausedLanes'], mask)

    def test_maintenance_rejects_open_outbound_and_invalid_masks(self):
        for mask in (0,2,4,255):
            rpc = FakeRPC(fixture()[0]); rpc.overrides[ENDPOINT, 'pausedLanes()', ()] = mask
            with self.subTest(mask=mask), self.assertRaisesRegex(ValueError, 'outbound paused'):
                self.check(rpc, 'maintenance')

    def test_active_phase_requires_fresh_metadata(self):
        rpc = FakeRPC(fixture()[1]); rpc.overrides[ENDPOINT, 'pausedLanes()', ()] = 0
        rpc.overrides[WRAPPED, 'metadataFresh()', ()] = 0
        with self.assertRaisesRegex(ValueError, 'stale wrapped metadata'): self.check(rpc, 'active')
