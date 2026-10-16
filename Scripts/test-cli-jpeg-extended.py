#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify extended JPEG CLI precision against deterministic T.81 sample vectors.

Use an independent libjpeg build separately for interoperability. These vectors
are generated from the standard's predictive and inverse-transform equations.
"""
import argparse, hashlib, json, struct, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',type=Path,required=True)
p.add_argument('--fixtures',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
report={'status':'running','checks':[],'commands':[], 'binarySHA256':hashlib.sha256(a.binary.read_bytes()).hexdigest()}
def save():(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def call(args,expected=0):
 r=subprocess.run([str(a.binary),*map(str,args)],capture_output=True,timeout=60)
 report['commands'].append({'arguments':list(map(str,args)),'exitCode':r.returncode,'stderr':r.stderr.decode(errors='replace')});save()
 assert r.returncode==expected,report['commands'][-1]
 return r

def raster(data):
 if data.startswith(b'P7\n'):
  head,raw=data.split(b'ENDHDR\n',1);fields=dict(row.split(maxsplit=1) for row in head.splitlines()[1:] if row and not row.startswith(b'#'))
  w,h,c,m=[int(fields[k]) for k in [b'WIDTH',b'HEIGHT',b'DEPTH',b'MAXVAL']]
 else:
  magic,dimensions,maximum,raw=data.split(b'\n',3);w,h=map(int,dimensions.split());c=1 if magic==b'P5' else 3;m=int(maximum)
 values=list(raw) if m<256 else [v[0] for v in struct.iter_unpack('>H',raw)]
 return w,h,c,m,values
try:
 for case in json.loads((a.fixtures/'manifest.json').read_text()):
  jpeg=a.fixtures/(case['name']+'.jpg')
  expected=4 if case['interpretation']!='srgb' or case['precision']<8 else 0
  r=call(['decode','-i',jpeg,'--input-format','jpeg-srgb','--output-format','pnm-srgb','--json'],expected)
  if expected:
   assert not r.stdout
   report['checks'].append({'case':case['name'],'rejectedUnrepresentableInterpretation':True});continue
  w,h,c,m,samples=raster(r.stdout)
  assert (w,h,c,m)==(case['width'],case['height'],case['channels'],(1<<case['precision'])-1)
  assert samples==case['samples'],case['name']
  encoded=call(['encode','-i',jpeg,'--input-format','jpeg-srgb'])
  stream=a.output/(case['name']+'.jxl');stream.write_bytes(encoded.stdout)
  decoded=call(['decode','-i',stream,'--output-format','pnm-srgb'])
  assert raster(decoded.stdout)==raster(r.stdout)
  report['checks'].append({'case':case['name'],'exactSamples':True,'bits':case['precision'],
                           'jpegSHA256':hashlib.sha256(jpeg.read_bytes()).hexdigest(),
                           'fidelity':json.loads(r.stderr).get('fidelity')})
 report['status']='passed'
except BaseException as e:
 report['status']='failed';report['failure']=repr(e);raise
finally:save()
print('Extended JPEG CLI:',len(report['checks']),'cases')
