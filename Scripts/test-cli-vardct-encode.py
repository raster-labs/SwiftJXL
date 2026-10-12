#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Qualify explicit lossy CLI selection, controls, precision, alpha and rejection."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
report = {'status': 'running', 'binarySHA256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
          'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'checks': []}
def run(args, data=b'', expected=0):
    result = subprocess.run([str(a.binary.resolve()), *args], input=data, capture_output=True, timeout=60)
    assert result.returncode == expected, (args, result.returncode, result.stderr)
    if expected:
        assert not result.stdout
    return result
try:
    caps = json.loads(run(['capabilities', '--json']).stdout)
    assert caps['encodeModes'] == ['lossless', 'lossy']
    for bits in range(8, 17):
        for channels in (1, 2, 3, 4):
            w, h = 17, 9
            maximum = (1 << bits) - 1
            samples = [((i * 37 + i // channels * 13) % 256) * (maximum // 255)
                       for i in range(w * h * channels)]
            tuple_type = ('GRAYSCALE', 'GRAYSCALE_ALPHA', 'RGB', 'RGB_ALPHA')[channels - 1]
            header = f'P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {channels}\nMAXVAL {maximum}\nTUPLTYPE {tuple_type}\nENDHDR\n'.encode()
            raw = bytes(samples) if bits == 8 else struct.pack('>' + 'H' * len(samples), *samples)
            source = header + raw
            for toggle in ('on', 'off'):
                encoded = run(['encode', '-i', '-', '--input-format', 'pnm-srgb', '--mode', 'lossy',
                               '--distance', '1', '--gaborish', toggle, '--adaptive-quantisation', toggle,
                               '--dc-smoothing', toggle, '--json'], source)
                assert json.loads(encoded.stderr)['fidelity'] == 'lossy'
                run(['validate', '-i', '-'], encoded.stdout)
                decoded = run(['decode', '-i', '-', '--output-format', 'pnm-srgb', '--json'], encoded.stdout)
                assert json.loads(decoded.stderr)['fidelity'] == 'lossy'
                # Output chooses P5/P6 for images without alpha, P7 otherwise.
                if channels % 2 == 0:
                    assert decoded.stdout.startswith(header)
                    data = decoded.stdout[len(header):]
                    actual = list(data) if bits == 8 else [x[0] for x in struct.iter_unpack('>H', data)]
                    assert actual[channels-1::channels] == samples[channels-1::channels]
                report['checks'].append({'bits': bits, 'channels': channels, 'controls': toggle,
                                         'encodedBytes': len(encoded.stdout), 'exactAlpha': channels % 2 == 0})
            default = run(['encode', '-i', '-', '--input-format', 'pnm-srgb', '--json'], source)
            assert json.loads(default.stderr)['fidelity'] == 'exact-samples'
            run(['encode', '-i', '-', '--input-format', 'pnm', '--mode', 'lossy'], source, 4)
    for distance in ('0', 'nan', 'inf', '1e100', 'invalid'):
        run(['encode', '-i', '/nonexistent', '--input-format', 'pnm-srgb', '--mode', 'lossy', '--distance', distance], expected=2)
    for key in ('--distance', '--gaborish', '--adaptive-quantisation', '--dc-smoothing'):
        value = '1' if key == '--distance' else 'off'
        for command in ('encode', 'decode', 'inspect', 'validate', 'transcode'):
            run([command, '-i', '/nonexistent', key, value], expected=2)
    for key in ('--gaborish', '--adaptive-quantisation', '--dc-smoothing'):
        run(['encode', '-i', '/nonexistent', '--mode', 'lossy', key, 'false'], expected=2)
    run(['encode', '-i', '/nonexistent', '--mode', 'lossy', '--max-error', '1'], expected=2)
    # A low meaningful precision is never silently widened for lossy encoding.
    source = b'P5\n1 1\n127\n\x40'
    run(['encode', '-i', '-', '--input-format', 'pnm-srgb', '--mode', 'lossy'], source, 4)
    report['status'] = 'passed'
except BaseException as error:
    report.update(status='failed', error=str(error))
    raise
finally:
    (a.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
