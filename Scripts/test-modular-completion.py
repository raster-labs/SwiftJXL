#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the bounded Modular group/layout matrix with required independent oracles.

Sanitizers use optimised code: unoptimised instrumentation of the 4097-square
case is slow enough to obscure this correctness gate. Resource limits and test
assertions are identical. Each output directory must be new.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--configuration', choices=['debug', 'release', 'asan', 'tsan'], required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--scratch-path', type=Path, required=True)
p.add_argument('--oracle-bin', type=Path, required=True, help='Directory containing pinned cjxl and djxl')
p.add_argument('--profile-oracle', type=Path, required=True, help='Compiled modular-profile-oracle.c')
p.add_argument('--timeout', type=int, default=1800)
a = p.parse_args()
if a.timeout <= 0:
    p.error('Timeout must be positive')
repo = Path(__file__).resolve().parents[1]
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
tools = [a.oracle_bin.resolve() / name for name in ['cjxl', 'djxl']] + [a.profile_oracle.resolve()]
if not all(path.is_file() and os.access(path, os.X_OK) for path in tools):
    p.error('All three independent oracle executables are required')
scratch = a.scratch_path.resolve()
cmd = (['xcrun', 'swift'] if sys.platform == 'darwin' else ['swift']) + [
    'test', '-c', 'debug' if a.configuration == 'debug' else 'release',
    '--disable-sandbox', '--scratch-path', str(scratch), '--jobs', '2',
    '--no-parallel', '--enable-swift-testing', '--disable-xctest',
    '--xunit-output', str(out / 'tests.xml'), '--filter',
    'ModularGroupBoundaryTests|ModularPublicMatrixTests|ModularProfileTests|ModularProfileLifetimeTests']
if sys.platform == 'darwin':
    cmd += ['--build-system', 'swiftbuild']
if a.configuration in ['asan', 'tsan']:
    cmd += ['--sanitize', 'address' if a.configuration == 'asan' else 'thread']
env = dict(os.environ, SWIFTJXL_ORACLE_BIN=str(a.oracle_bin.resolve()),
           SWIFTJXL_PROFILE_ORACLE=str(a.profile_oracle.resolve()),
           SWIFTJXL_ORACLE_OUTPUT=str(out / 'oracle'))
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
hashes = {str(path.relative_to(repo)): digest(path)
          for directory in ['Sources', 'Tests'] for path in (repo / directory).rglob('*.swift')}
report = {'configuration': a.configuration, 'command': cmd, 'sourceHashes': hashes,
          'oracleHashes': {str(path): digest(path) for path in tools}, 'status': 'running'}
def save():
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
save()
start = time.monotonic()
with (out / 'tests.log').open('w') as log:
    process = subprocess.Popen(cmd, cwd=repo, env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        report['exit'] = process.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        report['timedOutAfterSeconds'] = a.timeout
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        report['exit'] = process.returncode
report['seconds'] = time.monotonic() - start
report['sourceUnchanged'] = all(digest(repo / path) == value for path, value in hashes.items())
if (out / 'tests.xml').exists():
    tree = ET.parse(out / 'tests.xml').getroot()
    report['xml'] = {name: len(list(tree.iter(tag))) for name, tag in
                     [('declarations', 'testcase'), ('failures', 'failure'),
                      ('errors', 'error'), ('skips', 'skipped')]}
report['caseExecutions'] = len(re.findall(r'Test case passing \d+ arguments? .* to ',
                                         (out / 'tests.log').read_text()))
report['profileOracles'] = len(list((out / 'oracle').glob('public-matrix-*/oracle.json')))
report['independentEncodes'] = len(list((out / 'oracle').glob('group-reference-*/reference.jxl')))
report['oracleOutputs'] = len(list((out / 'oracle').glob('*/oracle.pam')))
passed = (report['exit'] == 0 and 'timedOutAfterSeconds' not in report and report['sourceUnchanged']
          and report.get('xml') == dict(declarations=7, failures=0, errors=0, skips=0)
          and report['caseExecutions'] == 541 and report['profileOracles'] == 432
          and report['independentEncodes'] == 15 and report['oracleOutputs'] == 89)
report['status'] = 'passed' if passed else 'failed'
save()
print(json.dumps({key: value for key, value in report.items()
                  if key not in ['sourceHashes', 'oracleHashes', 'command']}))
sys.exit(0 if passed else 1)
