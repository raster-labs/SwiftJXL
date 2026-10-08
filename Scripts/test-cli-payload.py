#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Black-box inspection/validation, stream, cancellation and report transactions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import select
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary, fixtures, out = args.binary.resolve(), args.fixtures.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    report = {'status': 'running', 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'fixture_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.iterdir()},
              'checks': []}
    def save(): (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    def record(label, result, expected):
        report['checks'].append({'check': label, 'exit_code': result.returncode, 'expected': expected,
                                 'stderr': result.stderr.decode(errors='replace')})
        save()
        assert result.returncode == expected, (label, result.returncode, result.stderr)
    def run(*values, expected=0, payload=None):
        result = subprocess.run([str(binary), *map(str, values)], input=payload,
                                capture_output=True, timeout=10)
        record(' '.join(map(str, values)), result, expected)
        if expected: assert not result.stdout, (values, result.stdout)
        return result
    def stream_case(label, command, expected, cancel=False, **kwargs):
        # Wait for real CLI diagnostics emitted after signal-handler setup.
        # Sanitizer startup is separate from the cancellation response budget.
        arguments = [*map(str, command), *(['-vvvvv'] if cancel else [])]
        p = subprocess.Popen([str(binary), *arguments], stdin=subprocess.PIPE,
                             stdout=kwargs.get('stdout', subprocess.PIPE), stderr=subprocess.PIPE)
        start = time.monotonic()
        diagnostic_prefix = b''
        ready_seconds = None
        try:
            if cancel:
                marker = (b'[5] swiftjxl-cli: bounded input processed; final report ready; no pixel file created\n'
                          if 'stdout' in kwargs else
                          b'[2] swiftjxl-cli: reporting ' + str(command[0]).encode() + b'\n')
                startup_deadline = start + 10
                while marker not in diagnostic_prefix:
                    remaining = startup_deadline - time.monotonic()
                    if remaining <= 0 or not select.select([p.stderr], [], [], remaining)[0]:
                        raise AssertionError((label, 'CLI readiness timed out', diagnostic_prefix))
                    chunk = os.read(p.stderr.fileno(), 4096)
                    if not chunk:
                        raise AssertionError((label, 'CLI exited before readiness', diagnostic_prefix))
                    diagnostic_prefix += chunk
                    assert len(diagnostic_prefix) <= 65536, (label, 'Unbounded startup diagnostics')
                ready_seconds = time.monotonic() - start
                start = time.monotonic()
                p.send_signal(signal.SIGINT)
            p.wait(timeout=5)
            stdout, stderr = p.communicate()
            stderr = diagnostic_prefix + stderr
        finally:
            if p.poll() is None:
                p.kill(); p.wait()
        result = subprocess.CompletedProcess(command, p.returncode, stdout or b'', stderr)
        record(label, result, expected)
        elapsed = time.monotonic() - start
        report['checks'][-1].update(readiness_seconds=ready_seconds, response_seconds=elapsed)
        save()
        assert elapsed < 5
    try:
        payload = (fixtures / 'scalar-12.jxl').read_bytes()
        private = out / 'private image λ with spaces.jxl'
        private.write_bytes(payload)
        for command in ['inspect', 'validate']:
            help_text = run(command, '--help').stdout
            assert b'UNAVAILABLE:' not in help_text and b'--timeout' in help_text
            assert run('help', command).stdout == help_text
            for bits in [12, 16]:
                result = run(command, '-i', fixtures / f'scalar-{bits}.jxl', '--json')
                obj = json.loads(result.stdout)
                assert (obj['width'], obj['height'], obj['meaningfulBits']) == (7, 5, bits)
                assert obj['pixelPayloadValidated'] == (command == 'validate')
            result = run(command, '-i', '-', '--json', payload=payload)
            assert json.loads(result.stdout)['meaningfulBits'] == 12
            result = run(command, '-i', private, '--json', '-vvvvv')
            assert json.loads(result.stdout)['format'] == 'jpeg-xl'
            assert len(result.stderr.splitlines()) == 5
            assert str(private).encode() not in result.stderr and payload not in result.stderr
            run(command, '-i', '-', payload=b'', expected=3)
            run(command, '-i', '-', payload=payload[:-1], expected=3)
            run(command, '-i', private, '--input-format', 'jpeg-xl', '--backend', 'scalar-cpu',
                '--copy-policy', 'allow-copy', '--threads', '2')
            run(command, '-i', '/nonexistent-private-input', '--input-format', 'png', expected=4)
            run(command, '-i', '/nonexistent-private-input', '--backend', 'accelerated', expected=4)
            run(command, '-i', '/nonexistent-private-input', expected=6)
            run(command, '-i', out, expected=6)
            for option, value in [('--threads', '0'), ('--threads', '9'), ('--max-memory', '-1'),
                                  ('--max-memory', str(2**128)), ('--timeout', 'nan'),
                                  ('--timeout', 'inf'), ('--timeout', '0'), ('--timeout', '31536001'),
                                  ('--backend', 'unknown'), ('--copy-policy', 'unknown'),
                                  ('--mode', 'lossless'), ('--max-error', '1'), ('--output-format', 'json')]:
                run(command, '-i', '-', option, value, expected=2)
            run(command, expected=2)
            run(command, '-i', private, '--input', private, expected=2)
            run(command, '-i', private, '--overwrite', expected=2)
            run(command, '-i', private, '--max-memory', '1', expected=5)
            run(command, '-i', private, '--timeout', '1e-100', expected=5)
            run(command, '-i', private, '--quiet', '--json')
            target = out / (command + ' report.json')
            target.write_bytes(b'keep')
            run(command, '-i', private, '-o', target, '--json', expected=6)
            assert target.read_bytes() == b'keep'
            run(command, '-i', private, '-o', target, '--json', '--overwrite')
            assert json.loads(target.read_bytes())['operation'] == command
            before = target.read_bytes()
            run(command, '-i', '-', '-o', target, '--overwrite', payload=b'bad', expected=3)
            assert target.read_bytes() == before
            run(command, '-i', private, '-o', private, '--overwrite', expected=6)
            assert private.read_bytes() == payload
            with private.open('rb') as source:
                result = subprocess.run([str(binary), command, '-i', '-', '-o', str(private), '--overwrite'],
                                        stdin=source, capture_output=True, timeout=5)
                record(command + ': stdin aliases report destination', result, 6)
            assert private.read_bytes() == payload
            link = out / (command + '-hardlink')
            os.link(private, link)
            run(command, '-i', private, '-o', link, '--overwrite', expected=6)
            symlink = out / (command + '-symlink')
            symlink.symlink_to(private)
            run(command, '-i', private, '-o', symlink, '--overwrite', expected=6)
            run(command, '-i', private, '-o', out / 'missing-directory' / 'report', expected=6)
            fresh = out / (command + '-new.json')
            run(command, '-i', private, '-o', fresh, '--json')
            assert json.loads(fresh.read_bytes())['operation'] == command
            stream_case(command + ': stalled stdin deadline', [command, '-i', '-', '--timeout', '.15'], 5)
            stream_case(command + ': Ctrl-C during stalled stdin', [command, '-i', '-'], 130, cancel=True)
            readfd, writefd = os.pipe()
            os.close(readfd)
            try:
                r = subprocess.run([str(binary), command, '-i', str(private)], stdout=writefd,
                                   stderr=subprocess.PIPE, timeout=5)
                record(command + ': closed report pipe', r, 6)
            finally: os.close(writefd)
            readfd, writefd = os.pipe()
            try:
                os.set_blocking(writefd, False)
                try:
                    while True: os.write(writefd, b'x' * 4096)
                except BlockingIOError: pass
                os.set_blocking(writefd, True)
                stream_case(command + ': blocked report deadline',
                            [command, '-i', private, '--timeout', '.15'], 5, stdout=writefd)
                stream_case(command + ': Ctrl-C during blocked report',
                            [command, '-i', private], 130, cancel=True, stdout=writefd)
            finally:
                os.close(readfd); os.close(writefd)
        # Header inspection must not masquerade as full payload validation.
        damaged = fixtures / 'damaged-payload.jxl'
        inspected = run('inspect', '-i', damaged, '--json')
        assert json.loads(inspected.stdout)['pixelPayloadValidated'] is False
        run('validate', '-i', damaged, expected=3)
        oversized = out / 'oversized.jxl'
        with oversized.open('wb') as f: f.truncate(4 * 1024 * 1024 + 1)
        run('inspect', '-i', oversized, expected=5)
        run('validate', '-i', '-', payload=b'x' * (4 * 1024 * 1024 + 1), expected=5)
        assert not list(out.glob('.swiftjxl-report-*.tmp'))
        report['status'] = 'passed'; save()
        print(f'{len(report["checks"])} CLI payload process checks passed')
    except Exception as error:
        report['status'] = 'failed'; report['failure'] = str(error); save(); raise

if __name__ == '__main__': main()
