#!/usr/bin/env python3
"""Test-only independent validation of compressed Brotli and dictionary fixtures."""
import argparse
import base64
import ctypes as C
import ctypes.util
import hashlib
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--decoder-library')
    parser.add_argument('--common-library')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    fixtures = root / 'Tests/SwiftJXLCoreTests/Fixtures/Brotli'
    decoder_path = args.decoder_library or C.util.find_library('brotlidec')
    common_path = args.common_library or C.util.find_library('brotlicommon')
    if not decoder_path or not common_path:
        raise SystemExit('Both independent Brotli libraries are required; checks cannot skip')
    decoder = C.CDLL(decoder_path)
    common = C.CDLL(common_path)
    decoder.BrotliDecoderDecompress.argtypes = [C.c_size_t, C.c_void_p, C.POINTER(C.c_size_t), C.c_void_p]
    decoder.BrotliDecoderDecompress.restype = C.c_int
    decoder.BrotliDecoderVersion.restype = C.c_uint
    manifest = json.loads((fixtures / 'decoder.json').read_text())
    results = []
    sha = lambda data: hashlib.sha256(data).hexdigest()
    for entry in manifest['cases']:
        encoded = (fixtures / (entry['name'] + '.br')).read_bytes()
        expected = (fixtures / (entry['raw'] + '.raw')).read_bytes()
        if sha(encoded) != entry['encodedSHA256'] or sha(expected) != entry['rawSHA256'] or len(expected) != entry['bytes']:
            raise RuntimeError('Fixture hash or size mismatch: ' + entry['name'])
        size = C.c_size_t(max(1, len(expected)))
        out = C.create_string_buffer(size.value)
        status = decoder.BrotliDecoderDecompress(len(encoded), encoded, C.byref(size), out)
        if status != 1 or out.raw[:size.value] != expected:
            raise RuntimeError('Independent decode mismatch: ' + entry['name'])
        results.append(entry['name'])

    # Layout pinned to google/brotli 028fb5a c/common/dictionary.h. Test-only ABI;
    # no package source links against this library or depends on these functions.
    class Dictionary(C.Structure):
        _fields_ = [('bits', C.c_uint8 * 32), ('offsets', C.c_uint32 * 32),
                    ('size', C.c_size_t), ('data', C.c_void_p)]
    common.BrotliGetDictionary.restype = C.POINTER(Dictionary)
    common.BrotliGetTransforms.restype = C.c_void_p
    common.BrotliTransformDictionaryWord.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_void_p, C.c_int]
    common.BrotliTransformDictionaryWord.restype = C.c_int
    dictionary = common.BrotliGetDictionary().contents
    transforms = common.BrotliGetTransforms()
    if dictionary.size != 122784 or not dictionary.data or not transforms:
        raise RuntimeError('Unexpected independent dictionary ABI or size')
    blob = C.string_at(dictionary.data, dictionary.size)
    source = root / 'Sources/SwiftJXLCore/Brotli/BrotliStaticDictionary.swift'
    strings = source.read_text().split('private static let dataBase64: [String] = [', 1)[1].split('    ]', 1)[0]
    embedded = base64.b64decode(''.join(re.findall(r'"([A-Za-z0-9+/=]+)"', strings)), validate=True)
    vectors = json.loads((fixtures / 'transforms.json').read_text())
    if embedded != blob or sha(blob) != vectors['dictionarySHA256']:
        raise RuntimeError('Embedded dictionary does not match independent Brotli')
    for vector in vectors['vectors']:
        offset, length, transform = vector['offset'], vector['length'], vector['transform']
        if not (4 <= length <= 24 and 0 <= offset <= len(blob) - length and 0 <= transform < 121):
            raise RuntimeError('Invalid transform fixture range')
        out = C.create_string_buffer(128)
        size = common.BrotliTransformDictionaryWord(out, dictionary.data + offset, length, transforms, transform)
        if not (0 <= size <= 128) or out.raw[:size].hex() != vector['output']:
            raise RuntimeError('Independent dictionary transform mismatch')
    report = dict(status='passed', compressedStreams=len(results), dictionaryTransforms=len(vectors['vectors']), skips=0,
                  decoderLibrary=decoder_path, commonLibrary=common_path, version=decoder.BrotliDecoderVersion(),
                  dictionarySHA256=sha(blob), manifestSHA256=sha((fixtures / 'decoder.json').read_bytes()),
                  transformsSHA256=sha((fixtures / 'transforms.json').read_bytes()), scriptSHA256=sha(Path(__file__).read_bytes()),
                  streams=results)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('Independent Brotli decoder fixtures passed:', len(results), 'streams,', len(vectors['vectors']), 'transforms')


if __name__ == '__main__':
    main()
