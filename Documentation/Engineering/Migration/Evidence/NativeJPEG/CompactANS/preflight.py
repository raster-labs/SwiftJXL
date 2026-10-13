# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import json,subprocess,hashlib,sys
w=Path(__file__).resolve().parent; who=sys.argv[1];o=w/(sys.argv[2] if len(sys.argv)>2 else 'fresh'); dest=o/'streams';dest.mkdir(exist_ok=True);rows=[]
for case in json.loads((w/'fixture-manifest.json').read_text()):
 name=case['name'];source=w/'inputs'/(name+'.jpg');stream=dest/(who+'-'+name+'.jxl');cmd=[str(o/who),'preflight',str(source),str(stream)]
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=120);row={'fixture':name,'command':cmd,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
 if stream.exists():
  row['jxlBytes']=stream.stat().st_size;row['jxlSHA256']=hashlib.sha256(stream.read_bytes()).hexdigest();row['oracle']=[]
  for ext in ['jpg','ppm']:
   target=dest/(who+'-'+name+'.'+ext);cmd=['/opt/homebrew/bin/djxl',str(stream),str(target)]
   q=subprocess.run(cmd,capture_output=True,text=True,timeout=120);z={'command':cmd,'exit':q.returncode,'stdout':q.stdout,'stderr':q.stderr}
   if target.exists():z.update({'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()})
   if ext=='jpg':z['exactJPEG']=target.exists() and target.read_bytes()==source.read_bytes()
   row['oracle'].append(z)
 rows.append(row);print(who,name,'native',r.returncode,'oracles',[(x['exit'],x.get('exactJPEG')) for x in row.get('oracle',[])],flush=True)
(o/(who+'-preflight.json')).write_text(json.dumps({'binarySHA256':hashlib.sha256((o/who).read_bytes()).hexdigest(),'cases':rows},indent=2)+'\n')

if who == "successor" and any(r["exit"] != 0 or len(r.get("oracle",[])) != 2 or not r["oracle"][0].get("exactJPEG",False) or any(v["exit"] != 0 for v in r["oracle"]) for r in rows):
 raise SystemExit(1)
