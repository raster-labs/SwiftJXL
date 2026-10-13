# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,json,statistics,math,time,sys,os
w=Path(__file__).resolve().parent;o=w/'fresh'; label=sys.argv[1]; rows=[]; out=o/(label+'.json'); variants={'predecessor':w/'fresh','successor':w/sys.argv[2]}
who=['predecessor','successor'];cases=[]
reports={x:json.loads((variants[x]/'successor-preflight.json').read_text()) for x in who}
for a,b in zip(reports['predecessor']['cases'],reports['successor']['cases']):
 if all(r['exit']==0 and all(v['exit']==0 for v in r['oracle']) and r['oracle'][0]['exactJPEG'] for r in [a,b]):cases.append(a['fixture'])
start=time.time()
for block,order in enumerate([who,who[::-1]]):
 for name in cases:
  for direction in ['forward','reverse']:
   for codec in order:
    cmd=[str(variants[codec]/'successor'),direction,str(w/'inputs'/(name+'.jpg')),str(variants[codec]/'streams'/('successor-'+name+'.jxl'))]
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=120,env={**os.environ,"SWIFT_DETERMINISTIC_HASHING":"1"})
    row={'block':block,'fixture':name,'codec':codec,'command':cmd,'exit':r.returncode,'stderr':r.stderr,'result':json.loads(r.stdout) if r.stdout else None};rows.append(row)
    out.write_text(json.dumps({'rows':rows,'seconds':time.time()-start},indent=2)+'\n')
    if r.returncode:raise RuntimeError(row)
 print('block',block,'passed',flush=True)
summary=[]
for name in cases:
 row={'fixture':name}
 for direction in ['forward','reverse']:
  data={c:[v for r in rows if r['fixture']==name and r['codec']==c and r['result']['direction']==direction for v in r['result']['samplesMicroseconds']] for c in who}
  row[direction]={c:{'medianUs':statistics.median(x),'p95Us':sorted(x)[math.ceil(.95*len(x))-1],'minUs':min(x),'maxUs':max(x),'n':len(x)} for c,x in data.items()}
  row[direction]['medianChangePercent']=(statistics.median(data['successor'])/statistics.median(data['predecessor'])-1)*100
 sizes={c:next(r['result']['outputBytes'] for r in rows if r['fixture']==name and r['codec']==c) for c in who}
 row['encodedBytes']=sizes;row['sizeChangePercent']=(sizes['successor']/sizes['predecessor']-1)*100
 summary.append(row)
(o/(label+'-summary.json')).write_text(json.dumps(summary,indent=2)+'\n')
for row in summary:print(row['fixture'],'forward',round(row['forward']['medianChangePercent'],1),'reverse',round(row['reverse']['medianChangePercent'],1),'size',round(row['sizeChangePercent'],1),flush=True)
