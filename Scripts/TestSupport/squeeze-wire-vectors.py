# SPDX-License-Identifier: Apache-2.0
"""Synthetic LSB wire vectors specified independently of Swift readers/writers.

Field distributions: libjxl a7a9c787341cf703dede03c2009fa460cae5e5df,
lib/jxl/modular/transform/{transform,squeeze_params}.cc::VisitFields.
"""
import json
from pathlib import Path

vectors = []
for selector, count in [(0, 0), (1, 1), (1, 8), (1, 16), (2, 9), (2, 17),
                        (2, 40), (2, 72), (3, 41), (3, 73), (3, 256), (3, 296)]:
    bits = []
    def put(value, width):
        bits.extend((value >> i) & 1 for i in range(width))
    put(2, 2)  # Squeeze transform kind.
    put(selector, 2)
    if selector:
        put(count - [0, 1, 9, 41][selector], [0, 4, 6, 8][selector])
    params = []
    for i in range(count):
        horizontal, in_place = bool(i % 2), bool(i % 3)
        begin = [0, 7, 8, 71, 72, 1095, 1096, 9287][i % 8]
        num = [1, 2, 3, 4, 19][i % 5]
        put(horizontal, 1); put(in_place, 1)
        begin_selector = 0 if begin < 8 else 1 if begin < 72 else 2 if begin < 1096 else 3
        put(begin_selector, 2)
        put(begin - [0, 8, 72, 1096][begin_selector], [3, 6, 10, 13][begin_selector])
        put(min(num - 1, 3), 2)
        if num >= 4:
            put(num - 4, 4)
        params.append(dict(horizontal=horizontal, inPlace=in_place, beginC=begin, numC=num))
    payload_bits = len(bits)
    put(0xB7, 8)  # Marker detects over/under-consumption without a round-trip assumption.
    bits.extend([0] * ((-len(bits)) % 8))
    data = [sum(bits[start + j] << j for j in range(8)) for start in range(0, len(bits), 8)]
    canonical = (selector == (0 if count == 0 else 1 if count <= 16 else 2 if count <= 72 else 3))
    vectors.append(dict(selector=selector, count=count, parameters=params, payloadBits=payload_bits,
                        canonical=canonical, bytes=data))
Path('Tests/SwiftJXLCoreTests/Fixtures/Modular/squeeze-wire.json').write_text(json.dumps(vectors, separators=(',', ':')) + '\n')
