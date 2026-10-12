# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import struct,subprocess,math,json,sys
p=Path(sys.argv[1]); oracle=Path(sys.argv[2]); results=[]
for f in sorted(p.glob('*.jxl')):
 _,w,h,ch,bits,large=f.stem.split('-');bits=int(bits);ch=int(ch)
 o=f.with_suffix('.scalar');subprocess.run([str(oracle),'decode-float',str(f),str(o)],check=True)
 raw=f.with_suffix('.decoded').read_bytes();src=f.with_suffix('.input').read_bytes()
 actual=list(raw) if bits==8 else list(struct.unpack('<'+'H'*(len(raw)//2),raw))
 source=list(src) if bits==8 else list(struct.unpack('<'+'H'*(len(src)//2),src))
 expected=[int(min(1,max(0,v))*((1<<bits)-1)+.5) for v in struct.unpack('<'+'f'*(o.stat().st_size//4),o.read_bytes())]
 assert len(actual)==len(expected)==len(source)
 err=[abs(a-b) for i,(a,b) in enumerate(zip(actual,expected)) if ch%2 or i%ch!=ch-1]
 alpha=all(a==b==source[i] for i,(a,b) in enumerate(zip(actual,expected)) if ch%2==0 and i%ch==ch-1)
 peak=max(err);rms=math.sqrt(sum(v*v for v in err)/len(err))
 results.append({'name':f.stem,'peakLSB':peak,'rmsLSB':rms,'alphaExact':alpha,'passed':peak<=2 and rms<=.5 and alpha})
print(json.dumps(results,indent=2));(p.parent/'independent-oracles.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['passed'] for r in results)
