#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate twelve synthetic standard BT.709 PNM/PAM mutation seeds."""
import argparse
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
for channels in range(1, 5):
    for bits in [8, 12, 16]:
        w, h, maximum = 17, 3, (1 << bits)-1
        raw = b''.join(((i*71+(i//w)*37+c*113) & maximum).to_bytes(1 if bits == 8 else 2, 'big')
                       for i in range(w*h) for c in range(channels))
        if channels in [1, 3]:
            header = f'P{5 if channels == 1 else 6}\n# synthetic mutation seed\n{w} {h}\n{maximum}\n'
            suffix = 'pgm' if channels == 1 else 'ppm'
        else:
            tuple_type = 'GRAYSCALE_ALPHA' if channels == 2 else 'RGB_ALPHA'
            header = f'P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {channels}\nMAXVAL {maximum}\nTUPLTYPE {tuple_type}\nENDHDR\n'
            suffix = 'pam'
        (a.output/f'bt709-{channels}-{bits}.{suffix}').write_bytes(header.encode()+raw)
