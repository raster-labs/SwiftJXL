import collections,datetime,hashlib,json,pathlib,re,subprocess
root=pathlib.Path.cwd();out=root/'.build/m5-final-cli-tsan-matrix';sha=lambda b:hashlib.sha256(b).hexdigest();report=json.loads((out/'report.json').read_text())
assert report['status']=='passed' and report['sourcesUnchanged'] and report['binaryUnchanged']
expected={'foundation':98,'payload':104,'nrrd':119,'pnm':299,'low-precision':81,'vardct':32,'vardct-encode':72,'native-jpeg':141,'completion':22,'jpeg-extended':91}
assert len(report['runs'])==10 and {x['group'] for x in report['runs']}==set(expected)
snapshot=json.loads((root/'.build/m5-macos260/source-00f03ff-provenance.json').read_text())['filesSHA256']
for path,digest in report['runtimeFiles'].items():assert snapshot[path]==digest==sha((root/path).read_bytes()),path
assert sha(json.dumps(report['runtimeFiles'],sort_keys=True,separators=(',',':')).encode())==report['sourceGroupDigests']['runtime']=='30a591977a593e9487429c5289b62a6ed30216d86d029124f31401c67164b753'
assert sha((root/'Scripts/TestSupport/qualify-cli-tsan.py').read_bytes())==report['driverSHA256']
assert report['sanitizerOptions']['TSAN_OPTIONS']=='halt_on_error=1:exitcode=66'
for path,digest in report['tools'].items():assert sha(pathlib.Path(path).read_bytes())==digest,path
binary=pathlib.Path(report['runs'][0]['command'][report['runs'][0]['command'].index('--binary')+1]);assert sha(binary.read_bytes())==report['binarySHA256']
linkage=subprocess.check_output(['otool','-L',str(binary)],text=True);assert linkage==report['linkedLibraries'];assert 'libclang_rt.tsan_osx_dynamic.dylib' in linkage
symbols=subprocess.check_output(['nm',str(binary)],text=True);assert re.search(r'\b___tsan_init\b',symbols)
diagnostics=re.compile(r'(?:WARNING|SUMMARY|FATAL): ThreadSanitizer|ThreadSanitizer: reported|ERROR: (?:AddressSanitizer|LeakSanitizer)')
records=[];explicit_status_checks=0
for row in report['runs']:
 name=row['group'];p=out/name/'report.json';raw=p.read_bytes();detail=json.loads(raw);script=pathlib.Path(row['command'][1]);log=(out/(name+'.log')).read_bytes()
 assert row['status']==row['result']==detail['status']=='passed' and row['exitCode']==0 and not row['sanitizerDiagnostic']
 assert sha(raw)==row['reportSHA256'];assert sha(script.read_bytes())==row['scriptSHA256'];assert row['checks']==expected[name]
 checks=detail['checks'];assert (checks if isinstance(checks,int) else len(checks))==expected[name]
 bound=detail.get('binary_sha256',detail.get('binarySHA256'))
 if bound is None:bound=detail['tools'][str(binary)]
 assert bound==report['binarySHA256']
 assert not diagnostics.search(raw.decode()) and not diagnostics.search(log.decode()),name
 for entry in detail.get('commands',[])+(checks if isinstance(checks,list) else []):
  if not isinstance(entry,dict):continue
  want=entry.get('expected',entry.get('expected_exit_code'));got=entry.get('exit',entry.get('exit_code'))
  if want is not None:
   assert got in want if isinstance(want,list) else got==want,(name,entry)
   explicit_status_checks+=1
 records.append({'group':name,'checks':expected[name],'status':'passed','reportSHA256':sha(raw),'scriptSHA256':sha(script.read_bytes()),'rawLogSHA256':sha(log),'noSanitizerDiagnostics':True})
manifest_path=root/'.build/milestone5-cli-oracles/scalar-oracle-manifest.json';manifest=json.loads(manifest_path.read_text());assert sha(manifest_path.read_bytes())==report['scalarOracleManifestSHA256'];assert manifest==report['scalarOracle'];assert manifest['status']=='passed' and manifest['scalarOnly'] and manifest['highPrecision']
source=root/'.build/m5-macos260/oracles/libjxl';assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==manifest['sourceRevision']=='a7a9c787341cf703dede03c2009fa460cae5e5df'
cache=root/'.build/milestone5-scalar-oracle-build/CMakeCache.txt';assert sha(cache.read_bytes())==manifest['cmakeCacheSHA256'];assert 'CMAKE_CXX_FLAGS:STRING=-DHWY_COMPILE_ONLY_SCALAR -DJXL_HIGH_PRECISION=1' in cache.read_text()
flags={}
for name in ['jxl_dec-obj','jxl_enc-obj']:
 p=root/'.build/milestone5-scalar-oracle-build/lib/CMakeFiles'/f'{name}.dir/flags.make';t=p.read_text();assert '-DHWY_COMPILE_ONLY_SCALAR' in t and '-DJXL_HIGH_PRECISION=1' in t;flags[name]=sha(p.read_bytes())
scalar_counts={}
for path,digest in manifest['librarySHA256'].items():
 p=pathlib.Path(path);assert sha(p.read_bytes())==digest;s=subprocess.check_output(['nm','-C',path]);text=s.decode();assert 'N_SCALAR' in text and not re.search(r'N_(?:NEON|SVE|AVX|SSE|EMU128)',text);scalar_counts[p.name]=text.count('N_SCALAR')
 if p.name=='libjxl.0.12.0.dylib':assert sha(s)==manifest['symbolsSHA256']
for name,key in [('milestone5-scalar-oracle-configure.log','configureLogSHA256'),('milestone5-scalar-oracle-build.log','buildLogSHA256')]:assert sha((root/'.build'/name).read_bytes())==manifest[key]
pixel_source=root/'Documentation/Engineering/Migration/Evidence/VarDCT/PublicEncoder/pixel-oracle-float-precision.c';assert sha(pixel_source.read_bytes())==manifest['sourceSHA256']
scalar_binary=root/'.build/milestone5-cli-oracles/pixel-oracle-scalar';assert sha(scalar_binary.read_bytes())==manifest['binarySHA256'];assert subprocess.check_output(['otool','-L',str(scalar_binary)],text=True)==manifest['linkage']
encoded=json.loads((out/'vardct-encode/report.json').read_text());checks=encoded['checks'];assert {(x['bits'],x['channels'],x['controls']) for x in checks}=={(b,c,t) for b in range(8,17) for c in range(1,5) for t in ['on','off']}
for x in checks:
 p=out/'vardct-encode'/f"{x['bits']}-{x['channels']}-{x['controls']}.jxl";assert sha(p.read_bytes())==x['encodedSHA256'];assert x['scalarPeak']<=2 and x['scalarRMS']<=0.5;assert x['exactAlpha']==(x['channels']%2==0)
completion=json.loads((out/'completion/report.json').read_text())
audit={'status':'passed','auditedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Independent retained-evidence audit of ten source-bound CLI TSan runners; no new execution claimed. Original runner sample assertions remain the semantic oracle evidence.','sourceRevision':snapshot and '00f03ff288a7c8e0e2b82d2e71ec22622ede71ae','runtimeDigest':report['sourceGroupDigests']['runtime'],'runtimeFileCount':len(report['runtimeFiles']),'runtimeBytesMatchFrozenAndCurrent':True,'host':report['host'],'binarySHA256':report['binarySHA256'],'tsanRuntimeLinked':True,'tsanInstrumentationSymbolCount':len([x for x in symbols.splitlines() if '___tsan_' in x]),'sanitizerOptions':report['sanitizerOptions'],'allToolHashesUnchanged':True,'groups':records,'totalChecks':sum(expected.values()),'explicitExpectedExitComparisons':explicit_status_checks,'scalarOracle':{'sourceRevision':manifest['sourceRevision'],'manifestSHA256':sha(manifest_path.read_bytes()),'compiledScalarAndHighPrecisionFlags':True,'flagsSHA256':flags,'onlyScalarDispatchSymbols':scalar_counts,'mainLibrarySymbolHashMatches':True,'all72EncodedPayloadHashesMatch':True,'maximumObservedPeakLSB':max(x['scalarPeak'] for x in checks),'maximumObservedRMSLSB':max(x['scalarRMS'] for x in checks),'peakLimitLSB':2,'rmsLimitLSB':0.5},'retainedReferenceDisagreements':completion.get('referenceDisagreements',[]),'matrixReportSHA256':sha((out/'report.json').read_bytes()),'auditorSHA256':sha(pathlib.Path(__file__).read_bytes()),'limitations':['This is native arm64 macOS27.0.1 TSan CLI evidence, not exact26.0 or physical-device evidence.','Some CLI reports contain semantic case records rather than one record per process; totalChecks is the existing runner check count, not a uniform subprocess count.']}
p=out/'independent-audit.json';p.write_text(json.dumps(audit,indent=2)+'\n');print('PASSED:',len(records),'groups',audit['totalChecks'],'checks',explicit_status_checks,'explicit expected-exit comparisons');print('Audit:',p)
