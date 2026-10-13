# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import json,hashlib,subprocess,sys
w=Path(__file__).resolve().parent;repo=Path(json.loads((w/'config.json').read_text())['successor']);d=w/'inputs';d.mkdir(exist_ok=True);rows=[]
for name in ['gray','progressive-edge','quant16','multigroup-420','icc-rgb','icc-gray','rgb','rgb-progressive']:
 folder='JPEGBridge' if name in ['quant16','multigroup-420','rgb','rgb-progressive'] else 'JPEG';base='444' if name=='icc-rgb' else 'gray' if name=='icc-gray' else name
 p=repo/'Tests/SwiftJXLCoreTests/Fixtures'/folder/(base+'.jpg');b=p.read_bytes();sources=[str(p)]
 if name.startswith('icc-'):
  profile=repo/'Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge'/('gray-gamma22.icc' if name=='icc-gray' else 'srgb.icc');payload=b'ICC_PROFILE\0'+bytes([1,1])+profile.read_bytes();b=b[:2]+b'\xff\xe2'+(len(payload)+2).to_bytes(2,'big')+payload+b[2:];sources.append(str(profile))
 (d/(name+'.jpg')).write_bytes(b);rows.append({'name':name,'sources':sources,'sha256':hashlib.sha256(b).hexdigest(),'bytes':len(b)})
(w/'fixture-manifest.json').write_text(json.dumps(rows,indent=2)+'\n')
subprocess.run([sys.executable,str(w/'extend-corpus.py')],check=True)
