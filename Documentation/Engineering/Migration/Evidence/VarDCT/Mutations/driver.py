#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded deterministic mutation campaign; retain failures and exact seed hashes.

One invocation exercises one entry point for its own requested wall time.
This is mutation testing, not coverage-guided fuzzing or a security certification.
"""
import argparse
import hashlib
import json
import platform
import random
import resource
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--entry', choices=['inspect', 'decode', 'caller', 'pnm'], required=True)
p.add_argument('--seeds', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--seconds', type=float, default=3600)
p.add_argument('--seed', type=int, default=20261009)
a = p.parse_args()
if not 1 <= a.seconds <= 86400:
    p.error('--seconds must be 1..86400')
a.output.mkdir(parents=True, exist_ok=False)
rng = random.Random(a.seed)
suffixes = {'.pgm', '.ppm', '.pam'} if a.entry == 'pnm' else {'.jxl'}
seeds = [(p, p.read_bytes()) for p in sorted(a.seeds.rglob('*')) if p.suffix in suffixes]
if not seeds or any(len(data) > 1 << 20 for _, data in seeds):
    raise ValueError('Need non-empty conformant seed corpus, each at most 1 MiB')
sha = lambda data: hashlib.sha256(data).hexdigest()
report = {'status': 'preflight', 'entry': a.entry, 'requestedSeconds': a.seconds,
          'host': platform.platform(), 'python': platform.python_version(),
          'randomSeed': a.seed, 'binarySHA256': sha(a.binary.read_bytes()),
          'scriptSHA256': sha(Path(__file__).read_bytes()), 'preflight': [],
          'seeds': [{'path': str(p), 'sha256': sha(d), 'bytes': len(d)} for p, d in seeds],
          'iterations': 0, 'outcomes': {}, 'mutations': {}, 'elapsedSeconds': 0,
          'method': 'Fresh ASan process per input, 15-second outer timeout; deterministic PRNG and saved current input. Per-entry campaign clock starts after all conformant seeds are accepted. No coverage guidance.',
          'memoryNote': 'Child-process peak RSS includes sanitizer/runtime/startup. API and CLI additionally enforce resource admission; this is not peak algorithm workspace.'}
def save():
    temporary = a.output/'report.tmp'
    temporary.write_text(json.dumps(report, indent=2)+'\n')
    temporary.replace(a.output/'report.json')

def invoke(data):
    current = a.output/'current-input.bin'
    current.write_bytes(data)
    if a.entry == 'pnm':
        command = [str(a.binary), 'encode', '-i', str(current), '--input-format', 'pnm',
                   '--max-memory', str(128 << 20), '--timeout', '5']
    else:
        command = [str(a.binary), a.entry, str(current)]
    report['currentCommand'] = command
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except subprocess.TimeoutExpired as e:
        (a.output/'failure.bin').write_bytes(data)
        (a.output/'failure.stderr').write_bytes(e.stderr or b'')
        raise RuntimeError('Unresolved outer-timeout finding') from e
    stderr = result.stderr
    if a.entry == 'pnm':
        outcome = 'accepted' if result.returncode == 0 else f'rejected:exit-{result.returncode}'
        valid = result.returncode in [0, 2, 3, 4, 5, 7] and (result.returncode == 0 or not result.stdout)
    else:
        outcome = result.stdout.decode(errors='replace').strip()
        valid = result.returncode == 0 and (outcome == 'accepted' or outcome.startswith('rejected:'))
    if not valid or b'Sanitizer' in stderr or b'runtime error:' in stderr:
        (a.output/'failure.bin').write_bytes(data)
        (a.output/'failure.stderr').write_bytes(stderr)
        raise RuntimeError(f'Unexpected exit/diagnostic: {result.returncode}, {outcome[:100]}')
    return outcome

def mutate(source, iteration):
    data = bytearray(source)
    # Cycle operators so every campaign has all classes even with short duration.
    kind = iteration % 8
    pos = rng.randrange(len(data)+1)
    if kind == 0:
        for _ in range(rng.randint(1, 8)):
            if data: data[rng.randrange(len(data))] ^= 1 << rng.randrange(8)
    elif kind == 1:
        del data[pos:]
    elif kind == 2:
        data[pos:pos] = rng.randbytes(rng.randint(1, 64))
    elif kind == 3:
        del data[pos:pos+rng.randint(1, 64)]
    elif kind == 4:
        if data:
            start = rng.randrange(min(128, len(data)))
            length = min(rng.choice([1, 2, 4, 8]), len(data)-start)
            data[start:start+length] = bytes([rng.choice([0, 1, 127, 128, 254, 255])])*length
    elif kind == 5:
        data[pos:pos] = data[max(0, pos-64):pos]
    elif kind == 6:
        other = rng.choice(seeds)[1]
        data[pos:] = other[rng.randrange(len(other)+1):]
    else:
        # Periodically preserve a valid stream among malformed samples.
        if iteration % 32 != 7:
            data = bytearray(rng.randbytes(rng.randint(0, 512)))
    return bytes(data[:1 << 20]), str(kind)

save()
try:
    for path, data in seeds:
        outcome = invoke(data)
        report['preflight'].append({'path': str(path), 'outcome': outcome})
        save()
        if outcome != 'accepted':
            raise RuntimeError(f'Conformant seed did not reach successful {a.entry}: {path}, {outcome}')
    started = time.monotonic()
    last_saved = started
    report['status'] = 'running'
    save()
    while time.monotonic()-started < a.seconds:
        path, source = rng.choice(seeds)
        data, kind = mutate(source, report['iterations'])
        report['currentSeed'] = str(path)
        report['currentSHA256'] = sha(data)
        report['currentMutation'] = kind
        outcome = invoke(data)
        report['iterations'] += 1
        report['outcomes'][outcome] = report['outcomes'].get(outcome, 0)+1
        report['mutations'][kind] = report['mutations'].get(kind, 0)+1
        report['elapsedSeconds'] = time.monotonic()-started
        report['childPeakRSSNativeUnits'] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        if time.monotonic()-last_saved >= 1:
            save()
            last_saved = time.monotonic()
    report['status'] = 'passed'
except BaseException as error:
    report['status'] = 'failed'
    report['failure'] = repr(error)
    raise
finally:
    save()
print(f"{a.entry}: {report['iterations']} mutations in {report['elapsedSeconds']:.1f}s")
