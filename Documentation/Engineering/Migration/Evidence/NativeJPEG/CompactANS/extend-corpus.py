# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import json,subprocess,hashlib
w=Path(__file__).resolve().parent;manifest=json.loads((w/'fixture-manifest.json').read_text());rows=[]
cases=[('gray-flat',513,257,1,'flat'),('gray-ramp',512,511,1,'ramp'),('gray-noise',257,257,1,'noise'),('rgb-ramp',513,259,3,'ramp'),('rgb-noise444',257,257,3,'noise'),('rgb-flat420',1025,17,3,'flat'),('rgb-textured420',1024,1024,3,'texture'),('rgb-boundary444',257,8,3,'texture')]
for name,width,height,channels,pattern in cases:
 data=bytearray();seed=20261013
 for y in range(height):
  for x in range(width):
   for c in range(channels):
    seed=(seed*1664525+1013904223)&0xffffffff
    v=127 if pattern=='flat' else (x+3*y+c*53)&255 if pattern=='ramp' else seed>>24 if pattern=='noise' else ((x*11+y*7+c*43)^((x//9+y//13)*29))&255
    data.append(v)
 p=w/'inputs'/(name+'.pnm');p.write_bytes(('P5' if channels==1 else 'P6').encode()+f'\n{width} {height}\n255\n'.encode()+data)
 jpeg=p.with_suffix('.jpg');cmd=['/opt/homebrew/bin/cjpeg','-quality','90','-dct','int']
 if channels==1:cmd+=['-grayscale']
 else:cmd+=['-sample','2x2' if '420' in name or name=='rgb-ramp' else '1x1']
 cmd+=['-outfile',str(jpeg),str(p)];r=subprocess.run(cmd,capture_output=True,text=True);assert r.returncode==0,r.stderr
 rows.append({'name':name,'generator':'extend-corpus.py; seed 20261013','width':width,'height':height,'pattern':pattern,'command':cmd,'exit':r.returncode,'pnmSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'sha256':hashlib.sha256(jpeg.read_bytes()).hexdigest(),'bytes':jpeg.stat().st_size})
(w/'extended-fixtures.json').write_text(json.dumps({'cjpegSHA256':hashlib.sha256(Path('/opt/homebrew/bin/cjpeg').resolve().read_bytes()).hexdigest(),'version':subprocess.run(['/opt/homebrew/bin/cjpeg','-version'],capture_output=True,text=True).stderr,'fixtures':rows},indent=2)+'\n')
(w/'fixture-manifest-original.json').write_text(json.dumps(manifest,indent=2)+'\n');(w/'fixture-manifest.json').write_text(json.dumps(manifest+rows,indent=2)+'\n');print('Eight synthetic multi-group JPEGs generated.')
