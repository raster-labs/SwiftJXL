"""Offline diagnostic; no codec execution or acceptance-record edits."""
from pathlib import Path
import struct, math, json
root = Path(__file__).resolve().parent
base = root.parent / 'encoder-large-writer'
def pixels(path, floating=False):
    b = path.read_bytes()
    values = struct.unpack('<' + ('f' if floating else 'H') * (len(b)//(4 if floating else 2)), b)
    return [int(min(1,max(0,v))*65535+.5) for v in values] if floating else values
def compare(a,b):
    assert len(a)==len(b)
    d=[x-y for x,y in zip(a,b)]
    return dict(samples=len(d),peakLSB=max(map(abs,d)),rmsLSB=math.sqrt(sum(x*x for x in d)/len(d)),differentSamples=sum(x!=0 for x in d))
arm=pixels(root.parent/'writer-4-arm-float.bin',True)
integer=pixels(base/'writer-4.oracle')
swift=pixels(base/'writer-4.decoded')
scalar=pixels(base/'writer-4.scalar',True)
result=dict(armIntegerVsArmFloatNearest=compare(integer,arm),savedSwiftVsArmFloatNearest=compare(swift,arm),scalarVsArmFloatNearest=compare(scalar,arm),variants={})
for mode in ['original','exact-unfused','exact-fused','approx-unfused','approx-fused']:
    v=pixels(root/(mode+'.decoded'))
    result['variants'][mode]=dict(vsArmFloatNearest=compare(v,arm),vsSavedSwift=compare(v,swift),vsArmInteger=compare(v,integer))
assert result == json.loads((root/'results.json').read_text())
print(json.dumps(result,indent=2))
