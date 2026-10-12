from pathlib import Path
import os,subprocess,json,time,hashlib,re
root=Path(__file__).resolve().parent;repo=root/'mutants';out=root/'final-combined-validation'
record=json.loads((out/'validation.json').read_text());expected=record['copiedSourceHashes']
def hashes(folder):return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}
for kind,scratch,sanitizer in [('asan','address-asan','address'),('tsan','address-tsan','thread')]:
 assert hashes(repo/'Sources')==expected
 cmd=['xcrun','swift','test','--skip-build','--disable-sandbox','--cache-path',str(root/'cache'),'--config-path',str(root/'config'),'--security-path',str(root/'security'),'--scratch-path',str(root/scratch),'--build-system','swiftbuild','--jobs','2','--filter','ModularEncoderTests','--sanitize',sanitizer]
 env=os.environ.copy();env.update(CLANG_MODULE_CACHE_PATH=str(root/'module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'module-cache'),SWIFTJXL_ORACLE_BIN='/opt/homebrew/bin')
 started=time.monotonic();logpath=out/(kind+'-oracle.log')
 with logpath.open('w') as log:r=subprocess.run(cmd,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 text=logpath.read_text();lines=[l for l in text.splitlines() if '✔ Test ' in l and 'run with' not in l]
 record.setdefault('oracleSupplements',[]).append({'kind':kind,'command':cmd,'environment':{'SWIFTJXL_ORACLE_BIN':'/opt/homebrew/bin'},'exitCode':r.returncode,'elapsedSeconds':time.monotonic()-started,'testDeclarations':len(lines),'testCases':sum(int(m.group(1)) if (m:=re.search(r'with (\d+) test cases',l)) else 1 for l in lines),'logSHA256':hashlib.sha256(logpath.read_bytes()).hexdigest(),'runtimeSourcesUnchanged':hashes(repo/'Sources')==expected})
 (out/'validation.json').write_text(json.dumps(record,indent=2)+'\n');print(kind,'oracle',r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
