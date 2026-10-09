#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Require independent JPEG reconstruction for authored scan-event vectors."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tools', type=Path, required=True)
parser.add_argument('--coefficient-oracle', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
fixtures = root / 'Tests/SwiftJXLCoreTests/Fixtures/JPEGEvents'
args.output.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
report = {'status': 'running', 'tools': {}, 'checks': []}
for name in ['cjxl', 'djxl']:
    executable = args.tools.resolve() / name
    version = subprocess.run([str(executable), '--version'], check=True, capture_output=True, timeout=10)
    report['tools'][name] = {'sha256': sha(executable), 'version': (version.stdout + version.stderr).decode().strip()}
entries = json.loads((fixtures / 'manifest.json').read_text())['fixtures']
large = json.loads((fixtures / 'large-eob.json').read_text())
entries.append({'name': large['fixture'], 'jpegSHA256': large['jpeg_sha256'], 'jbrdSHA256': large['jbrd_sha256']})
for entry in entries:
    name = entry['name']
    source = fixtures / (name + '.jpg')
    bundle = fixtures / (name + '.jbrd')
    assert sha(source) == entry['jpegSHA256'] and sha(bundle) == entry['jbrdSHA256'], name
    encoded = args.output / (name + '.jxl')
    restored = args.output / (name + '.jpg')
    commands = [[str(args.tools.resolve() / 'cjxl'), str(source), str(encoded), '--lossless_jpeg=1', '-e', '3'],
                [str(args.tools.resolve() / 'djxl'), str(encoded), str(restored)]]
    for command in commands:
        subprocess.run(command, check=True, capture_output=True, timeout=30)
    assert restored.read_bytes() == source.read_bytes(), name
    data = encoded.read_bytes()
    position = 12
    bundles = []
    while position < len(data):
        assert len(data) - position >= 8
        size = int.from_bytes(data[position:position + 4], 'big')
        assert 8 <= size <= len(data) - position
        if data[position + 4:position + 8] == b'jbrd':
            bundles.append(data[position + 8:position + size])
        position += size
    assert bundles == [bundle.read_bytes()], name
    report['checks'].append({'name': name, 'byteExactRestoration': True,
                             'reconstructionBundleMatches': True, 'commands': commands,
                             'jpegSHA256': sha(source), 'jbrdSHA256': sha(bundle)})
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
report['status'] = 'passed'
# The refinement-tail vector is valid JPEG (libjpeg yields zero coefficients)
# but libjxl cannot preserve its redundant codewords in standard JBRD.
source = fixtures / 'refinement-extra-zero-unsupported.jpg'
assert sha(source) == json.loads((fixtures / 'manifest.json').read_text())['unsupportedFixture']['jpegSHA256']
oracle = args.coefficient_oracle.resolve()
decoded = subprocess.run([str(oracle), str(source)], check=True, capture_output=True, timeout=30)
coefficients = json.loads(decoded.stdout)
assert (coefficients['width'], coefficients['height']) == (32, 8)
assert all(value == 0 for component in coefficients['components'] for value in component['coefficients'])
command = [str(args.tools.resolve() / 'cjxl'), str(source), str(args.output / 'unsupported.jxl'), '--lossless_jpeg=1', '-e', '3']
rejected = subprocess.run(command, capture_output=True, timeout=30)
assert rejected.returncode != 0
report['unsupportedRefinementTail'] = {'jpegSHA256': sha(source), 'coefficientOracleSHA256': sha(oracle),
    'independentJPEGDecodePassed': True, 'referenceReconstructionExit': rejected.returncode, 'command': command}
(args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"All {len(report['checks'])} independent JPEG scan-event fixtures passed.")
