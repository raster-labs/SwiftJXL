#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded PNM CLI, independent libjxl sample and colour interpretation checks."""
import argparse, hashlib, json, subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--info-oracle', type=Path, required=True)
p.add_argument('--reference-tools', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
report = {'status': 'running', 'binarySHA256': hashlib.sha256(a.binary.read_bytes()).hexdigest(),
          'scriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'checks': []}
def save(): (a.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
def run(command, payload=None, expected=0):
    r = subprocess.run([str(a.binary), *map(str, command)], input=payload, capture_output=True, timeout=20)
    report['checks'].append({'command': list(map(str, command)), 'exit': r.returncode, 'expected': expected,
                             'stderr': r.stderr.decode(errors='replace')})
    save()
    assert r.returncode == expected, (command, r.returncode, r.stderr)
    if expected: assert not r.stdout
    return r.stdout
def encode(data, fmt='pnm', expected=0, extra=()):
    return run(['encode', '-i', '-', '--input-format', fmt, *extra], data, expected)
def decode(data, fmt='pnm', expected=0, extra=()):
    return run(['decode', '-i', '-', '--output-format', fmt, *extra], data, expected)
def header(w,h,c,b):
    if c % 2:
        return f'P{5 if c==1 else 6}\n{w} {h}\n{(1<<b)-1}\n'.encode()
    return f'P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {c}\nMAXVAL {(1<<b)-1}\nTUPLTYPE {"GRAYSCALE_ALPHA" if c==2 else "RGB_ALPHA"}\nENDHDR\n'.encode()

try:
    fixtures = Path(__file__).resolve().parents[1]/'Tests/SwiftJXLCoreTests/Fixtures/Modular/Transfer'
    for c in [1,2,3,4]:
        for bits in [8,12,16]:
            w,h=513,3
            samples=b''.join(((i*71+(i//w)*37+ch*113)&((1<<bits)-1)).to_bytes(1 if bits==8 else 2,'big')
                             for i in range(w*h) for ch in range(c))
            source=header(w,h,c,bits)+samples
            independent=(fixtures/f'bt709-{c}-{bits}.jxl').read_bytes()
            assert decode(independent)==source
            decode(independent,'pnm-srgb',expected=4)
            for fmt in ['pnm','pnm-srgb']:
                encoded=encode(source,fmt)
                assert decode(encoded,fmt)==source
                decode(encoded,'pnm-srgb' if fmt=='pnm' else 'pnm',expected=4)
                inspected=json.loads(run(["inspect","-i","-","--json"],encoded))
                assert inspected["colourTransfer"]==("bt709" if fmt=="pnm" else "srgb")
                dest=a.output/f'{fmt}-{c}-{bits}.jxl';dest.write_bytes(encoded)
                info=json.loads(subprocess.check_output([str(a.info_oracle),str(dest)]))
                assert info['transferFunction']==(1 if fmt=='pnm' else 13)
                assert info['bits']==bits and info['alphaBits']==(bits if c%2==0 else 0) and info['premultiplied']==0
                output=dest.with_suffix('.pam')
                oracle=subprocess.run([str(a.reference_tools/'djxl'),str(dest),str(output),f'--bits_per_sample={bits}','--quiet'],capture_output=True,timeout=20)
                exact=oracle.returncode==0 and output.read_bytes().endswith(samples)
                report['checks'].append({'oracle':str(dest),'exit':oracle.returncode,'exactSamples':exact,'metadata':info})
                save();assert exact,(dest,oracle.stderr)
    for first in [0,9,10,13,32,35,255]:
        src=b'P5\n# comment\n1\t1\n255\n'+bytes([first])
        assert decode(encode(src))==header(1,1,1,8)+bytes([first])
    for bits in range(9,16):
        for c in [1,4]:
            samples=b''.join(v.to_bytes(2,'big') for v in [0,(1<<bits)-1]*c)
            src=header(2,1,c,bits)+samples
            assert decode(encode(src))==src
    bad=[(b'',3),(b'P3\n1 1\n255\n0',3),(b'P5\n0 1\n255\n',3),
         (b'P5\n1025 1\n255\n',5),(b'P5\n1 1\n100\n\0',4),
         (b'P5\n1 1\n65536\n\0\0',3),(b'P5\n1 1\n4095\n\x10\0',3),
         (header(1,1,1,8),3),(header(1,1,1,8)+b'\0\0',3),
         (b'P5\n'+b'9'*65+b' 1\n255\n\0',5),(b'P5\n#'+b'x'*16384+b'\n1 1\n255\n\0',5),
         (b'P7\n'+b'# comment\n'*64+b'ENDHDR\n',5),
         (header(1,1,4,8).replace(b'RGB_ALPHA',b'CMYK')+b'\0'*4,4),
         (header(1,1,4,8).replace(b'WIDTH 1',b'WIDTH 1\nWIDTH 1')+b'\0'*4,3),
         (header(1,1,4,8).replace(b'ENDHDR',b'UNKNOWN 1\nENDHDR')+b'\0'*4,4),
         (header(1,1,4,8).replace(b'DEPTH 4',b'DEPTH 3')+b'\0'*4,4)]
    for data,code in bad:encode(data,expected=code)
    src=header(3,2,3,8)+bytes(range(18));encoded=encode(src)
    # Bounded truncation coverage includes every header and sample position.
    for length in range(len(src)):encode(src[:length],expected=3)
    encode(src,expected=5,extra=['--max-memory','1'])
    target=a.output/'colour image λ.ppm';target.write_bytes(b'keep')
    decode(encoded,expected=6,extra=['-o',target]);assert target.read_bytes()==b'keep'
    decode(encoded,extra=['-o',target,'--overwrite']);assert target.read_bytes()==src
    decode(encoded,'pnm-srgb',expected=4,extra=['-o',target,'--overwrite']);assert target.read_bytes()==src
    sourcefile=a.output/'source with spaces.ppm';sourcefile.write_bytes(src)
    assert run(['encode','-i',sourcefile,'--input-format','pnm'])==encoded
    caps=json.loads(run(['capabilities','--json']));assert 'pnm' in caps['interchangeFormats']
    # Associated alpha cannot be exported as unassociated PAM.
    alpha=fixtures.parent/'Alpha/premult-4-16.jxl'
    decode(alpha.read_bytes(),'pnm-srgb',expected=4)
    report['status']='passed'
except BaseException as e:
    report['status']='failed';report['failure']=repr(e);raise
finally:save()
print(f"Passed {len(report['checks'])} PNM CLI/oracle checks")
