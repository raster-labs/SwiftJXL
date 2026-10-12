import pathlib,subprocess,hashlib,json,os,shutil,time,difflib
root=pathlib.Path(__file__).resolve().parent
parent=root.parent/'SwiftJXL-vardct-public'; repo=root/'mutants';out=root/'public-header-validation';out.mkdir(exist_ok=True)
names=['VarDCTPublicTests','PixelFrameHeaderTests','ModularStorageTests','ModularICCTests','VarDCTPixelStorageTests']
def hashes(folder): return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}
# Exact source inventory, including absence of stray source files.
shutil.rmtree(repo/'Sources');shutil.copytree(parent/'Sources',repo/'Sources')
for p in (repo/'Tests/SwiftJXLCoreTests').glob('*.swift'):p.unlink()
for name in names:shutil.copy2(parent/'Tests/SwiftJXLCoreTests'/(name+'.swift'),repo/'Tests/SwiftJXLCoreTests'/(name+'.swift'))
# Copy exact current resource fixtures used by the retained diagnostic target.
for name in ['JPEG','JBRD','Brotli','JPEGEvents','JPEGBridge','Modular','VarDCT']:
 dst=repo/'Tests/SwiftJXLCoreTests/Fixtures'/name
 if dst.exists():shutil.rmtree(dst)
 shutil.copytree(parent/'Tests/SwiftJXLCoreTests/Fixtures'/name,dst)
# Keep the test target/resource configuration; exclude unrelated public test target.
manifest=(parent/'Package.swift').read_text()
for p in (repo/'Tests/SwiftJXLTests').glob('*.swift'):p.unlink()
shutil.copy2(parent/'Tests/SwiftJXLTests/CancellationPublicationTests.swift',repo/'Tests/SwiftJXLTests/CancellationPublicationTests.swift')
(repo/'Package.swift').write_text(manifest)
sourcehashes=hashes(parent/'Sources');assert sourcehashes==hashes(repo/'Sources')
record={'parentHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=parent,text=True).strip(),'parentWorkingSourceHashes':sourcehashes,'copiedSourceHashes':hashes(repo/'Sources'),'testSourceHashes':{name:hashlib.sha256((repo/'Tests/SwiftJXLCoreTests'/(name+'.swift')).read_bytes()).hexdigest() for name in names},'selectedTests':names+['cancellationInProviderFinalisationPreventsPublication'],'publicCancellationTestSHA256':hashlib.sha256((repo/'Tests/SwiftJXLTests/CancellationPublicationTests.swift').read_bytes()).hexdigest(),'manifestSHA256':hashlib.sha256(manifest.encode()).hexdigest(),'fixtureSHA256':hashes(repo/'Tests/SwiftJXLCoreTests/Fixtures'),'runs':[]}
(out/'manifest.patch').write_text(''.join(difflib.unified_diff((parent/'Package.swift').read_text().splitlines(keepends=True),manifest.splitlines(keepends=True),fromfile='parent/Package.swift',tofile='diagnostic/Package.swift')))
(out/'Package.swift').write_text(manifest)
(out/'validation.json').write_text(json.dumps(record,indent=2)+'\n')
for kind,scratch in [('asan','address-asan'),('tsan','address-tsan')]:
 cmd=['xcrun','swift','test','--disable-sandbox','--cache-path',str(root/'cache'),'--config-path',str(root/'config'),'--security-path',str(root/'security'),'--scratch-path',str(root/scratch),'--build-system','swiftbuild','--jobs','2','--filter','|'.join(names+['cancellationInProviderFinalisationPreventsPublication'])]
 if kind!='debug':cmd+=['--sanitize','address' if kind=='asan' else 'thread']
 env=os.environ.copy();env['CLANG_MODULE_CACHE_PATH']=str(root/'module-cache');env['SWIFTPM_MODULECACHE_OVERRIDE']=str(root/'module-cache')
 started=time.monotonic()
 with (out/(kind+'.log')).open('w') as log:result=subprocess.run(cmd,cwd=repo,stdout=log,stderr=subprocess.STDOUT,env=env,timeout=1800)
 record['runs'].append({'kind':kind,'command':cmd,'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-started,'runtimeSourcesUnchanged':hashes(repo/'Sources')==sourcehashes,'parentSourcesStillMatch':hashes(parent/'Sources')==sourcehashes,'logSHA256':hashlib.sha256((out/(kind+'.log')).read_bytes()).hexdigest()})
 (out/'validation.json').write_text(json.dumps(record,indent=2)+'\n')
 print(kind,result.returncode,flush=True)
 if result.returncode:raise SystemExit(result.returncode)
