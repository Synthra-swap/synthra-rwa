import copy
import unittest
from check_slither import fingerprint, validate


class SlitherGateTests(unittest.TestCase):
    def setUp(self):
        self.finding = {'check': 'timestamp', 'impact': 'Low', 'elements': [
            {'type': 'function', 'name': 'publishMetadata', 'source_mapping': {'filename_relative': 'src/SourceVault.sol'}},
            {'type': 'node', 'name': 'effective <= block.timestamp'},
        ]}
        self.reviewed = [fingerprint(self.finding)]

    def report(self, finding):
        return {'success': True, 'results': {'detectors': [finding]}}

    def test_reviewed_finding_passes(self):
        self.assertEqual(validate(self.report(self.finding), self.reviewed), 1)

    def test_same_detector_in_new_function_fails(self):
        changed = copy.deepcopy(self.finding)
        changed['elements'][0]['name'] = 'unsafeNewFunction'
        with self.assertRaisesRegex(ValueError, 'Unreviewed'): validate(self.report(changed), self.reviewed)

    def test_new_expression_in_reviewed_function_fails(self):
        changed = copy.deepcopy(self.finding)
        changed['elements'][1]['name'] = 'block.timestamp % 2 == 0'
        with self.assertRaisesRegex(ValueError, 'Unreviewed'): validate(self.report(changed), self.reviewed)

    def test_medium_never_allowlisted(self):
        changed = copy.deepcopy(self.finding); changed['impact'] = 'Medium'
        with self.assertRaisesRegex(ValueError, 'High/Medium'):
            validate(self.report(changed), [fingerprint(changed)])

    def test_failed_or_incomplete_analysis_fails_closed(self):
        for report in ({'success': False}, {'success': True}, {}):
            with self.subTest(report=report), self.assertRaises(ValueError): validate(report, self.reviewed)
