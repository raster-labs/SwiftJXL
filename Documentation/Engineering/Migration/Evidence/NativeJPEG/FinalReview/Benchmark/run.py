from pathlib import Path
import subprocess,json,hashlib,sys
root=Path('../native-jpeg-audit/native-final-review/benchmark')
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-module-cache-path','.build/module-cache','-package-name','SwiftJXL','-module-name','NativeOperationBenchmark',*map(str,sorted(Path('Sources/SwiftJXLCore').rglob('*.swift'))),str(root/'main.swift'),'-o',str(root/'probe')]
with (root/'build.log').open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=600)
(root/'command.json').write_text(json.dumps({'command':cmd,'exit':r.returncode},indent=2)+'\n')
if r.returncode:raise SystemExit(r.returncode)
if '--build-only' in sys.argv:raise SystemExit(0)
rows=[]
for name in ['gray','progressive-edge','quant16','multigroup-420','icc-rgb','icc-gray','rgb','rgb-progressive']:
 r=subprocess.run([str(root/'probe'),name],capture_output=True,timeout=180)
 if r.returncode:print(r.stderr.decode());raise SystemExit(r.returncode)
 rows.append(json.loads(r.stdout));print(name,'passed',flush=True)
(root/'result.json').write_text(json.dumps({'binarySHA256':hashlib.sha256((root/'probe').read_bytes()).hexdigest(),'fixtures':rows},indent=2)+'\n')
