#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Recheck retained coefficients with a required independent libjpeg executable."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--oracle', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
fixtures = root / 'Tests/SwiftJXLCoreTests/Fixtures/JPEG'
oracle = args.oracle.resolve()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
version = subprocess.run([str(oracle), '--version'], check=True, capture_output=True, timeout=10).stdout.decode().strip()
report = {'oracle': str(oracle), 'version': version, 'oracleSHA256': sha(oracle),
          'oracleSourceSHA256': sha(root / 'Scripts/TestSupport/jpeg-coefficient-oracle.c'), 'checks': []}
args.output.mkdir(parents=True, exist_ok=False)
manifest = json.loads((fixtures / 'manifest.json').read_text())
for fixture in manifest['fixtures']:
    source = fixtures / (fixture['name'] + '.jpg')
    expected = source.with_suffix('.json')
    if sha(source) != fixture['source_sha256'] or sha(expected) != fixture['coefficient_sha256']:
        raise RuntimeError('Fixture hash mismatch: ' + fixture['name'])
    process = subprocess.run([str(oracle), str(source)], check=True, capture_output=True, timeout=30)
    actual = json.loads(process.stdout)
    if actual != json.loads(expected.read_text()):
        raise RuntimeError('Independent coefficient mismatch: ' + fixture['name'])
    report['checks'].append({'fixture': fixture['name'], 'sourceSHA256': fixture['source_sha256'],
                             'coefficientSHA256': fixture['coefficient_sha256'],
                             'coefficientCount': sum(len(c['coefficients']) for c in actual['components']),
                             'passed': True})
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"All {len(report['checks'])} independent coefficient snapshots match {version}.")
