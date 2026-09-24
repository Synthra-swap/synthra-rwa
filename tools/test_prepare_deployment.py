import copy
from datetime import datetime, timezone, timedelta
from fractions import Fraction
import json
from pathlib import Path
import tempfile
import unittest

from deploy_asset import check_network, command, load, simulation_environment
from prepare_deployment import ROOT, build, make_pair, raw_amount

NOW = datetime(2026, 9, 24, 12, tzinfo=timezone.utc)


def fixture():
    source = {'evmChain': 4663, 'wormholeChain': 72, 'core': '0x' + '1' * 40,
              'governanceSafe': '0x' + '2' * 40, 'guardian': '0x' + '2' * 40,
              'treasury': '0x' + '3' * 40, 'deployer': '0x' + '4' * 40,
              'outboundConsistency': 0, 'inboundConsistency': 0}
    destination = dict(source, evmChain=5042, wormholeChain=71, core='0x' + '5' * 40)
    asset = {'symbol': 'AAPL', 'token': '0x' + '6' * 40, 'uid': '0x' + '7' * 64,
             'decimals': 18, 'currency': 'USD', 'isTradingHalt': False,
             'registryStatus': 'ASSET_STATUS_ACTIVE', 'registryMultiplier': '4',
             'multiplierRaw': str(4 * 10**18), 'quoteBidUsd': '99', 'quoteAskUsd': '100',
             'quoteGeneratedAt': NOW.isoformat(), 'multiplierObservedAt': NOW.isoformat(),
             'wrappedName': 'Synthra Wrapped AAPL', 'wrappedSymbol': 'sAAPL'}
    return {'source': source, 'destination': destination, 'referenceLimitUsd': '100000',
            'referenceTestUsd': '10', 'amountPolicyApproved': True,
            'governanceDelaySeconds': 172800, 'metadataMaxAgeSeconds': 2592000, 'assets': [asset]}


class DeploymentPreparationTests(unittest.TestCase):
    def test_split_multiplier_applied_once_and_rounding_never_exceeds_reference(self):
        self.assertEqual(raw_amount('100000', '100', str(4 * 10**18)), 250 * 10**18)
        multiplier = 1000775159164630595
        result = raw_amount('10', '223.29', str(multiplier))
        unit_value = Fraction('223.29') * multiplier / 10**36
        self.assertLessEqual(result * unit_value, 10)
        self.assertGreater((result + 1) * unit_value, 10)

    def test_invalid_financial_numbers_rejected(self):
        for value in (0, 1.5, True, 'NaN', 'Infinity', '-1', '1e6', '0'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                raw_amount(value, '100', str(10**18))
        for value in ('0', str(2**256), 1.1):
            with self.subTest(value=value), self.assertRaises(ValueError):
                raw_amount('10', '100', value)

    def test_fee_rounding_and_paired_governance(self):
        plan = fixture()
        configs, amounts = make_pair(plan, plan['assets'][0], NOW)
        self.assertEqual(configs[0]['maxTransferRaw'], configs[1]['maxTransferRaw'])
        self.assertEqual(configs[0]['guardian'], configs[0]['governanceSafe'])
        self.assertNotEqual(configs[0]['guardian'], plan['source']['deployer'])
        self.assertEqual(int(amounts['testGrossRaw']), 25 * 10**15)
        self.assertEqual(int(amounts['testFeeRaw']), 125 * 10**12)
        self.assertEqual(int(amounts['testNetRaw']) + int(amounts['testFeeRaw']), int(amounts['testGrossRaw']))

    def test_stale_future_and_unzoned_observations_rejected(self):
        for field in ('quoteGeneratedAt', 'multiplierObservedAt'):
            for value in ((NOW - timedelta(days=2)).isoformat(),
                          (NOW + timedelta(minutes=6)).isoformat(), '2026-09-24T12:00:00'):
                plan = fixture(); plan['assets'][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    make_pair(plan, plan['assets'][0], NOW)

    def test_wrong_price_units_halt_multiplier_and_domain_rejected(self):
        for field, value in (('currency', 'EUR'), ('isTradingHalt', True),
                             ('registryMultiplier', '1'), ('quoteBidUsd', '101'),
                             ('decimals', 6), ('registryStatus', 'ASSET_STATUS_INACTIVE')):
            plan = fixture(); plan['assets'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                make_pair(plan, plan['assets'][0], NOW)
        plan = fixture(); plan['destination']['evmChain'] = 4663
        with self.assertRaises(ValueError): make_pair(plan, plan['assets'][0], NOW)

    def temporary_root(self, root):
        for path in ('config/pair.example.json', 'tools/prepare_deployment.py', 'tools/deploy_asset.py',
                     'tools/preflight.py', 'tools/rpc_policy.py', 'foundry.toml'):
            target = root / path; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / path).read_bytes())
        return root / 'config/deployments/test'

    def test_bundle_preserves_inputs_and_blocks_modified_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); output = self.temporary_root(root)
            bundle = build(fixture(), output, root=root, now=NOW)
            entry, config = load(output / 'bundle.json', 'AAPL', 'source', root=root)
            self.assertEqual(config['treasury'], fixture()['source']['treasury'])
            target = root / entry['source']['deployment']
            target.write_text(target.read_text().replace('250000000000000000000', '999000000000000000000'))
            with self.assertRaisesRegex(ValueError, 'changed bundle input'):
                load(output / 'bundle.json', 'AAPL', 'source', root=root)
            self.assertIn('tools/deploy_asset.py', bundle['buildInputsSha256'])
            self.assertIn('tools/rpc_policy.py', bundle['buildInputsSha256'])

    def test_modified_tools_block_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); output = self.temporary_root(root)
            build(fixture(), output, root=root, now=NOW)
            (root / 'tools/deploy_asset.py').write_text('# changed')
            with self.assertRaisesRegex(ValueError, 'changed bundle input'):
                load(output / 'bundle.json', 'AAPL', 'source', root=root)

    def test_rebuild_cannot_overwrite_existing_deployment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); output = self.temporary_root(root)
            build(fixture(), output, root=root, now=NOW)
            with self.assertRaisesRegex(ValueError, 'already exists'):
                build(fixture(), output, root=root, now=NOW)

    def test_duplicate_asset_or_bad_later_asset_writes_no_partial_bundle(self):
        for duplicate in (True, False):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); output = self.temporary_root(root); plan = fixture()
                plan['assets'].append(copy.deepcopy(plan['assets'][0]))
                if not duplicate:
                    plan['assets'][1].update(symbol='NVDA', wrappedSymbol='sNVDA', token='0x'+'9'*40,
                                             multiplierRaw='0')
                with self.assertRaises(ValueError): build(plan, output, root=root, now=NOW)
                self.assertFalse(output.exists())

    def test_unapproved_amounts_and_path_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); output = self.temporary_root(root); plan = fixture()
            plan['amountPolicyApproved'] = False
            with self.assertRaisesRegex(ValueError, 'not approved'): build(plan, output, root=root, now=NOW)
            plan = fixture(); plan['assets'][0]['symbol'] = '../../escape'
            with self.assertRaises(ValueError): build(plan, output, root=root, now=NOW)
            with self.assertRaisesRegex(ValueError, 'under config/deployments'):
                build(fixture(), root / 'other', root=root, now=NOW)

    def test_default_foundry_command_cannot_broadcast(self):
        cmd = command({}, '0x'+'4'*40, 'https://example.invalid')
        self.assertIn('--sender', cmd)
        for unsafe in ('--broadcast', '--unlocked', '--resume', '--skip-simulation', '--private-key'):
            self.assertNotIn(unsafe, cmd)

    def test_inherited_compiler_overrides_and_signer_removed_from_simulation(self):
        env = simulation_environment({'PATH': '/bin', 'DEPLOYER_PRIVATE_KEY': 'secret',
                                      'FOUNDRY_EVM_VERSION': 'paris', 'FOUNDRY_OPTIMIZER': 'false',
                                      'DAPP_SOLC': 'other', 'SOURCE_RPC_URL': 'https://example.invalid'},
                                     'config/source.json', ROOT / '.tools/test')
        self.assertNotIn('DEPLOYER_PRIVATE_KEY', env)
        self.assertNotIn('FOUNDRY_OPTIMIZER', env)
        self.assertNotIn('FOUNDRY_EVM_VERSION', env)
        self.assertNotIn('DAPP_SOLC', env)
        self.assertEqual(env['FOUNDRY_PROFILE'], 'deployment')

    def test_wrong_network_rejected_before_contract_reads(self):
        class WrongRPC:
            def request(self, method, params):
                if method != 'eth_chainId': raise AssertionError('unexpected read')
                return hex(1)
        with self.assertRaisesRegex(ValueError, 'wrong chain'):
            check_network(WrongRPC(), {'evmChain': 4663}, {}, 'source')


if __name__ == '__main__':
    unittest.main()
