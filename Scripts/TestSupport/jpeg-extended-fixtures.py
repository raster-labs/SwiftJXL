#!/usr/bin/env python3
"""Deterministic, synthetic T.81 JPEG source fixtures (Apache-2.0).
No runtime codec is used. Emits original samples, reconstructed samples and hashes.
Usage: python3 jpeg-extended-fixtures.py OUTPUT_DIRECTORY
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import sys


def marker(code, payload):
    return bytes([255, code]) + struct.pack('>H', len(payload) + 2) + payload


class Bits:
    def __init__(self):
        self.bits = ''

    def write(self, value, count):
        self.bits += format(value, f'0{count}b') if count else ''

    def flush(self):
        text = self.bits + '1' * (-len(self.bits) % 8)
        self.bits = ''
        return bytes(int(text[i:i+8], 2) for i in range(0, len(text), 8)).replace(b'\xff', b'\xff\0')


def extended_magnitude(bits, difference):
    category = abs(difference).bit_length()
    bits.write(category, 5)
    if category != 16:
        bits.write(difference if difference >= 0 else difference + (1 << category) - 1, category)


def sof3(samples, width, height, precision, predictor=1, point=0, restart=0, split=False):
    channels = len(samples[0])
    header = bytes([precision]) + struct.pack('>HHB', height, width, channels)
    header += b''.join(bytes([i+1, 0x11, 0]) for i in range(channels))
    # All difference categories have a five-bit canonical Huffman code.
    dht = bytes([0]) + bytes([0, 0, 0, 0, 17] + [0] * 11) + bytes(range(17))
    data = b'\xff\xd8' + marker(0xc3, header) + marker(0xc4, dht)
    if restart:
        data += marker(0xdd, struct.pack('>H', restart))
    scans = [[i] for i in range(channels)] if split else [list(range(channels))]
    p = precision - point
    mask = (1 << p) - 1
    for scan in scans:
        data += marker(0xda, bytes([len(scan)]) + b''.join(bytes([i+1, 0]) for i in scan) + bytes([predictor, 0, point]))
        bits, first_row, rst = Bits(), 0, 0
        for y in range(height):
            for x in range(width):
                index = y * width + x
                if restart and index and index % restart == 0:
                    data += bits.flush() + bytes([255, 0xd0 + rst])
                    first_row, rst = y, (rst + 1) % 8
                for c in scan:
                    a = samples[index-1][c] >> point if x else 0
                    b = samples[index-width][c] >> point if y else 0
                    prev = samples[index-width-1][c] >> point if x and y else 0
                    if y == first_row:
                        predicted = a if x else 1 << (p-1)
                    elif x == 0:
                        predicted = b
                    else:
                        predicted = [a, b, prev, a+b-prev, a+((b-prev)>>1), b+((a-prev)>>1), (a+b)>>1][predictor-1]
                    difference = ((samples[index][c] >> point) - predicted) & 65535
                    if difference >= 32768:
                        difference -= 65536
                    extended_magnitude(bits, difference)
        data += bits.flush()
    return data + b'\xff\xd9'


def dct12(progressive=False, dc=0, ac=0, rgb=False, refine=False):
    channels = 3 if rgb else 1
    header = bytes([12, 0, 8, 0, 8, channels])
    header += b''.join(bytes([c, 0x11, 0]) for c in ([82,71,66] if rgb else [1]))
    dc_table = bytes([0]) + bytes([0,0,0,0,16]+[0]*11) + bytes(range(16))
    initial_ac = (abs(ac) >> 1) * (-1 if ac < 0 else 1) if refine else ac
    ac_category = abs(initial_ac).bit_length()
    ac_table = bytes([0x10]) + bytes([1,1]+[0]*14) + bytes([0, ac_category or 1])
    data = b'\xff\xd8' + marker(0xc2 if progressive else 0xc1, header)
    data += marker(0xdb, b'\0' + bytes([1]*64)) + marker(0xc4, dc_table+ac_table)
    ids = [82,71,66] if rgb else [1]
    def write_dc(bits, value):
        n = abs(value).bit_length()
        bits.write(n, 5)
        bits.write(value if value >= 0 else value+(1<<n)-1, n)
    if progressive:
        data += marker(0xda, bytes([channels])+b''.join(bytes([c,0]) for c in ids)+bytes([0,0,1 if refine else 0]))
        bits = Bits()
        for _ in ids:
            write_dc(bits, dc >> 1 if refine else dc)
        data += bits.flush()
        for c in ids:
            data += marker(0xda, bytes([1,c,0,1,63,1 if refine else 0]))
            bits = Bits()
            if initial_ac:
                bits.write(2,2)
                bits.write(initial_ac if initial_ac >= 0 else initial_ac+(1<<ac_category)-1, ac_category)
            bits.write(0,1)
            data += bits.flush()
        if refine:
            data += marker(0xda, bytes([channels])+b''.join(bytes([c,0]) for c in ids)+bytes([0,0,0x10]))
            bits = Bits()
            for _ in ids:
                bits.write(dc & 1, 1)
            data += bits.flush()
            for c in ids:
                data += marker(0xda, bytes([1,c,0,1,63,0x10]))
                bits = Bits()
                bits.write(0,1)
                if initial_ac:
                    bits.write(abs(ac) & 1,1)
                data += bits.flush()
    else:
        data += marker(0xda, bytes([channels])+b''.join(bytes([c,0]) for c in ids)+bytes([0,63,0]))
        bits = Bits()
        for _ in ids:
            write_dc(bits,dc)
            if ac:
                bits.write(2,2)
                bits.write(ac if ac >= 0 else ac+(1<<ac_category)-1,ac_category)
            bits.write(0,1)
        data += bits.flush()
    expected = []
    for y in range(8):
        for x in range(8):
            value = dc / 8 + ac * math.cos((2*x+1)*math.pi/16) / (4*math.sqrt(2))
            rounded = math.floor(value+0.5) if value >= 0 else math.ceil(value-0.5)
            expected.append([min(4095,max(0,2048+rounded))] * channels)
    return data+b'\xff\xd9', expected


def exif(orientation=1, little=True):
    endian = '<' if little else '>'
    short = lambda x: struct.pack(endian+'H',x)
    long = lambda x: struct.pack(endian+'I',x)
    entry = lambda tag,typ,n,value: short(tag)+short(typ)+long(n)+value
    # IFD0 -> Exif IFD with explicit sRGB, no patient or personal metadata.
    tiff = (b'II' if little else b'MM')+short(42)+long(8)+short(2)
    tiff += entry(0x112,3,1,short(orientation)+b'\0\0')
    tiff += entry(0x8769,4,1,long(38))+long(0)
    tiff += short(1)+entry(0xa001,3,1,short(1)+b'\0\0')+long(0)
    return b'Exif\0\0'+tiff


def generate(output):
    output.mkdir(parents=True,exist_ok=True)
    manifest=[]
    (output/'malformed-out-of-range.invalid').write_bytes(sof3([[300]],1,1,8))
    def save(name,data,samples,width,height,precision,**extra):
        raw=b''.join(struct.pack('<H',s) for pixel in samples for s in pixel)
        (output/(name+'.jpg')).write_bytes(data)
        (output/(name+'.raw')).write_bytes(raw)
        info=dict(name=name,width=width,height=height,precision=precision,channels=len(samples[0]),
                  interpretation='srgb',fidelity='lossless',samples=[s for pixel in samples for s in pixel],
                  jpegSHA256=hashlib.sha256(data).hexdigest(),rawSHA256=hashlib.sha256(raw).hexdigest(),
                  provenance='Synthetic T.81 generator jpeg-extended-fixtures.py; Apache-2.0',**extra)
        manifest.append(info)
    for precision in [2,8,12,16]:
        maximum=(1<<precision)-1
        samples=[[v&maximum] for v in [0,maximum,1,maximum//2,3,maximum-1,7,13,5,0,maximum,2]]
        for predictor in range(1,8):
            for point in [0,min(2,precision-1)]:
                reconstructed=[[p[0]>>point<<point] for p in samples]
                name=f'sof3-p{precision}-predictor{predictor}-pt{point}'
                save(name,sof3(samples,4,3,precision,predictor,point,8),reconstructed,4,3,precision,
                     pointTransform=point,originalSamples=[p[0] for p in samples])
                manifest[-1]['fidelity']='lossy' if point else 'lossless'
    extreme=[[255],[0],[0],[255]]
    save('sof3-predictor4-category9',sof3(extreme,2,2,8,4),extreme,2,2,8)
    rgb=[[0,65535,32768],[17,1,50000],[65535,0,1],[30000,60000,2],[16,32,64],[1,2,3]]
    for split in [False,True]:
        save('sof3-rgb-'+('split' if split else 'interleaved'),sof3(rgb,3,2,16,4,0,0,split),rgb,3,2,16)
    for progressive in [False,True]:
        for dc,ac in [(0,0),(-16384,0),(16376,0),(0,8192),(0,-8192),(20,1500)]:
            name=f'dct12-{progressive}-{dc}-{ac}'
            data,samples=dct12(progressive,dc,ac)
            save(name,data,samples,8,8,12)
            manifest[-1]['fidelity']='lossy'
    for dc,ac in [(21,1501),(-21,-1501)]:
        data,samples=dct12(True,dc,ac,refine=True)
        save(f'dct12-refined-{dc}-{ac}',data,samples,8,8,12)
        manifest[-1]['fidelity']='lossy'
    data,samples=dct12(rgb=True)
    save('dct12-rgb',data,samples,8,8,12)
    manifest[-1]['fidelity']='lossy'
    source=[[1],[2],[3],[4],[5],[6]]
    base=sof3(source,3,2,8)
    for orientation in range(1,9):
        for little in [False,True]:
            data=base[:2]+marker(0xe1,exif(orientation,little))+base[2:]
            save(f'exif-{orientation}-{little}',data,source,3,2,8,orientation=orientation)
            manifest[-1]['interpretation']='embedded-preserve'
    # Reuse the repository's independently generated real grey ICC profile.
    profile_path=Path(__file__).resolve().parents[2]/'Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge/gray-gamma22.icc'
    profile=profile_path.read_bytes()
    halves=[profile[:len(profile)//2],profile[len(profile)//2:]]
    segments=b''.join(marker(0xe2,b'ICC_PROFILE\0'+bytes([i+1,2])+halves[i]) for i in [1,0])
    save('icc-gray',base[:2]+segments+base[2:],source,3,2,8)
    manifest[-1]['interpretation']='embedded-preserve'
    (output/'gray.icc').write_bytes(profile)
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__':
    generate(Path(sys.argv[1]))
