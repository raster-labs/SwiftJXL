#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Inspect/validate low-precision fixtures without silently widening file output."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
fixtures = Path(__file__).resolve().parents[1]/'Tests/SwiftJXLCoreTests/Fixtures/Modular/LowPrecision'
report = {'status': 'running', 'binarySHA256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
          'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'checks': []}
def save():
    (a.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
def run(command, expected=0):
    r = subprocess.run([str(a.binary), *map(str, command)], capture_output=True, timeout=20)
    report['checks'].append({'command': list(map(str, command)), 'exit': r.returncode, 'expected': expected})
    assert r.returncode == expected, (command, r.returncode, r.stderr)
    if expected: assert not r.stdout
    return r.stdout
try:
    inputs = sorted(fixtures.glob('*.jxl'))
    assert len(inputs) == 28, 'Required independent fixture corpus is missing'
    for path in inputs:
        _, channels, bits = path.stem.split('-')
        for operation in ['inspect', 'validate']:
            info = json.loads(run([operation, '-i', path, '--json']))
            assert info['meaningfulBits'] == int(bits) and info['componentCount'] == int(channels)
            assert info['pixelPayloadValidated'] == (operation == 'validate')
        # Both boundary precisions and each component layout exercise rejection
        # of file adapters that cannot preserve these declared precisions.
        if int(bits) in [1, 7]:
            for fmt in ['pnm', 'pnm-srgb', 'nrrd']:
                run(['decode', '-i', path, '--output-format', fmt], expected=4)
    caps = json.loads(run(['capabilities', '--json']))
    assert 'inspect/validate 1..16' in caps['profile']
    assert caps['pnmMeaningfulBits'] == list(range(8, 17))
    report['status'] = 'passed'
except BaseException as error:
    report['status'] = 'failed'
    report['failure'] = repr(error)
    raise
finally:
    save()
print(f"Passed {len(report['checks'])} low-precision CLI checks")
