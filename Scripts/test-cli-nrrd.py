#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent NRRD interoperability and bounded binary CLI regression checks."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time
import nrrd
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reference-tools', type=Path, help='Require independent libjxl CLI checks when supplied')
    args = parser.parse_args()
    binary, out = args.binary.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    assert nrrd.__version__ == '1.1.3' and np.__version__ == '2.0.2', 'Use pinned test-oracle versions'
    report = {'status': 'running', 'pynrrd': nrrd.__version__, 'numpy': np.__version__,
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'checks': []}
    def save(): (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    def record(name, r, expected):
        report['checks'].append({'check': name, 'exit_code': r.returncode, 'expected': expected,
                                 'stderr': r.stderr.decode(errors='replace')})
        save()
        assert r.returncode == expected, (name, r.returncode, r.stderr)
    def run(command, payload=None, expected=0):
        r = subprocess.run([str(binary), *map(str, command)], input=payload, capture_output=True, timeout=15)
        record(' '.join(map(str, command)), r, expected)
        if expected: assert not r.stdout
        return r
    def encode(data, *extra, expected=0):
        return run(['encode', '-i', '-', '--input-format', 'nrrd', *extra], data, expected)
    def decode(data, *extra, expected=0):
        return run(['decode', '-i', '-', '--output-format', 'nrrd', *extra], data, expected)
    def read(data, expected, name):
        p = out / name; p.write_bytes(data)
        decoded, header = nrrd.read(str(p), index_order='C')
        assert decoded.dtype.kind == 'u' and decoded.dtype.itemsize == 2
        assert np.array_equal(decoded, expected), (name, decoded.shape, expected.shape)
        return header
    def blocked(command, name, cancel=False, stdout=None):
        argv = [str(binary), *map(str, command), '-vvvvv']
        if not cancel: argv += ['--timeout', '.15']
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE)
        prefix = b''; start = time.monotonic()
        try:
            if cancel:
                marker = (b'[5] swiftjxl-cli: final ' if stdout else b'[2] swiftjxl-cli: reporting ')
                while marker not in prefix:
                    remaining = start + 10 - time.monotonic()
                    assert remaining > 0 and select.select([p.stderr], [], [], remaining)[0], 'Readiness deadline'
                    chunk = os.read(p.stderr.fileno(), 4096)
                    assert chunk, ('Exited before readiness', prefix)
                    prefix += chunk
                    assert len(prefix) < 65536
                start = time.monotonic(); p.send_signal(signal.SIGINT)
            p.wait(timeout=5)
            output, stderr = p.communicate()
            r = subprocess.CompletedProcess(argv, p.returncode, output, prefix + stderr)
            record(name, r, 130 if cancel else 5)
            assert time.monotonic() - start < 5
        finally:
            if p.poll() is None: p.kill(); p.wait()
    try:
        # Asymmetric textured images expose axis/endian errors. The independent
        # writer supplies input and independent reader checks every output sample.
        for command in ['encode', 'decode']:
            help_text=run([command,'--help']).stdout
            assert b'NRRD0005' in help_text and b'--timeout' in help_text
            assert run(['help',command]).stdout==help_text
        for shape in [(1, 1), (1, 512), (5, 7), (17, 31), (513, 17), (1024, 3)]:
            samples = ((np.arange(np.prod(shape), dtype=np.uint32).reshape(shape) * 7919) & 65535)
            if samples.size > 1: samples.flat[-1] = 65535
            for endian in ['<', '>']:
                data = samples.astype(endian + 'u2')
                source = io.BytesIO(); nrrd.write(source, data, {'encoding': 'raw'}, index_order='C')
                payload = source.getvalue()
                encoded = encode(payload, '--json')
                assert json.loads(encoded.stderr)['fidelity'] == 'exact-samples'
                restored = decode(encoded.stdout, '--json')
                assert json.loads(restored.stderr)['meaningfulBits'] == 16
                read(restored.stdout, data, f'roundtrip-{shape[0]}-{shape[1]}-{ord(endian)}.nrrd')
        if args.reference_tools:
            tools=args.reference_tools.resolve()
            version=subprocess.run([str(tools/'djxl'),'--version'],capture_output=True,check=True)
            report['reference_version']=(version.stdout+version.stderr).decode()
            assert '0.12.0' in report['reference_version']
            fixture_jxl=out/'oracle.jxl';fixture_jxl.write_bytes(encoded.stdout)
            pgm=out/'oracle.pgm'
            r=subprocess.run([str(tools/'djxl'),str(fixture_jxl),str(pgm),'--bits_per_sample=16'],capture_output=True,timeout=30)
            record('CLI encode -> independent djxl',r,0)
            reference=pgm.read_bytes()
            # The reference writer emits the standard binary PGM header.
            import re
            match=re.match(rb'P5\s+(\d+)\s+(\d+)\s+65535\n',reference)
            assert match and tuple(map(int,match.groups()))==(data.shape[1],data.shape[0]),reference[:100]
            values=np.frombuffer(reference[match.end():],dtype='>u2').reshape(data.shape)
            assert np.array_equal(values,data)
            source_pgm=out/'source.pgm';source_pgm.write_bytes(b'P5\n'+str(data.shape[1]).encode()+b' '+str(data.shape[0]).encode()+b'\n65535\n'+data.astype('>u2').tobytes())
            independent=out/'independent.jxl'
            r=subprocess.run([str(tools/'cjxl'),str(source_pgm),str(independent),'-d','0','-e','1','--modular=1'],capture_output=True,timeout=30)
            record('independent cjxl generation',r,0)
            decode(independent.read_bytes(),expected=4)  # Default perceptual intent needs metadata.
            relative=out/'independent-relative.jxl'
            r=subprocess.run([str(tools/'cjxl'),str(source_pgm),str(relative),'-d','0','-e','1','--modular=1','-x','color_space=Gra_D65_Rel_SRG'],capture_output=True,timeout=30)
            record('independent cjxl relative-intent profile',r,0)
            read(decode(relative.read_bytes()).stdout,data,'independent-decoded.nrrd')
        source_file = out / 'private image λ.nrrd'; source_file.write_bytes(payload)
        jxl_file = out / 'image.jxl'; jxl_file.write_bytes(encoded.stdout)
        # Execute a real binary pipe without an intermediate image file.
        producer = subprocess.Popen([str(binary), 'encode', '-i', str(source_file), '--input-format', 'nrrd'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            consumer = subprocess.run([str(binary), 'decode', '-i', '-', '--output-format', 'nrrd'],
                                      stdin=producer.stdout, capture_output=True, timeout=15)
            producer.stdout.close(); producer.wait(timeout=5)
            record('binary pipeline producer', subprocess.CompletedProcess([], producer.returncode, b'', producer.stderr.read()), 0)
            record('binary pipeline consumer', consumer, 0)
            read(consumer.stdout, data, 'pipeline.nrrd')
        finally:
            if producer.poll() is None: producer.kill(); producer.wait()
        # A hand-authored minimal file covers aliases, case and both line endings.
        raw = b'\x00\x00\xff\xff\x34\x12\x00\x80'
        header = b'NRRD0005\ntype: uint16\ndimension: 2\nsizes: 2 2\nencoding: raw\nendian: little\n'
        for alias in [b'ushort', b'unsigned short', b'unsigned short int', b'uint16_t']:
            variant = header.replace(b'uint16', alias) + b'\n' + raw
            read(decode(encode(variant).stdout).stdout, np.array([[0, 65535], [4660, 32768]], dtype='u2'), 'alias.nrrd')
        for variant in [header.replace(b'\n', b'\r\n') + b'\r\n' + raw,
                        header.replace(b'type: uint16', b'TYPE: UINT16') + b'kinds: domain domain\n\n' + raw]:
            decode(encode(variant).stdout)
        invalid = [
            (b'', 3), (b'junk\n\n', 3), (header, 3), (header+b'\n'+raw[:-1], 3), (header+b'\n'+raw+b'x', 3),
            (header.replace(b'NRRD0005', b'NRRD0004')+b'\n'+raw, 4),
            (header+b'type: uint16\n\n'+raw, 3), (header.replace(b'endian: little\n', b'')+b'\n'+raw, 3),
            (header.replace(b'sizes: 2 2', b'sizes: 0 2')+b'\n'+raw, 3),
            (header.replace(b'sizes: 2 2', b'sizes: -1 2')+b'\n'+raw, 3),
            (header.replace(b'sizes: 2 2', b'sizes: 999999999999999999999999999999 2')+b'\n'+raw, 5),
            (header.replace(b'type: uint16', b'type: int16')+b'\n'+raw, 4),
            (header.replace(b'encoding: raw', b'encoding: gzip')+b'\n'+raw, 4),
            (header.replace(b'dimension: 2', b'dimension: 3')+b'\n'+raw, 4),
            (header.replace(b'endian: little', b'endian: native')+b'\n'+raw, 4),
            (header.replace(b'dimension: 2\nsizes: 2 2', b'sizes: 2 2\ndimension: 2')+b'\n'+raw, 3),
            (header+b'data file: https://invalid.example/private\n\n', 4),
            (header+b'byte skip: 1\n\n'+raw, 4), (header+b'space: scanner-xyz\n\n'+raw, 4),
            (header+b'meaningfulBits:=12\n\n'+raw, 4), (header+b'kinds: vector domain\n\n'+raw, 4),
            (header+b'#'+b'x'*1025+b'\n\n'+raw, 5), (header+b'# comment\n'*65+b'\n'+raw, 5),
            (header+b'#'+b'\xff\n\n'+raw, 3),
        ]
        for payload_bad, code in invalid: encode(payload_bad, expected=code)
        encode(b'NRRD0005\n'+(b'#'+b'x'*1000+b'\n')*17+b'\n', expected=5)
        encode(header.replace(b'sizes: 2 2',b'sizes: 513 1')+b'\n'+b'\0'*(513*2),expected=0)
        encode(header.replace(b'sizes: 2 2',b'sizes: 1025 1')+b'\n'+b'\0'*(1025*2),expected=5)
        # A plain uint16 header cannot retain lower source precision or intent.
        decode((args.fixtures / 'scalar-12.jxl').read_bytes(), expected=4)
        decode((args.fixtures / 'scalar-16-intent.jxl').read_bytes(), expected=4)
        decode((args.fixtures / 'damaged-payload.jxl').read_bytes(), expected=4)
        for command, source, formats in [('encode', source_file, ['--input-format','nrrd']),
                                         ('decode', jxl_file, ['--output-format','nrrd'])]:
            run([command, '-i', source], expected=2)
            run([command, '-i', source, *formats, '--backend', 'accelerated'], expected=4)
            run([command, '-i', source, *formats, '--max-memory', '1'], expected=5)
            run([command, '-i', source, *formats, '--max-memory', str(262144+3*source.stat().st_size+1)], expected=5)
            run([command, '-i', source, *formats, '--timeout', '1e-100'], expected=5)
            run([command, '-i', source, *formats, '--max-error', '1'], expected=2)
            if command == 'encode':
                run([command, '-i', source, *formats, '--mode', 'lossy'], expected=4)
            else: run([command, '-i', source, *formats, '--mode', 'lossless'], expected=2)
            target = out / (command+'-final');target.write_bytes(b'keep')
            run([command, '-i', source, *formats, '-o', target], expected=6);assert target.read_bytes()==b'keep'
            run([command, '-i', source, *formats, '-o', target, '--overwrite'])
            if command == 'decode': read(target.read_bytes(), data, 'file-output.nrrd')
            before=target.read_bytes()
            run([command, '-i', '-', *formats, '-o', target, '--overwrite'], payload=b'bad', expected=3)
            assert target.read_bytes()==before
            run([command, '-i', source, *formats, '-o', source, '--overwrite'], expected=6)
            blocked([command,'-i','-',*formats], command+': input deadline')
            blocked([command,'-i','-',*formats], command+': input cancellation', cancel=True)
            readfd, writefd = os.pipe();os.close(readfd)
            try:
                r=subprocess.run([str(binary),command,'-i',str(source),*formats],stdout=writefd,stderr=subprocess.PIPE,timeout=10)
                record(command+': broken output',r,6);assert b'"fidelity"' not in r.stderr
            finally: os.close(writefd)
            readfd, writefd = os.pipe()
            try:
                os.set_blocking(writefd,False)
                try:
                    while True: os.write(writefd,b'x'*4096)
                except BlockingIOError: pass
                os.set_blocking(writefd,True)
                blocked([command,'-i',source,*formats], command+': output deadline',stdout=writefd)
                blocked([command,'-i',source,*formats], command+': output cancellation',cancel=True,stdout=writefd)
            finally:os.close(readfd);os.close(writefd)
        # A blocked diagnostic sink must not hide a deadline or malformed-input
        # exit behind an uninterruptible error-message write. Keep the read end
        # open but never drain it, so this tests backpressure rather than EPIPE.
        readfd, writefd = os.pipe()
        try:
            os.set_blocking(writefd, False)
            try:
                while True: os.write(writefd, b'x' * 4096)
            except BlockingIOError: pass
            os.set_blocking(writefd, True)
            for command, formats in [('encode', ['--input-format', 'nrrd']), ('decode', ['--output-format', 'nrrd'])]:
                for arguments, expected, stalled in [
                    (['-i', '-', '--timeout', '.15'], 5, True),
                    (['-i', '-'], 3, False),
                    (['-i', '-', '-vv'], 6, True),
                ]:
                    p = subprocess.Popen([str(binary), command, *formats, *arguments],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=writefd)
                    start = time.monotonic()
                    try:
                        if stalled:
                            p.wait(timeout=5)
                            stdout, _ = p.communicate()
                        else:
                            stdout, _ = p.communicate(b'bad', timeout=5)
                        assert not stdout
                        result = subprocess.CompletedProcess(arguments, p.returncode, stdout, b'')
                        record(command + ': full stderr ' + ' '.join(arguments), result, expected)
                        report['checks'][-1]['response_seconds'] = time.monotonic() - start
                        save()
                    finally:
                        if p.poll() is None:
                            p.kill(); p.communicate()
            assert os.get_blocking(writefd), 'Diagnostic writer failed to restore shared fd flags'
        finally:
            os.close(readfd); os.close(writefd)
        # Establish signal readiness before filling stderr, then ensure the
        # cancellation error itself cannot block while trying to log exit 130.
        for command, formats in [('encode', ['--input-format', 'nrrd']), ('decode', ['--output-format', 'nrrd'])]:
            readfd, writefd = os.pipe()
            p = subprocess.Popen([str(binary), command, *formats, '-i', '-', '-vv'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=writefd)
            try:
                marker = b'[2] swiftjxl-cli: reporting ' + command.encode() + b'\n'
                prefix = b''
                end = time.monotonic() + 10
                while marker not in prefix:
                    remaining = end - time.monotonic()
                    assert remaining > 0 and select.select([readfd], [], [], remaining)[0], 'Readiness timeout'
                    chunk = os.read(readfd, 4096)
                    assert chunk and len(prefix) + len(chunk) <= 65536
                    prefix += chunk
                os.set_blocking(writefd, False)
                try:
                    while True: os.write(writefd, b'x' * 4096)
                except BlockingIOError: pass
                os.set_blocking(writefd, True)
                start = time.monotonic()
                p.send_signal(signal.SIGINT)
                p.wait(timeout=5)
                stdout, _ = p.communicate()
                assert not stdout
                record(command + ': Ctrl-C with full stderr',
                       subprocess.CompletedProcess([], p.returncode, stdout, prefix), 130)
                report['checks'][-1]['response_seconds'] = time.monotonic() - start
                save()
                assert os.get_blocking(writefd)
            finally:
                if p.poll() is None:
                    p.kill(); p.communicate()
                os.close(readfd); os.close(writefd)
        # JSON reports follow binary publication. A full report sink must reach
        # the deadline and preserve the already committed payload accurately.
        for command, source, formats in [('encode', source_file, ['--input-format', 'nrrd']),
                                         ('decode', jxl_file, ['--output-format', 'nrrd'])]:
            readfd, writefd = os.pipe()
            target = out / (command + '-published-before-report-deadline')
            try:
                os.set_blocking(writefd, False)
                try:
                    while True: os.write(writefd, b'x' * 4096)
                except BlockingIOError: pass
                os.set_blocking(writefd, True)
                result = subprocess.run([str(binary), command, '-i', str(source), *formats,
                    '-o', str(target), '--json', '--timeout', '.5'],
                    stdout=subprocess.PIPE, stderr=writefd, timeout=5)
                result.stderr = b''
                record(command + ': full JSON report sink after publication', result, 5)
                assert not result.stdout and os.get_blocking(writefd)
                if command == 'encode': assert target.read_bytes() == jxl_file.read_bytes()
                else: read(target.read_bytes(), data, 'published-report-deadline.nrrd')
            finally:
                os.close(readfd); os.close(writefd)
        assert not list(out.glob('.swiftjxl-report-*.tmp'))
        report['status']='passed';save();print(f'{len(report["checks"])} NRRD CLI checks passed')
    except Exception as error:
        report['status']='failed';report['failure']=str(error);save();raise

if __name__ == '__main__': main()
