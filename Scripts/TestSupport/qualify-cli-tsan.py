#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run all ten CLI qualification groups against one TSan-instrumented binary.

Build the release binary separately with --sanitize thread. Reference tools are
test-only dependencies. Each group retains its own exact process/sample checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time
from datetime import datetime, timezone


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalise_paths(arguments):
    for key, value in vars(arguments).items():
        if value is not None:
            # A virtual-environment interpreter must retain its symlink path:
            # resolving it selects the base Python and loses pinned packages.
            setattr(arguments, key, value.absolute() if key == 'nrrd_python' else value.resolve())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    for flag in ['binary', 'output', 'fixtures', 'oracle-dir', 'reference-tools', 'nrrd-python']:
        p.add_argument('--' + flag, type=Path, required=True)
    p.add_argument('--foundation-report', type=Path,
                   help='Reuse a completed foundation run only when binary, script, installer and manual hashes still match')
    a = p.parse_args()
    normalise_paths(a)
    a.output.mkdir(parents=True, exist_ok=False)
    runtime = lambda: {str(f.relative_to(a.repo)): sha(f) for f in sorted(
        [a.repo/'Package.swift', a.repo/'VERSION', *[x for x in (a.repo/'Sources').rglob('*') if x.is_file()]])}
    source = runtime()
    env = os.environ.copy()
    env['TSAN_OPTIONS'] = 'halt_on_error=1:exitcode=66'
    report = {'status': 'running', 'startedAtUTC': datetime.now(timezone.utc).isoformat(),
              'runtimeFiles': source, 'sourceGroupDigests': {'runtime': hashlib.sha256(
                  json.dumps(source, sort_keys=True, separators=(',', ':')).encode()).hexdigest()},
              'host': platform.platform(), 'binarySHA256': sha(a.binary),
              'driverSHA256': sha(Path(__file__)), 'runs': [], 'tools': {},
              'sanitizerOptions': {'TSAN_OPTIONS': env['TSAN_OPTIONS']}}
    def save():
        (a.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    save()
    try:
        identity = subprocess.run(['otool', '-L', str(a.binary)], capture_output=True, text=True, check=True)
        report['linkedLibraries'] = identity.stdout
        if 'libclang_rt.tsan_osx_dynamic.dylib' not in identity.stdout:
            raise ValueError('CLI binary does not link the ThreadSanitizer runtime')
        for tool in [a.binary, a.nrrd_python, *(a.reference_tools/x for x in ['cjxl','djxl','djpeg']),
                     *(a.oracle_dir/x for x in ['modular-info-oracle','animation-pixel-oracle',
                                               'jpeg-coefficient-oracle','pixel-oracle-scalar'])]:
            if not tool.is_file() or not os.access(tool, os.X_OK):
                raise ValueError('Missing executable: '+str(tool))
            report['tools'][str(tool)] = sha(tool)
        manifest_path = a.oracle_dir/'scalar-oracle-manifest.json'
        scalar = json.loads(manifest_path.read_text())
        if (scalar.get('sourceRevision') != 'a7a9c787341cf703dede03c2009fa460cae5e5df'
                or scalar.get('scalarOnly') is not True or scalar.get('highPrecision') is not True
                or scalar.get('binarySHA256') != sha(a.oracle_dir/'pixel-oracle-scalar')):
            raise ValueError('A source-pinned scalar-only, high-precision reference build is required')
        if not scalar.get('librarySHA256'):
            raise ValueError('Missing scalar reference libraries')
        scalar_symbols = False
        for path, digest in scalar['librarySHA256'].items():
            if sha(Path(path)) != digest:
                raise ValueError('Scalar reference library changed: '+path)
            symbols = subprocess.run(['nm', '-C', path], capture_output=True, text=True, check=True).stdout
            if 'N_SCALAR' in symbols:
                scalar_symbols = True
                if re.search(r'N_(?:NEON|SVE|AVX|SSE|EMU128)', symbols):
                    raise ValueError('Reference includes non-scalar dispatch implementations: '+path)
        if not scalar_symbols:
            raise ValueError('Reference library has no compiled scalar implementation')
        report['scalarOracle'] = scalar
        report['scalarOracleManifestSHA256'] = sha(manifest_path)
        groups = [
            ('foundation', 'test-cli.py', []),
            ('payload', 'test-cli-payload.py', ['--fixtures', a.fixtures]),
            ('nrrd', 'test-cli-nrrd.py', ['--fixtures', a.fixtures, '--reference-tools', a.reference_tools]),
            ('pnm', 'test-cli-pnm.py', ['--info-oracle', a.oracle_dir/'modular-info-oracle', '--reference-tools', a.reference_tools]),
            ('low-precision', 'test-cli-low-precision.py', []),
            ('vardct', 'test-cli-vardct.py', []),
            ('vardct-encode', 'test-cli-vardct-encode.py', ['--scalar-oracle', a.oracle_dir/'pixel-oracle-scalar']),
            ('native-jpeg', 'test-cli-native-jpeg.py', ['--reference-tools', a.reference_tools]),
            ('completion', 'test-cli-completion.py', ['--djpeg', a.reference_tools/'djpeg',
                '--animation-oracle', a.oracle_dir/'animation-pixel-oracle',
                '--coefficient-oracle', a.oracle_dir/'jpeg-coefficient-oracle']),
            ('jpeg-extended', 'test-cli-jpeg-extended.py', ['--fixtures', a.repo/'Tests/SwiftJXLCoreTests/Fixtures/JPEGExtended']),
        ]
        for name, script, extra in groups:
            script = a.repo/'Scripts'/script
            cmd = list(map(str, [a.nrrd_python, script, '--binary', a.binary, '--output', a.output/name, *extra]))
            started = time.monotonic()
            row = {'group': name, 'command': cmd, 'scriptSHA256': sha(script)}
            print('Starting '+name, flush=True)
            try:
                if name == 'foundation' and a.foundation_report:
                    path = a.foundation_report
                    detail = json.loads(path.read_text())
                    expected = {'binary_sha256': sha(a.binary), 'test_runner_sha256': sha(script),
                                'installer_sha256': sha(a.repo/'Scripts/install-cli.sh'),
                                'manual_sha256': sha(a.repo/'ManPages/swiftjxl-cli.1')}
                    if not all(detail.get(k) == v for k, v in expected.items()) or detail.get('status') != 'passed':
                        raise ValueError('Completed foundation report does not match the current binary and scripts')
                    if not detail.get('commands') or not all(c['exit_code'] == c['expected_exit_code'] for c in detail['commands']):
                        raise ValueError('Completed foundation command outcomes are invalid')
                    row.update(exitCode=0, reusedReport=str(path), reusedHashes=expected)
                    (a.output/(name+'.log')).write_text('Reused completed source/binary-bound report: '+str(path)+'\n')
                else:
                    with (a.output/(name+'.log')).open('w') as log:
                        result = subprocess.run(cmd, cwd=a.repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=7200)
                    row['exitCode'] = result.returncode
                    path = a.output/name/'report.json'
                detail = json.loads(path.read_text())
                checks = detail.get('checks', [])
                row.update(reportSHA256=sha(path), result=detail.get('status'),
                           checks=checks if type(checks) is int else len(checks), commands=len(detail.get('commands', [])))
                diagnostics = path.read_text() + (a.output/(name+'.log')).read_text()
                row['sanitizerDiagnostic'] = any(x in diagnostics for x in
                    ['WARNING: ThreadSanitizer', 'SUMMARY: ThreadSanitizer', 'ThreadSanitizer: reported'])
                row['status'] = 'passed' if row['exitCode'] == 0 and detail.get('status') == 'passed' and not row['sanitizerDiagnostic'] else 'failed'
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                row.update(status='failed', error=str(error))
            row['seconds'] = time.monotonic()-started
            report['runs'].append(row)
            save()
            print(name+': '+row['status'], flush=True)
        report['sourcesUnchanged'] = source == runtime()
        report['binaryUnchanged'] = sha(a.binary) == report['binarySHA256']
        report['status'] = 'passed' if report['sourcesUnchanged'] and report['binaryUnchanged'] and all(
            row['status'] == 'passed' for row in report['runs']) and len(report['runs']) == 10 else 'failed'
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report.update(status='failed', error=str(error))
    report['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
    save()
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
