#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Required independent JPEG pixels, container and animation CLI qualification.

JPEG uses libjpeg floating IDCT with nearest chroma (-nosmooth), with declared
maximum 2 LSB / RMS 0.75 tolerance for integer IDCT/colour-rounding differences.
Lossless JPEG XL samples and animation timing must match exactly.
The retained quant16 adversarial fixture scales quantisers without re-encoding
coefficients. Its out-of-range IDCT is checked against a direct mathematical
reference, not libjpeg's intentionally wrapping range-limit table.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--djpeg', type=Path, required=True)
p.add_argument('--animation-oracle', type=Path, required=True)
p.add_argument('--coefficient-oracle', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--extra-jpeg', type=Path, action='append', default=[], help='Additional licensed corpus JPEG; recorded by hash')
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
tools = [a.binary.resolve(), a.djpeg.resolve(), a.animation_oracle.resolve(), a.coefficient_oracle.resolve()]
if not all(x.is_file() and os.access(x, os.X_OK) for x in tools):
    p.error('All four executables are required; missing independent tools cannot skip this gate')
report = {'status': 'running', 'tools': {str(x): hashlib.sha256(x.read_bytes()).hexdigest() for x in tools},
          'commands': [], 'checks': []}
def save():
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
def call(args, payload=None, expected=0):
    result = subprocess.run([str(x) for x in args], input=payload, capture_output=True, timeout=180)
    report['commands'].append({'command': [str(x) for x in args], 'exit': result.returncode,
        'stderr': result.stderr.decode(errors='replace'), 'stdoutSHA256': hashlib.sha256(result.stdout).hexdigest()})
    save()
    assert result.returncode == expected, report['commands'][-1]
    return result
def cli(args, **kwargs):
    return call([tools[0], *args], **kwargs)
def raster(data):
    if data.startswith(b'P7\n'):
        header, payload = data.split(b'ENDHDR\n', 1)
        fields = dict(x.split(maxsplit=1) for x in header.splitlines()[1:] if x and not x.startswith(b'#'))
        return int(fields[b'WIDTH']), int(fields[b'HEIGHT']), int(fields[b'DEPTH']), int(fields[b'MAXVAL']), payload
    offset = 0; fields = []
    while len(fields) < 4:
        while data[offset] in b' \r\n\t': offset += 1
        if data[offset] == 35:
            offset = data.index(b'\n', offset) + 1; continue
        end = offset
        while data[end] not in b' \r\n\t': end += 1
        fields.append(data[offset:end]); offset = end
    assert fields[0] in [b'P5', b'P6']
    return int(fields[1]), int(fields[2]), 1 if fields[0] == b'P5' else 3, int(fields[3]), data[offset+1:]
def direct_saturation_reference(jpeg):
    # Independently extract coefficients using libjpeg, then evaluate the
    # nonseparable 64-term T.81 A.3.3 formula. Swift uses two separable passes.
    snapshot = call([tools[3], jpeg]).stdout
    (out / 'quant16-independent-coefficients.json').write_bytes(snapshot)
    d = json.loads(snapshot)
    assert d['width'] <= 64 and d['height'] <= 64 and len(d['components']) == 1
    c = d['components'][0]; pixels = []
    for y in range(d['height']):
        for x in range(d['width']):
            base = ((y//8)*c['width'] + x//8)*64
            value = sum((1/math.sqrt(2) if u == 0 else 1)*(1/math.sqrt(2) if v == 0 else 1)
                * c['coefficients'][base+v*8+u]*c['quantisation'][v*8+u]
                * math.cos((2*(x%8)+1)*u*math.pi/16)*math.cos((2*(y%8)+1)*v*math.pi/16)
                for v in range(8) for u in range(8))*.25
            nearest = math.floor(value+.5) if value >= 0 else math.ceil(value-.5)
            pixels.append(max(0, min(255, nearest+128)))
    return bytes(pixels)
try:
    names = ['gray', '444', '422', '420', '440', 'progressive', 'restart',
             'progressive-422', 'progressive-440', 'progressive-edge', 'sequential-multiscan']
    cases = [(name, repo / 'Tests/SwiftJXLCoreTests/Fixtures/JPEG' / (name + '.jpg')) for name in names]
    cases += [('bridge-' + name, repo / 'Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge' / (name + '.jpg'))
              for name in ['rgb', 'rgb-progressive', 'tiny', 'thin', 'quant16', 'multigroup-420', 'multigroup-progressive-422']]
    cases += [('extra-' + str(index), path.resolve()) for index, path in enumerate(a.extra_jpeg)]
    for name, jpeg in cases:
        reference = call([tools[1], '-dct', 'float', '-nosmooth', jpeg]).stdout
        actual = cli(['decode', '-i', jpeg, '--input-format', 'jpeg-srgb', '--output-format', 'pnm-srgb']).stdout
        r, v = raster(reference), raster(actual)
        assert r[:4] == v[:4] and len(r[4]) == len(v[4])
        errors = [abs(x-y) for x,y in zip(r[4], v[4])]
        peak, rms = max(errors), math.sqrt(sum(x*x for x in errors)/len(errors))
        (out / (name + '-reference.pnm')).write_bytes(reference)
        (out / (name + '-native.pnm')).write_bytes(actual)
        if name == 'bridge-quant16':
            assert hashlib.sha256(jpeg.read_bytes()).hexdigest() == 'ee414037cbf2e3faf353ff6e424e00a44859edb07ee2802fbb5820d53c1bff89'
            direct = direct_saturation_reference(jpeg)
            (out / 'quant16-direct-reference.raw').write_bytes(direct)
            assert v[4] == direct
            report.setdefault('referenceDisagreements', []).append({'jpeg': name,
                'djpegMaximumLSB': peak, 'djpegRMSLSB': rms, 'classification': 'adversarial out-of-range IDCT saturation',
                'directFormulaExact': True, 'source': 'https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/src/jdmaster.c#L362-L400'})
            peak, rms = 0, 0.0
        if peak > 2 or rms > .75:
            report.setdefault('pixelFailures', []).append({'jpeg': name, 'maximumLSB': peak, 'rmsLSB': rms})
            save()
            continue
        encoded = cli(['encode', '-i', jpeg, '--input-format', 'jpeg-srgb', '--container', 'iso']).stdout
        stream = out / (name + '.jxl'); stream.write_bytes(encoded)
        floating = out / (name + '.float')
        call([tools[2], stream, floating])
        samples = [int(min(1, max(0, x[0])) * 255 + .5) for x in struct.iter_unpack('<f', floating.read_bytes())]
        assert bytes(samples) == v[4]
        report['checks'].append({'jpeg': name, 'maximumLSB': peak, 'rmsLSB': rms,
            'sourceSHA256': hashlib.sha256(jpeg.read_bytes()).hexdigest(), 'exactJXLEncodingOfDecodedSamples': True})
    for bits, channels in [(8, 3), (16, 4)]:
        width, height, maximum = 17, 9, (1 << bits) - 1
        sources, expected = [], []
        for index in range(3):
            samples = [(i * 73 + index * 1703) & maximum for i in range(width * height * channels)]
            header = f'P7\nWIDTH {width}\nHEIGHT {height}\nDEPTH {channels}\nMAXVAL {maximum}\nTUPLTYPE {"RGB" if channels == 3 else "RGB_ALPHA"}\nENDHDR\n'.encode()
            payload = bytes(samples) if bits == 8 else b''.join(struct.pack('>H', x) for x in samples)
            path = out / f'{bits}-source-{index}.pam'; path.write_bytes(header + payload)
            sources.append(path); expected.extend(samples)
        inputs = [argument for path in sources for argument in ['-i', path]]
        for container in ['codestream', 'iso']:
            stream = out / f'{bits}-{container}.jxl'
            encoded = cli(['encode', *inputs, '--input-format', 'pnm-srgb', '--frame-duration', '11,29,7',
                '--ticks-per-second', '24000/1001', '--loop-count', '4', '--container', container, '-o', stream, '--json'])
            assert json.loads(encoded.stderr)['frameCount'] == 3
            floating = out / f'{bits}-{container}.float'
            oracle = call([tools[2], stream, floating]).stdout.decode()
            assert 'clock 24000/1001 loops 4' in oracle
            for index, duration in enumerate([11,29,7]): assert f'frame {index} duration {duration}' in oracle
            samples = [int(min(1,max(0,x[0]))*maximum+.5) for x in struct.iter_unpack('<f', floating.read_bytes())]
            assert samples == expected
            directory = out / f'{bits}-{container}-decoded'
            cli(['decode', '-i', stream, '--all-frames', '--output-format', 'pnm-srgb', '-o', directory])
            timing = json.loads((directory/'timing.json').read_text())
            assert timing['ticksPerSecondDenominator'] == 1001 and timing['totalTicks'] == 47
            for index, path in enumerate(sources):
                assert raster((directory/f'frame-{index:06d}.pam').read_bytes()) == raster(path.read_bytes())
            cli(['decode', '-i', stream, '--all-frames', '--output-format', 'pnm-srgb', '-o', directory], expected=6)
            inspected = cli(['inspect', '-i', stream, '--all-frames', '--json'])
            assert not json.loads(inspected.stdout)['pixelPayloadValidated']
            validated = cli(['validate', '-i', stream, '--all-frames', '--json'])
            assert json.loads(validated.stdout)['pixelPayloadValidated']
            selected = cli(['decode', '-i', stream, '--frame', '1', '--output-format', 'pnm-srgb'])
            assert raster(selected.stdout) == raster(sources[1].read_bytes())
            cli(['decode', '-i', stream, '--frame', '3', '--output-format', 'pnm-srgb'], expected=2)
            cli(['validate', '-i', stream, '--all-frames', '--max-frames', '2'], expected=5)
            report['checks'].append({'animationBits': bits, 'channels': channels, 'container': container, 'exactSamplesAndTiming': True})
        # Never overwrite the second source through either its path or a hard link.
        alias = out / f'{bits}-source-alias.pam'; os.link(sources[1], alias)
        original = sources[1].read_bytes()
        cli(['encode', *inputs, '--input-format', 'pnm-srgb', '-o', alias, '--overwrite'], expected=6)
        assert sources[1].read_bytes() == original
        cli(['encode', *inputs, '--input-format', 'pnm-srgb', '--frame-duration', '1,2'], expected=2)
        cli(['encode', *inputs, '--input-format', 'pnm-srgb', '--max-memory', '300000'], expected=5)
    for args in [['decode','--all-frames','--frame','0'], ['encode','--all-frames'],
                 ['inspect','--container','iso'], ['encode','--frame-duration','10']]:
        cli([*args, '-i', '/nonexistent'], expected=2)
    assert not report.get('pixelFailures'), report.get('pixelFailures')
    report['status'] = 'passed'
except BaseException as error:
    report['status'] = 'failed'; report['error'] = repr(error)
    raise
finally:
    save()
