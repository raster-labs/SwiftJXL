#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise public VarDCT CLI decoding and faithful reports against pinned scalar references."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
fixtures = Path(__file__).resolve().parents[1] / 'Tests/SwiftJXLCoreTests/Fixtures/VarDCT'
report = {'status': 'running', 'binarySHA256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
          'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'scope': 'Separate scalar Float32/nearest integer corpus. Original NEON differences remain open.', 'checks': []}
def save():
    (a.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
def run(command, data, expected=0):
    result = subprocess.run([str(a.binary.resolve()), *command], input=data, capture_output=True, timeout=20)
    assert result.returncode == expected, (command, result.returncode, result.stderr)
    if expected:
        assert not result.stdout
    return result
try:
    for path in sorted(fixtures.glob('pred-*.jxl')):
        name = path.stem
        _, w, c, b = name.removesuffix('.independent').split('-')
        w, c, b = int(w), int(c), int(b)
        h = 9 if w == 17 else 64
        data = path.read_bytes()
        for command in ['inspect', 'validate']:
            metadata = json.loads(run([command, '-i', '-', '--json'], data).stdout)
            assert metadata['width'] == w and metadata['height'] == h
        result = run(['decode', '-i', '-', '--output-format', 'pnm-srgb', '--json'], data)
        metadata = json.loads(result.stderr)
        assert metadata['fidelity'] == 'lossy' and metadata['componentCount'] == c
        if c % 2:
            header = f'P{5 if c == 1 else 6}\n{w} {h}\n{(1 << b)-1}\n'.encode()
        else:
            header = f'P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {c}\nMAXVAL {(1 << b)-1}\nTUPLTYPE {"GRAYSCALE_ALPHA" if c == 2 else "RGB_ALPHA"}\nENDHDR\n'.encode()
        assert result.stdout.startswith(header)
        payload = result.stdout[len(header):]
        assert len(payload) == w * h * c * (b // 8)
        actual = list(payload) if b == 8 else [v[0] for v in struct.iter_unpack('>H', payload)]
        oracle = path.with_suffix('.scalar-oracle').read_bytes()
        expected = [math.floor(min(1, max(0, x[0])) * ((1 << b)-1) + 0.5)
                    for x in struct.iter_unpack('<f', oracle)]
        assert len(actual) == len(expected)
        errors = []
        for i, (x, y) in enumerate(zip(actual, expected)):
            if c % 2 == 0 and i % c == c - 1:
                assert x == y
            else:
                errors.append(abs(x-y))
        peak, rms = max(errors), math.sqrt(sum(x*x for x in errors)/len(errors))
        assert peak <= 2 and rms <= 0.5
        # Conventional PNM requests BT.709; silently relabelling sRGB is forbidden.
        run(['decode', '-i', '-', '--output-format', 'pnm'], data, expected=4)
        report['checks'].append({'fixture': name, 'sourceSHA256': hashlib.sha256(data).hexdigest(),
                                 'oracleSHA256': hashlib.sha256(oracle).hexdigest(), 'peak': peak, 'rms': rms,
                                 'inspect': True, 'validate': True, 'lossyReport': True,
                                 'exactAlpha': True, 'transferMismatchRejected': True})
        save()
    assert len(report['checks']) == 32
    modular = fixtures.parent / 'Modular/Transfer/bt709-3-8.jxl'
    result = run(['decode', '-i', '-', '--output-format', 'pnm', '--json'], modular.read_bytes())
    assert json.loads(result.stderr)['fidelity'] == 'exact-samples'
    report['modularFidelityRegression'] = {'sourceSHA256': hashlib.sha256(modular.read_bytes()).hexdigest(), 'passed': True}
    report['status'] = 'passed'
except BaseException as error:
    report.update(status='failed', error=str(error))
    raise
finally:
    save()
