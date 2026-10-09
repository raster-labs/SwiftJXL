#!/usr/bin/env python3
"""Test-only independent Brotli oracle for the Swift framing/encoder fixtures.

Swift tests compare encoder output byte for byte with these compact boundary
descriptions. This check independently decodes those same bytes with libbrotli.
No runtime package dependency is introduced.
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', help='Path to independent libbrotlidec')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / 'Tests/SwiftJXLCoreTests/Fixtures/Brotli/framing.json'
    record = json.loads(source.read_text())
    library = args.library or ctypes.util.find_library('brotlidec')
    if not library:
        raise SystemExit('Independent libbrotlidec is required; no skipped oracle checks')
    lib = ctypes.CDLL(library)
    lib.BrotliDecoderDecompress.argtypes = [ctypes.c_size_t, ctypes.c_void_p,
                                          ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p]
    lib.BrotliDecoderDecompress.restype = ctypes.c_int
    lib.BrotliDecoderVersion.restype = ctypes.c_uint
    results = []

    def verify(name, encoded, expected):
        capacity = ctypes.c_size_t(max(1, len(expected)))
        output = ctypes.create_string_buffer(capacity.value)
        status = lib.BrotliDecoderDecompress(len(encoded), encoded, ctypes.byref(capacity), output)
        if status != 1 or output.raw[:capacity.value] != expected:
            raise RuntimeError('Independent decode failed: ' + name)
        results.append({'name': name, 'encodedSHA256': hashlib.sha256(encoded).hexdigest(),
                        'outputSHA256': hashlib.sha256(expected).hexdigest()})

    for item in record['streams']:
        verify(item['name'], bytes.fromhex(item['stream']), bytes.fromhex(item['output']))
    for item in record['encoderBoundaries']:
        payload = bytes([165]) * item['count']
        encoded = bytes.fromhex(item['prefix']) + payload + bytes.fromhex(item['suffix'])
        if hashlib.sha256(encoded).hexdigest() != item['sha256']:
            raise RuntimeError('Boundary fixture hash mismatch')
        verify('encoder-' + str(item['count']), encoded, payload)
    report = {'status': 'passed', 'checks': len(results), 'skips': 0,
              'library': library, 'version': lib.BrotliDecoderVersion(),
              'fixtureSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'results': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('Independent Brotli framing checks passed:', len(results))


if __name__ == '__main__':
    main()
