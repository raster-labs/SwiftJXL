#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Byte-exact native JPEG CLI, independent interoperability and publication checks."""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--reference-tools',type=Path,required=True)
a=p.parse_args();binary=a.binary.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
repo=Path(__file__).resolve().parent.parent
report={'status':'running','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'checks':[]}
def save():(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(args,expected=0,input=None):
 r=subprocess.run(list(map(str,args)),input=input,capture_output=True,timeout=30)
 report['checks'].append({'argv':list(map(str,args)),'exit':r.returncode,'expected':expected,'stderr':r.stderr.decode(errors='replace')})
 save();assert r.returncode==expected,(args,r.returncode,r.stderr);return r
def cli(source,target,extra=(),input=None,expected=0):
 return run([binary,'transcode','-i',source,'--input-format','jpeg' if target=='jxl' else 'jxl','--output-format',target,*extra],expected,input)
try:
 for folder in ['JPEG','JPEGBridge']:
  for source in sorted((repo/'Tests/SwiftJXLCoreTests/Fixtures'/folder).glob('*.jpg')):
   expected=source.read_bytes();name=source.stem
   native=out/(name+'.jxl');restored=out/(name+'.jpg')
   result=cli(source,'jxl',['-o',native,'--json']);assert not result.stdout
   assert json.loads(result.stderr)['fidelity']=='original-bitstream'
   cli(native,'jpeg',['-o',restored]);assert restored.read_bytes()==expected
   oracle=out/(name+'-oracle.jpg')
   run([a.reference_tools/'djxl',native,oracle,'--quiet']);assert oracle.read_bytes()==expected
   reference=out/(name+'-reference.jxl')
   run([a.reference_tools/'cjxl',source,reference,'--lossless_jpeg=1','--quiet'])
   result=cli(reference,'jpeg');assert result.stdout==expected
 # Binary stdin/stdout, no filesystem intermediate needed by either command.
 source=repo/'Tests/SwiftJXLCoreTests/Fixtures/JPEG/gray.jpg';data=source.read_bytes()
 encoded=cli('-','jxl',input=data).stdout
 assert cli('-','jpeg',input=encoded).stdout==data
 # Failure cannot replace an existing final file or emit a success report.
 existing=out/'preserved.jpg';existing.write_bytes(b'previous')
 cli('-','jpeg',['-o',existing,'--overwrite','--json'],input=b'bad',expected=3)
 assert existing.read_bytes()==b'previous'
 cli(source,'jxl',['-o',existing],expected=6);assert existing.read_bytes()==b'previous'
 cli(source,'jxl',['-o',source,'--overwrite'],expected=6);assert source.read_bytes()==data
 cli(source,'jxl',['--mode','lossy'],expected=4)
 cli(source,'jxl',['--max-error','1'],expected=2)
 cli(source,'jxl',['--max-memory','1'],expected=5)
 cli(source,'jxl',['--timeout','0.000000001'],expected=5)
 run([binary,'transcode','-i',source],expected=2)
 run([binary,'transcode','-i',source,'--input-format','jpeg','--output-format','jpeg'],expected=4)
 report['status']='passed';save();print(len(report['checks']),'native JPEG CLI process checks passed')
except BaseException:
 report['status']='failed';save();raise
