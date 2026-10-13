from pathlib import Path
import hashlib,json,os,subprocess,sys,time

w=Path(__file__).resolve().parent
repo=Path(os.environ.get('SWIFTJXL_REPO','/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public'))
core=Path(os.environ.get('SWIFTJXL_CORE_BUILD',str(w.parent/'native-jpeg/compact-ans-colour')))
revisions={'baseline':'423b8ae404ca5029a6a5fa1abe736d57dc8f0a96','current':'aa6d75c7028e0e3eda4e8ce06fdd60907ecd59fd'}
name=sys.argv[1];revision=revisions['current' if name=='candidate' else name];out=w/name;out.mkdir(exist_ok=True)
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',revision,'Sources/SwiftJXL'],cwd=repo,text=True).splitlines()
sources=[];hashes={}
for path in paths:
 if not path.endswith('.swift'): continue
 data=(repo/path).read_bytes() if name=='candidate' else subprocess.check_output(['git','show',revision+':'+path],cwd=repo)
 dest=out/path;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
 sources.append(str(dest));hashes[path]=hashlib.sha256(data).hexdigest()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',SWIFT_DETERMINISTIC_HASHING='1')
core_identity=None
if name!='baseline':
 core_identity=json.loads((core/'SwiftJXLCore-build.json').read_text())
 for path,digest in core_identity['sourceHashes'].items():
  assert hashlib.sha256((repo/path).read_bytes()).hexdigest()==digest,path
flags=['-O','-g','-whole-module-optimization','-swift-version','6','-strict-concurrency=complete','-target','arm64-apple-macos27.0','-module-cache-path',str(out/'cache'),'-package-name','SwiftJXL']
cmd=['xcrun','swiftc',*flags,'-parse-as-library','-module-name','SwiftJXL','-I',str(core),'-emit-module','-emit-module-path',str(out/'SwiftJXL.swiftmodule'),'-emit-library','-static',*sources,'-o',str(out/'libSwiftJXL.a')]
start=time.monotonic()
with (out/'build.log').open('w') as log:
 r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=900)
assert r.returncode==0,(out/'build.log').read_text()[-4000:]
probe=(repo/'Documentation/Engineering/Swift64/Evidence/Benchmark/Original/candidate/Sources/StorageBench/main.swift').read_text().replace('SwiftJ2K','SwiftJXL')
(out/'probe.swift').write_text(probe)
link=['xcrun','swiftc',*flags,'-I',str(out),'-I',str(core),str(out/'probe.swift'),str(out/'libSwiftJXL.a')]
if name!='baseline':link.append(str(core/'libSwiftJXLCore.a'))
link+=['-o',str(out/'probe')]
r=subprocess.run(link,env=env,capture_output=True,text=True,timeout=300)
(out/'link.log').write_text(r.stdout+r.stderr)
assert r.returncode==0,r.stdout+r.stderr
report={'name':name,'revision':revision,'command':cmd,'linkCommand':link,'exit':0,'seconds':time.monotonic()-start,'sourceHashes':hashes,'probeHash':hashlib.sha256(probe.encode()).hexdigest(),'binaryHash':hashlib.sha256((out/'probe').read_bytes()).hexdigest(),'sizeBytes':(out/'probe').stat().st_size,'coreReuse':core_identity,'compiler':subprocess.check_output(['xcrun','swiftc','--version'],env=env,text=True),'os':subprocess.check_output(['sw_vers'],text=True),'power':subprocess.check_output(['pmset','-g','batt'],text=True)}
(out/'build.json').write_text(json.dumps(report,indent=2)+'\n')
print(name,'built',round(report['seconds'],1),'seconds',flush=True)
