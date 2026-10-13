# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,json,hashlib,sys,time
w=Path(__file__).resolve().parent;c=json.loads((w/'config.json').read_text());name=sys.argv[1]; root=Path(c['predecessor' if name=='JXLSwift' else 'successor']);out=w/(sys.argv[2] if len(sys.argv)>2 else 'fresh');out.mkdir(exist_ok=True)
sources=sorted((root/'Sources'/name).glob('**/*.swift'))
cmd=['xcrun','swiftc','-O','-g','-whole-module-optimization','-swift-version','6','-strict-concurrency=complete','-parse-as-library','-package-name','JXLSwift' if name=='JXLSwift' else 'SwiftJXL','-module-name',name,'-module-cache-path',str(out/'cache'),'-I',str(out),'-emit-module','-emit-module-path',str(out/(name+'.swiftmodule')),'-emit-library','-static',*map(str,sources),'-o',str(out/('lib'+name+'.a'))]
start=time.time()
with (out/(name+'-build.log')).open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=900)
report={'command':cmd,'exit':r.returncode,'seconds':time.time()-start,'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceHashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
(out/(name+'-build.json')).write_text(json.dumps(report,indent=2)+'\n');print(name,r.returncode,round(report['seconds'],1),flush=True)
if r.returncode:print((out/(name+'-build.log')).read_text()[-3000:])
sys.exit(r.returncode)
