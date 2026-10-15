#!/usr/bin/env python3
"""Controlled follow-up of retained Milestone 4 pixel-family comparisons.

Build pixel-family-benchmark.swift against the final release objects first.
Reuse the pinned predecessor executable, corpus, eligibility and scalar oracle
from the prior bench directory; never rebuild or modify that baseline here.
This script executes validation, so invoke only after implementation is complete.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import time


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-directory', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--candidate-workers', default='1', choices=['default'] + [str(i) for i in range(1, 9)],
                        help='Retained one-worker policy or separate explicit/default policy comparison')
    parser.add_argument('--case', action='append', help='Repeat to select cases; default is all retained pixel families')
    args = parser.parse_args()
    old = args.baseline_directory.resolve()
    candidate = args.candidate.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    baseline = old / 'family-predecessor'
    oracle = old / 'family-oracle-scalar'
    plan = json.loads((old / 'families/measurement-plan.json').read_text())
    selected = [item for item in plan if not args.case or item['case']['id'] in args.case]
    if args.case and set(args.case) != {item['case']['id'] for item in selected}:
        raise ValueError('Unknown requested case')
    env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING='1', SWIFTJXL_BENCHMARK_WORKERS=args.candidate_workers)
    manifest = {'candidateSHA256': digest(candidate), 'baselineSHA256': digest(baseline),
                'oracleSHA256': digest(oracle), 'baselinePlanSHA256': digest(old / 'families/measurement-plan.json'),
                'warmupsPerProcess': 5, 'timedPerProcess': 10, 'rounds': ['ABBA', 'BAAB'],
                'candidateWorkerPolicy': args.candidate_workers, 'predecessorWorkerPolicy': 'native unchanged',
                'scope': 'Process RSS and retained heap endpoints are not exact workspace, copies or leak evidence.'}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

    def call(command, name, parse_json=True):
        started = time.monotonic()
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=600, env=env)
        record = {'command': list(map(str, command)), 'exit': result.returncode,
                  'stdout': result.stdout, 'stderr': result.stderr, 'seconds': time.monotonic() - started}
        (output / (name + '.json')).write_text(json.dumps(record, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError('Failed execution: ' + name)
        if not parse_json:
            return record
        payload = json.loads(result.stdout)
        if Path(command[0]).resolve() == candidate and payload.get('workerPolicy') != args.candidate_workers:
            raise RuntimeError('Candidate runner does not confirm the requested worker policy')
        return payload

    def command(binary, case, operation, iterations, prefix, shared=None):
        result = [binary, case['family'], operation, case['fixture'], case['frames'], case['distance'], iterations, prefix]
        if shared is not None:
            result.append(shared)
        return result

    rows = []
    for item in selected:
        case = item['case']
        name = case['id']
        prefix = output / (name + '-preflight')
        pre = call(command(candidate, case, 'encode', 0, prefix), name + '-preflight')
        call([oracle, str(prefix) + '.jxl', str(prefix) + '.f32le'], name + '-oracle', parse_json=False)
        values = array.array('f')
        values.frombytes(Path(str(prefix) + '.f32le').read_bytes())
        if sys.byteorder != 'little':
            values.byteswap()
        maximum = (1 << pre['bits']) - 1
        reference = [min(maximum, max(0, math.floor(v * maximum + .5))) for v in values]
        actual = []
        for frame in range(case['frames']):
            raw = Path(str(prefix) + f'-frame-{frame}.u16le').read_bytes()
            actual.extend(struct.unpack('<' + str(len(raw) // 2) + 'H', raw))
        if len(actual) != len(reference):
            raise RuntimeError('Oracle sample count mismatch: ' + name)
        differences = [abs(a - b) for a, b in zip(actual, reference)]
        payload = Path(case['fixture']).read_bytes().split(b'ENDHDR\n', 1)[1]
        originals = list(payload) if pre['bits'] == 8 else list(struct.unpack('>' + str(len(payload) // 2) + 'H', payload))
        source = [(value + frame * 17) & maximum for frame in range(case['frames']) for value in originals]
        if len(source) != len(actual):
            raise RuntimeError('Source sample count mismatch: ' + name)
        alpha = [abs(a - b) for index, (a, b) in enumerate(zip(actual, source))
                 if pre['channels'] % 2 == 0 and index % pre['channels'] == pre['channels'] - 1]
        if max(alpha, default=0) != 0 or (case['family'] == 'modular' and actual != source):
            raise RuntimeError('Fidelity mismatch: ' + name)
        colour_errors = [(a-b)**2 for index,(a,b) in enumerate(zip(actual,source))
                         if not (pre['channels'] % 2 == 0 and index % pre['channels'] == pre['channels'] - 1)]
        colour_rms = math.sqrt(sum(colour_errors) / len(colour_errors))
        metrics = {'sourceColourRMSLSB': colour_rms,
                   'sourcePSNRDB': None if colour_rms == 0 else 20 * math.log10(maximum / colour_rms),
                   'encodedBytes': pre['encodedBytes'],
                   'pinnedPredecessorRateDistortion': item['entries']['predecessor'].get('referenceRateDistortion'),
                   'maxLSB': max(differences), 'rmsLSB': math.sqrt(sum(v * v for v in differences) / len(differences)),
                   'sourceRMSLSB': math.sqrt(sum((a-b)**2 for a,b in zip(actual,source))/len(source)),
                   'alphaMaxLSB': max(alpha, default=0), 'exactSource': actual == source,
                   'fixtureSHA256': digest(case['fixture']), 'streamSHA256': digest(str(prefix) + '.jxl')}
        (output / (name + '-oracle-metrics.json')).write_text(json.dumps(metrics, indent=2) + '\n')
        if metrics['maxLSB'] > 2 or metrics['rmsLSB'] > .5:
            raise RuntimeError('Independent scalar gate failed: ' + name)
        # The benchmark itself checks exact lossless samples, alpha, descriptor
        # and timing outside measured work. Its own preflight is never skipped.
        for operation in ['encode', 'decode']:
            implementations = item[operation]
            if not implementations:
                continue  # Retain eligibility; never manufacture a baseline.
            row = {'case': name, 'operation': operation, 'implementations': implementations, 'rounds': []}
            rows.append(row)
            # Use the original shared input for decoder latency equivalence.
            shared = item['sharedInput'] if operation == 'decode' else None
            sequences = [['predecessor', 'candidate', 'candidate', 'predecessor'],
                         ['candidate', 'predecessor', 'predecessor', 'candidate']] if len(implementations) == 2 else [implementations * 2] * 2
            for round_index, sequence in enumerate(sequences):
                runs = {implementation: [] for implementation in implementations}
                for run_index, implementation in enumerate(sequence):
                    run_name = f'{name}-{operation}-r{round_index}-{run_index}-{implementation}'
                    binary = candidate if implementation == 'candidate' else baseline
                    result = call(command(binary, case, operation, 10, output / run_name, shared), run_name)
                    runs[implementation].append(result)
                summary = {}
                for implementation, results in runs.items():
                    samples = sorted(value for result in results for value in result['milliseconds'])
                    summary[implementation] = {'medianMS': statistics.median(samples),
                        'p95MS': samples[math.ceil(len(samples) * .95) - 1], 'rawMS': samples,
                        'medianProcessPeakRSSBytes': statistics.median(result['processPeakRSSBytes'] for result in results),
                        'encodedBytes': results[0]['encodedBytes'],
                        'thermalStates': [[result['thermalStart'], result['thermalEnd']] for result in results]}
                result = {'summary': summary}
                if len(implementations) == 2:
                    before, after = summary['predecessor'], summary['candidate']
                    result.update(
                        latencyChangePercent=100 * (after['medianMS'] / before['medianMS'] - 1),
                        rssChangePercent=100 * (after['medianProcessPeakRSSBytes'] / before['medianProcessPeakRSSBytes'] - 1),
                        sizeChangePercent=100 * (after['encodedBytes'] / before['encodedBytes'] - 1))
                row['rounds'].append(result)
                (output / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
            row['repeatedLatencyTrigger'] = len(implementations) == 2 and all(r['latencyChangePercent'] > 5 for r in row['rounds'])
            row['repeatedRSSTrigger'] = len(implementations) == 2 and all(r['rssChangePercent'] > 5 for r in row['rounds'])
            row['losslessSizeTrigger'] = len(implementations) == 2 and operation == 'encode' and case['family'] == 'modular' and all(r['sizeChangePercent'] > 1 for r in row['rounds'])
            print(name, operation, {k: v for k, v in row.items() if k.endswith('Trigger')}, flush=True)
            (output / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    return int(any(row.get(key, False) for row in rows for key in ['repeatedLatencyTrigger', 'repeatedRSSTrigger', 'losslessSizeTrigger']))


if __name__ == '__main__':
    sys.exit(main())
