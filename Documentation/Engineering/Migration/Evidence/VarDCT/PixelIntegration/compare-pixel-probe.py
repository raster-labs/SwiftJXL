from pathlib import Path
import math,json,sys
root=Path('work/vardct-preflight');directory=Path(sys.argv[1]);source=Path('work/SwiftJXL/Tests/SwiftJXLCoreTests/Fixtures/VarDCT');results=json.loads((directory/'results.json').read_text())
for r in results:
 if r.get('stage')!='pixels':continue
 n=r['name'];c=int(r['channels']);bits=int(r['bits']);maximum=(1<<bits)-1
 pixels=list(memoryview((directory/(n+'.decoded')).read_bytes()).cast('B' if bits==8 else 'H'))
 for label,path,kind in [('originalInteger',source/(n+'.oracle'),'integer'),('pinnedScalarFloatNearest',root/'scalar-oracle'/(n+'.float'),'float')]:
  values=list(memoryview(path.read_bytes()).cast('f' if kind=='float' else ('B' if bits==8 else 'H')))
  if kind=='float':values=[max(0,min(maximum,int(v*maximum+.5)))for v in values]
  dif=[abs(a-b)for i,(a,b) in enumerate(zip(pixels,values)) if c%2 or i%c!=c-1];alpha=all(pixels[i]==values[i]for i in range(c-1,len(pixels),c)) if c%2==0 else True
  rms=math.sqrt(sum(x*x for x in dif)/len(dif));r[label]={'maximum':max(dif),'rms':rms,'alphaExact':alpha,'withinUnchangedNumericalLimits':max(dif)<=2 and rms<=.5 and alpha}
(directory/'comparisons.json').write_text(json.dumps(results,indent=2)+'\n')
for r in results:print(r['name'],r['decode'],r.get('originalInteger',''),r.get('pinnedScalarFloatNearest',''))
