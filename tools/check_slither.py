#!/usr/bin/env python3
"""Accept only the specific reviewed locations and expressions, not an entire detector class."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fingerprint(finding):
    function = next(element for element in finding['elements'] if element['type'] == 'function')
    return {
        'check': finding['check'], 'impact': finding['impact'],
        'file': function['source_mapping']['filename_relative'], 'function': function['name'],
        'nodes': sorted(element['name'] for element in finding['elements'] if element['type'] == 'node'),
    }


def validate(report, reviewed):
    if report.get('success') is not True:
        raise ValueError('Slither did not finish successfully')
    findings = report.get('results', {}).get('detectors')
    if not isinstance(findings, list):
        raise ValueError('Missing Slither detector results')
    for finding in findings:
        if finding.get('impact') in ('High', 'Medium'):
            raise ValueError('High/Medium static-analysis finding')
        try:
            known = fingerprint(finding) in reviewed
        except (KeyError, StopIteration):
            known = False
        if not known:
            raise ValueError(f"Unreviewed static-analysis finding: {finding.get('check')}")
    return len(findings)


def main():
    report = json.loads((ROOT / 'audit/slither.json').read_text())
    reviewed = json.loads((ROOT / 'tools/slither-reviewed.json').read_text())
    count = validate(report, reviewed)
    print(f'Slither: no high/medium findings; {count} findings match reviewed locations and expressions')


if __name__ == '__main__':
    main()
