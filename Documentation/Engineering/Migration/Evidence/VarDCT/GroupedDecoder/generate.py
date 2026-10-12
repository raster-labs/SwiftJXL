# SPDX-License-Identifier: Apache-2.0
# Reproduce fixtures with the separately compiled oracle.c linked to pinned
# libjxl a7a9c787341cf703dede03c2009fa460cae5e5df scalar build.
from pathlib import Path
import json, struct, subprocess, sys
oracle, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
for case in json.loads(Path(__file__).with_name('cases.json').read_text()):
    w,h,ch,bits = (case[k] for k in ('width','height','channels','bits'))
    name = case['name']; raw = bytearray()
    for y in range(h):
        for x in range(w):
            for c in range(ch):
                v = ((x*3+y*5+c*37)%256) if c!=ch-1 or ch%2 else ((x*17+y*31)%256)
                raw.extend(struct.pack('<H',v*257) if bits==16 else bytes([v]))
    source = output/(name+'.input'); source.write_bytes(raw)
    subprocess.run([str(oracle),'encode',str(source),str(output/(name+'.jxl')),str(w),str(h),str(ch),str(bits)],check=True)
    subprocess.run([str(oracle),'decode-float',str(output/(name+'.jxl')),str(output/(name+'.scalar-oracle'))],check=True)
