#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run mandatory independent-codec tests; missing tools/skipped tests fail the gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'status': 'running', 'tools': [], 'test_runs': []}
    env = dict(os.environ, SWIFTJXL_ORACLE_BIN=str(args.tools.resolve()),
               SWIFTJXL_ORACLE_OUTPUT=str(output / 'fixtures'))

    def run(label, command):
        print(label, flush=True)
        result = subprocess.run(command, cwd=repo, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=900)
        (output / (label + '.log')).write_text(result.stdout)
        if result.returncode:
            print(result.stdout[-8000:], file=sys.stderr)
            raise RuntimeError(f'{label}: exit {result.returncode}')
        return result.stdout

    try:
        for name in ('cjxl', 'djxl'):
            path = (args.tools / name).resolve()
            version = run(name + '-version', [str(path), '--version']).strip()
            if not re.search(r'\bv0\.12\.0\b', version):
                raise RuntimeError(f'{name}: expected the qualified 0.12.0 oracle')
            report['tools'].append({'name': name, 'version': version,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        report['swift'] = run('swift-version', ['swift', '--version']).strip()
        report['commit'] = run('source-commit', ['git', '-c', f'safe.directory={repo}', 'rev-parse', 'HEAD']).strip()
        sources = [repo / 'Package.swift'] + sorted((repo / 'Sources').rglob('*.swift')) + sorted((repo / 'Tests').rglob('*.swift'))
        report['source_sha256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        manifest = (repo / 'Package.swift').read_text()
        modules = set(re.findall(r'\.testTarget\s*\(\s*name:\s*"([^"]+)"', manifest))
        for config in ('debug', 'release'):
            command = ['swift', 'test', '-c', config, '--jobs', '2']
            listing = run(config + '-discovery', command + ['list'])
            names = [line for line in listing.splitlines() if line.split('.', 1)[0] in modules]
            if not names:
                raise RuntimeError('No tests discovered')
            xml = output / (config + '-tests.xml')
            log = run(config + '-tests', command + ['--skip-build', '--xunit-output', str(xml)])
            cases = ET.parse(xml).findall('.//testcase')
            failed = sum(c.find('failure') is not None or c.find('error') is not None for c in cases)
            skipped = sum(c.find('skipped') is not None for c in cases)
            record = {'configuration': config, 'discovered': len(names), 'executed': len(cases),
                      'failed': failed, 'skipped': skipped}
            report['test_runs'].append(record)
            if len(cases) != len(names) or failed or skipped:
                raise RuntimeError(f'{config}: missing, failing or skipped tests')
            if 'independentBothDirections' not in log or 'with 5 test cases passed' not in log:
                raise RuntimeError(f'{config}: independent oracle did not execute all precisions')
        fixtures = sorted((output / 'fixtures').rglob('*-oracle.jxl'))
        if len(fixtures) != 50:
            raise RuntimeError('Expected 25 reference fixtures in each configuration')
        report['fixture_sha256'] = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((output / 'fixtures').rglob('*')) if p.is_file()}
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['failure'] = str(error)
        print(error, file=sys.stderr)
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
