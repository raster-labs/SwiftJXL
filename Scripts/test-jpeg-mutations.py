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
p.add_argument('--entry', choices=['jpeg-inspect', 'jpeg-decode', 'jpeg-caller'], required=True)
p.add_argument('--seeds', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--source-root', type=Path, required=True)
p.add_argument('--build-record', type=Path, required=True)
p.add_argument('--seconds', type=float, default=3600)
p.add_argument('--seed', type=int, default=20261009)
a = p.parse_args()
if not 1 <= a.seconds <= 86400:
    p.error('--seconds must be 1..86400')
a.output.mkdir(parents=True, exist_ok=False)
rng = random.Random(a.seed)
suffixes = {'.jpg', '.jpeg'}
seeds = [(p, p.read_bytes()) for p in sorted(a.seeds.rglob('*')) if p.suffix in suffixes]
if not seeds or any(len(data) > 1 << 20 for _, data in seeds):
    raise ValueError('Need non-empty conformant seed corpus, each at most 1 MiB')
sha = lambda data: hashlib.sha256(data).hexdigest()
def source_hashes():
    return {str(p.relative_to(a.source_root)): sha(p.read_bytes())
            for p in [*sorted((a.source_root/'Sources').rglob('*.swift')), *sorted((a.source_root/'Tests').rglob('*.swift')), a.source_root/'Package.swift',
                      a.source_root/'Scripts/TestSupport/jpeg-mutation-probe.swift']}
build = json.loads(a.build_record.read_text())
if build['binarySHA256'] != sha(a.binary.read_bytes()) or build['sourceSHA256'] != source_hashes():
    raise ValueError('Build record does not match current binary and source')
if build.get('sanitizer') != 'address' or build.get('exitCode') != 0 or not build.get('sourcesUnchanged') or not build.get('objectsUnchanged') or not build.get('baselineInputsUnchanged') or not build.get('canarySelfTest',{}).get('passed'):
    raise ValueError('An AddressSanitizer build is required')
manifest_path = a.seeds/'manifest.json'
manifest_bytes = manifest_path.read_bytes()
manifest_rows = json.loads(manifest_bytes)
manifest = {x['name']: x for x in manifest_rows}
expected_modes = {'srgb', 'embedded-preserve', 'embedded-apply',
                  'srgb-discard', 'embedded-preserve-discard', 'embedded-apply-discard'}
if len(seeds) != 144 or len(manifest_rows) != 144 or len(manifest) != 144 or {p.stem for p, _ in seeds} != set(manifest):
    raise ValueError('Qualification requires exactly 144 distinct manifest-bound seeds')
for path, data in seeds:
    row = manifest[path.stem]
    if row['jpegSHA256'] != sha(data) or row['interpretation'] not in ('srgb', 'embedded-preserve', 'embedded-apply'):
        raise ValueError('Seed hash or interpretation mismatch: ' + str(path))
last_outcomes = []
report = {'status': 'preflight', 'buildRecord': build,
          'startedAtUTC': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat(),
          'coverage': {'guidance': 'deterministic mutation, no measured branch coverage',
                       'interpretations': ['explicit-srgb', 'embedded-preserve', 'embedded-apply'],
                       'metadataPolicies': ['preserve', 'discardAncillary'],
                       'operators': ['bit-flip', 'truncate', 'insert', 'delete', 'JPEG-marker-length', 'duplicate', 'splice', 'random-or-valid' ]}, 'entry': a.entry, 'requestedSeconds': a.seconds,
          'host': platform.platform(), 'python': platform.python_version(),
          'randomSeed': a.seed, 'binarySHA256': sha(a.binary.read_bytes()),
          'scriptSHA256': sha(Path(__file__).read_bytes()), 'seedManifestSHA256': sha(manifest_bytes), 'preflight': [],
          'seeds': [{'path': str(p), 'sha256': sha(d), 'bytes': len(d)} for p, d in seeds],
          'iterations': 0, 'outcomes': {}, 'mutations': {}, 'elapsedSeconds': 0,
          'method': 'Fresh ASan process per input, 25-second outer timeout; deterministic PRNG and saved current input. Per-entry campaign clock starts after all conformant seeds are accepted. No coverage guidance.',
          'memoryNote': 'Child-process peak RSS includes sanitizer/runtime/startup. API and CLI additionally enforce resource admission; this is not peak algorithm workspace.'}
def save():
    temporary = a.output/'report.tmp'
    temporary.write_text(json.dumps(report, indent=2)+'\n')
    temporary.replace(a.output/'report.json')

def invoke(data):
    global last_outcomes
    current = a.output/'current-input.bin'
    current.write_bytes(data)
    command = [str(a.binary), a.entry, str(current)]
    report['currentCommand'] = command
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    except subprocess.TimeoutExpired as e:
        (a.output/'failure.bin').write_bytes(data)
        (a.output/'failure.stderr').write_bytes(e.stderr or b'')
        raise RuntimeError('Unresolved outer-timeout finding') from e
    stderr = result.stderr
    try:
        payload = json.loads(result.stdout)
        last_outcomes = payload['outcomes']
        valid = (result.returncode == 0 and payload['status'] in ['accepted', 'rejected']
                 and len(last_outcomes) == 6
                 and {item['interpretation'] for item in last_outcomes} == expected_modes
                 and all(item['status'] in ('accepted', 'rejected') for item in last_outcomes)
                 and all(isinstance(item.get('category'), str) and item['category'] != 'internalFailure'
                         for item in last_outcomes if item['status'] == 'rejected')
                 and (payload['status'] == 'accepted') == any(item['status'] == 'accepted' for item in last_outcomes))
        outcome = payload['status']
        for item in last_outcomes:
            key = item['interpretation'] + ':' + item['status'] + ':' + item.get('category', '')
            report.setdefault('interpretationOutcomes', {})[key] = report.setdefault('interpretationOutcomes', {}).get(key, 0) + 1
    except (ValueError, KeyError, TypeError):
        valid = False
        outcome = result.stdout.decode(errors='replace')[:100]

    if not valid or b'Sanitizer' in stderr or b'runtime error:' in stderr:
        (a.output/'failure.bin').write_bytes(data)
        (a.output/'failure.stderr').write_bytes(stderr)
        (a.output/'failure.stdout').write_bytes(result.stdout)
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
            markers = [i + 2 for i in range(len(data) - 3) if data[i] == 255 and data[i + 1] not in (0, 255, 216, 217)]
            start = rng.choice(markers) if markers else rng.randrange(min(128, len(data)))
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
        report['preflight'].append({'path': str(path), 'outcome': outcome, 'interpretations': last_outcomes})
        required_seed_modes = ['srgb'] if manifest[path.stem]['interpretation'] == 'srgb' else ['embedded-preserve', 'embedded-apply']
        required_seed_modes += [mode + '-discard' for mode in required_seed_modes]
        if not all(any(x['interpretation'] == mode and x['status'] == 'accepted' for x in last_outcomes) for mode in required_seed_modes):
            raise RuntimeError('Conformant seed failed expected interpretation: ' + str(path))
        save()
        if outcome != 'accepted':
            raise RuntimeError(f'Conformant seed did not reach successful {a.entry}: {path}, {outcome}')
    started = time.monotonic()
    last_saved = started
    report['status'] = 'running'
    report['campaignStartedAtUTC'] = __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()
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
        if time.monotonic()-last_saved >= 10:
            if source_hashes() != build['sourceSHA256'] or sha(a.binary.read_bytes()) != report['binarySHA256'] or sha(Path(__file__).read_bytes()) != report['scriptSHA256'] or sha(manifest_path.read_bytes()) != report['seedManifestSHA256']:
                raise RuntimeError('Source changed during campaign; evidence invalid')
            save()
            last_saved = time.monotonic()
    report['sourcesUnchanged'] = source_hashes() == build['sourceSHA256'] and sha(a.binary.read_bytes()) == report['binarySHA256'] and sha(Path(__file__).read_bytes()) == report['scriptSHA256'] and sha(manifest_path.read_bytes()) == report['seedManifestSHA256']
    if not report['sourcesUnchanged']: raise RuntimeError('Source changed during campaign')
    report['oneHourGateMet'] = report['elapsedSeconds'] >= 3600
    report['status'] = 'passed' if report['oneHourGateMet'] else 'short-run-complete'
except BaseException as error:
    report['status'] = 'failed'
    report['failure'] = repr(error)
    raise
finally:
    report['finishedAtUTC'] = __import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat()
    save()
print(f"{a.entry}: {report['iterations']} mutations in {report['elapsedSeconds']:.1f}s")
