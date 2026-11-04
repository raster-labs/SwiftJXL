import datetime,hashlib,json,pathlib,shutil,subprocess
repo=pathlib.Path.cwd();root=repo/'Documentation/Engineering/Release/Evidence/Qualification/apple-simulators'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
def copy_tree(source,target,exclude=()):
 target.mkdir(parents=True,exist_ok=True);files={}
 for p in sorted(source.rglob('*')):
  if not p.is_file() or any(x in exclude or x.endswith('.xcresult') for x in p.relative_to(source).parts):continue
  rel=p.relative_to(source);out=target/rel;out.parent.mkdir(parents=True,exist_ok=True)
  if out.exists():assert out.read_bytes()==p.read_bytes(),str(out)+' differs from original'
  else:shutil.copyfile(p,out)
  files[str(rel)]=sha(out)
 (target/'archive-manifest.json').write_text(json.dumps({'status':'archived','sourceDirectory':str(source),'selectedFilesSHA256':files,'selectedFileCount':len(files),'selectedBytes':sum((target/p).stat().st_size for p in files),'scope':'Exact selected original evidence bytes; raw xcresult bundles, caches and binaries retained at original paths with hashes bound in receipts.'},indent=2)+'\n')
copy_tree(repo/'.build/m5-watchos26-profile-e8f976a-final',root/'watch-profile',('DerivedData','module-cache','watch-profile-probe'))
copy_tree(repo/'.build/m5-watch-jpeg-reference-preflight',root/'watch-profile-oracle-preflight',('DerivedData','module-cache','watch-profile-probe'))
shutil.copyfile(repo/'.build/m5-watch-jpeg-reference-diagnosis/preflight.py',root/'watch-profile-oracle-preflight/preflight.py')
shutil.copyfile(repo/'.build/watch-test-adjustment/native-projection-independent-audit.json',root/'watch-test-adjustment/native-projection-independent-audit.json')
for name in ['qualify-watch-profile.py','apple-runtime-probe.swift']:
 target=root/'watch-profile/driver-snapshots';target.mkdir(exist_ok=True);shutil.copyfile(repo/'Scripts/TestSupport'/name,target/name)
vectorroot=root/'hardware-reciprocal';vectorroot.mkdir(exist_ok=True)
for name in ['reciprocal-vectors.json','replay-report.json']:shutil.copyfile(repo/'.build/m5-simulator-vectors'/name,vectorroot/name)
shutil.copyfile(pathlib.Path(__file__),root/'assemble-simulator-evidence.py')
current={str(p.relative_to(repo)):sha(p) for p in [repo/'Package.swift',*[p for group in ['Sources','Tests'] for p in (repo/group).rglob('*') if p.is_file() and p.name!='.DS_Store']]}
projection=load(root/'watch-test-adjustment/non-watch-proof.json');allowed=projection['files'];checks={};projected={}
for name,record in allowed.items():
 before=(root/'watch-test-adjustment'/(pathlib.Path(name).name+'.before')).read_bytes();after=(repo/name).read_bytes();assert sha(repo/name)==record['afterSHA256'];stack=[];active=True;lines=[];branches=0
 for line in after.decode().splitlines(keepends=True):
  stripped=line.strip()
  if stripped=='#if os(watchOS)':stack.append(active);active=False;branches+=1;continue
  if stripped=='#else' and stack:active=stack[-1];continue
  if stripped=='#endif' and stack:active=stack.pop();continue
  if active:lines.append(line)
 derived=''.join(lines).encode();assert not stack and derived==before;assert hashlib.sha256(before).hexdigest()==record['beforeSHA256']==record['nonWatchDerivedSHA256'];projected[name]={'beforeSHA256':record['beforeSHA256'],'afterSHA256':record['afterSHA256'],'inactiveWatchBlocks':branches,'nonWatchBytesUnchanged':True}
checks['nonWatchSourcesExactlyUnchangedExceptReviewedInactiveBranches']=sum(x['inactiveWatchBlocks'] for x in projected.values())==6 and len(projected)==2
checks['independentProjectionAuditPassed']=load(root/'watch-test-adjustment/native-projection-independent-audit.json')['status']=='passed'
expected={'ios26':['debug','asan','tsan'],'tvos26':['release'],'visionos26':['release'],'watchos26':['release']};platforms={};all_sources=True;all_runtime=True;all_counts=True;all_sentinels=True;all_audits=True;all_drivers=True;all_cleanup=True;binary_proofs=True
for name,configs in expected.items():
 folder=root/name;r=load(folder/'report.json');audit=load(folder/'audit.json');assert r['status']=='passed' and r['sourcesUnchanged'] is True and r['driversUnchanged'] is True
 source=r['sourceHashesAfter'];differing={key for key in set(source)|set(current) if source.get(key)!=current.get(key)}
 if name=='watchos26':all_sources &= not differing
 else:all_sources &= differing==set(allowed) and all(source[key]==allowed[key]['beforeSHA256'] and current[key]==allowed[key]['afterSHA256'] for key in differing)
 all_runtime &= all(current[key]==value for key,value in source.items() if not key.startswith('Tests/'))
 all_drivers &= all(sha(repo/key)==value for key,value in r['driverHashes'].items())
 all_audits &= audit['status']=='passed' and audit['receiptSHA256']==sha(folder/'report.json') and set(audit['selectedConfigurations'])==set(configs) and not audit['excludedConfigurations']
 all_cleanup &= r['cleanup']['deviceAbsent'] is True and all(r['cleanup'][x]['exitCode']==0 for x in ['shutdown','delete'])
 assert [x['configuration'] for x in r['runs']]==configs
 records=[]
 for run in r['runs']:
  tree=run['tree'];acceptance=run['acceptance'];device=acceptance['device'];all_counts &= acceptance['passed'] is True and tree['declarationsCount']==362 and tree['totalCases']==1960 and tree['passedCases']==1960 and tree['failedCases']==0 and tree['skippedCases']==0 and device['osVersion']=='26.0' and device['architecture']=='arm64'
  sentinels=run['reciprocalSentinels'];all_sentinels &= {x['name'] for x in sentinels}=={'missing','short','corrupt'} and len(sentinels)==3 and all(x['verified'] is True for x in sentinels)
  if run['configuration'] in ['asan','tsan']:binary_proofs &= run['instrumentationProof']['acceptance']['passed'] is True
  records.append({'configuration':run['configuration'],'declarations':362,'cases':1960,'failedCases':0,'skippedCases':0,'device':device,'reciprocalNegativeSentinels':3})
 platforms[name]={'report':str((folder/'report.json').relative_to(root)),'reportSHA256':sha(folder/'report.json'),'audit':str((folder/'audit.json').relative_to(root)),'auditSHA256':sha(folder/'audit.json'),'sourceRevision':r['sourceRevision'],'sourceFiles':len(source),'currentSourceBinding':'exact' if not differing else 'exact after six reviewed inactive Watch-only branches','configurations':records}
checks.update(allSourceAndFixtureInventoriesBound=all_sources,productionSourcesAndManifestUnchanged=all_runtime,allSimulatorDriversUnchanged=all_drivers,allSixConfigurationsPassFullInventory=all_counts,allEighteenVectorNegativeSentinelsVerified=all_sentinels,allIndependentReceiptAuditsPass=all_audits,allFullSuiteDisposableDevicesRemoved=all_cleanup,asanAndTsanActualBinaryHooksRuntimeLinkageAndHashesVerified=binary_proofs)
probe=load(root/'watch-profile/report.json');preflight=load(root/'watch-profile-oracle-preflight/preflight.json');required={'low-memory rejection','cancellation','cancellation after destination writes','failed destination invalidation','Watch profile and exact round trip','extended JPEG precision metadata and ownership'}
checks['watchSupplementPassedAndFullyBound']=probe['status']=='passed' and probe['sourcesAndDriversUnchanged'] is True and probe['sourceHashes']==current and probe['suiteReportSHA256']==sha(root/'watchos26/report.json') and all(sha(repo/key)==value for key,value in probe['driverHashes'].items()) and required<=set(probe['result']['checks']) and probe['result']['memoryCeilingBytes']==32*1024*1024 and probe['result']['jpegExtendedCases']>0 and all(x['exitCode']==0 for x in probe['cleanup'])
checks['independentJpegReferencePreparedReplayedAndPinned']=preflight['status']=='passed' and probe['jpegOracleUnchanged'] is True and probe['jpegReference']['replayedByteForByte'] is True and probe['jpegReference']['bytes']==527 and len(probe['jpegReference']['nonSystemDependencySHA256'])>0 and probe['jpegReference']==preflight['jpegReference']
checks['historicalWatchFailuresRemainExplicit']=load(root/'watchos26-initial-failure/report.json')['status']=='failed' and load(root/'watch-profile-initial-failure/report.json')['status']=='failed'
checks['hardwareVectorBytesBound']=sha(vectorroot/'reciprocal-vectors.json')=='25b402b28eb3dc355f00c2d3c1cd1e130f49e45c6ced1c01550a1b82e7d5453b' and len(load(vectorroot/'reciprocal-vectors.json'))==45826
files={str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file() and p.name!='qualification-index.json'}
report={'schemaVersion':1,'status':'passed' if all(checks.values()) else 'failed','createdUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':checks,'failedChecks':[key for key,value in checks.items() if not value],'scope':'Apple OS26.0 arm64 simulators, six full configurations plus Watch limits/ownership/cancellation probe. Runtime source unchanged from00f03ff; Watch test correction24cbd10; independent JPEG reference helper correctione8f976a. Physical-device testing remains deferred.','physicalDevicesQualified':False,'currentSourcesSHA256':current,'watchOnlyTestProjection':projected,'platforms':platforms,'watchProfile':{'report':'watch-profile/report.json','reportSHA256':sha(root/'watch-profile/report.json'),'checks':probe['result']['checks'],'jpegExtendedCases':probe['result']['jpegExtendedCases'],'varDCTPeakLSB':probe['result']['varDCTPeakLSB'],'varDCTRMSLSB':probe['result']['varDCTRMSLSB'],'configuredMemoryCeilingBytes':probe['result']['memoryCeilingBytes'],'measuredRSSBytes':None,'probeSourceSHA256':sha(repo/'Scripts/TestSupport/apple-runtime-probe.swift'),'driverSHA256':probe['driverHashes']},'preservedFailures':['watchos26-initial-failure/report.json','watch-profile-initial-failure/report.json'],'oraclePreflight':'watch-profile-oracle-preflight/preflight.json','archivedFilesSHA256':files,'archiveFileCount':len(files),'archiveBytes':sum((root/p).stat().st_size for p in files),'assemblerSHA256':sha(pathlib.Path(__file__))}
(root/'qualification-index.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':report['status'],'failedChecks':report['failedChecks'],'files':len(files),'bytes':report['archiveBytes']}));raise SystemExit(0 if report['status']=='passed' else 1)
