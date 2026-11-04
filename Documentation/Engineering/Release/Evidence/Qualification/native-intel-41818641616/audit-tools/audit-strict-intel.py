import datetime,hashlib,json,pathlib,re,xml.etree.ElementTree as ET
repo=pathlib.Path.cwd();r=repo/'.build/m5-native-intel-41818641616';frozen=repo/'.build/m5-macos260/source-00f03ff-provenance.json'
def load(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
s=load(r/'summary.json');h=load(r/'host-and-source.json');c=load(r/'core/report.json');p=load(frozen);v=load(r/'arm-vectors/report.json');d=load(r/'core/normalised-test-identities.json');head=load(r/'head-source-provenance.json');e=load(r/'extracted-files.json');checks={}
checks['all1327ExtractedFilesMatchTransferManifest']=len(e['extractedSHA256'])==1327 and all((r/x['path']).stat().st_size==x['bytes'] and sha(r/x['path'])==x['sha256'] for x in e['extractedSHA256'])
checks['allTwelveSummaryReceiptHashesMatch']=len([x for x in s['reports'] if 'sha256' in x])==12 and all(x.get('passed') is True and ('sha256' not in x or sha(r/x['path'])==x['sha256']) for x in s['reports'])
checks['host1277SourceHashesMatchReporterHead2345c7b']=len(h['sourceSHA256'])==1277 and head['sourceRevision']=='2345c7b9fb1c329463cf4f3ba5bc3194fea51193' and all(head['filesSHA256'].get(k)==value for k,value in h['sourceSHA256'].items())
checks['core203SourceHashesMatchFrozen00f03ff']=len(c['sourceSHA256'])==203 and all(p['filesSHA256'].get(k)==value for k,value in c['sourceSHA256'].items()) and c['packageManifestSHA256']==p['filesSHA256']['Package.swift']
checks['nativeIntelKernelAndCompiler']=h['machine']=='x86_64' and h['nativeIntelConfirmed'] is True and 'RELEASE_X86_64' in h['uname']['stdout'] and 'Target: x86_64-apple-macosx26.0' in h['swift']['stdout']
checks['noExact260OrPhysicalClaim']=s['exactMacOS260Claimed'] is False and h['exactMacOS260Claimed'] is False
xml=ET.parse(r/'core/tests.xml').getroot();cases=xml.findall('.//testcase');suites=xml.findall('.//testsuite')
checks['xml368DeclarationsNoFailureSkip']=len(cases)==368 and all(int(x.attrib.get(k,'0'))==0 for x in suites for k in ['failures','errors','skipped']) and not xml.findall('.//failure') and not xml.findall('.//error') and not xml.findall('.//skipped')
log=(r/'core/tests.log').read_text();params=[int(x) for x in re.findall(r'with (\d+) test cases passed',log)];total=368-len(params)+sum(params)
checks['console2053CasesAndFull368Completion']=total==2053 and len(re.findall(r'✔ Test (?!run with).* passed after',log))==368 and 'Test run with 368 tests in 80 suites passed' in log and '✘' not in log
def normalise(name):
 return name.replace('.', '/', 1) if '/' not in name else name
raw_discovery=[line.strip() for line in (r/'core/discovery.stdout.log').read_text().splitlines() if re.match(r'^SwiftJXL(?:Core)?Tests[./]',line.strip())]
normal_discovery=sorted(map(normalise,raw_discovery));normal_execution=sorted(normalise(x.attrib['classname']+'/'+x.attrib['name']) for x in cases)
checks['exactDiscoveryExecutionSetDirectlyFromSplitStreams']=raw_discovery==load(r/'core/discovered-tests.json') and len(set(normal_discovery))==len(set(normal_execution))==368 and normal_discovery==normal_execution==d['normalisedDiscovered']==d['normalisedExecuted'] and c['fullSuiteCoverage']['identityInventorySHA256']==sha(r/'core/normalised-test-identities.json') and c['fullSuiteCoverage']['exactIdentitySetAgreement'] is True
stream_records={};streams_valid=True
for stem,key in [('discovery','discoveryProcess'),('tests','testProcess')]:
 process=load(r/('core/'+stem+'-process.json'));streams_valid &= process==c[key] and process['exitCode']==0
 for stream in ['stdout','stderr']:
  file=r/'core'/process[stream];streams_valid &= file.stat().st_size==process[stream+'Bytes'] and sha(file)==process[stream+'SHA256']
 combined=r/'core'/process['combinedLog']['path'];streams_valid &= combined.read_bytes()==(r/'core'/process['stdout']).read_bytes()+(r/'core'/process['stderr']).read_bytes() and sha(combined)==process['combinedLog']['sha256']
 stream_records[stem]=process
checks['splitStreamsProcessReceiptsAndCombinedHashesAgree']=streams_valid
checks['bothExecutionStreamsInspectedNoFailureDiagnostics']=all('✘' not in (r/('core/tests.'+stream+'.log')).read_text() for stream in ['stdout','stderr']) and c['executionConsoleCoverage']=={'passed':True,'passingSummaries':[{'stream':'stdout','declarations':368}],'failureDiagnostics':[],'bothStreamsInspected':True}

expected={(bits,channels,associated,transfer,intent) for bits in range(8,17) for channels in range(1,5) for associated in ([0,1] if channels%2==0 else [0]) for transfer in [1,13] for intent in range(4)}
files=sorted((r/'oracle-outputs').glob('public-matrix-*/oracle.json'));profiles=[load(x) for x in files]
checks['all432OracleFilesHashesAndSemanticCartesianProfiles']=len(files)==432 and {str(x.relative_to(r/'oracle-outputs')):sha(x) for x in files}==c['independentProfileCoverage']['sha256'] and all(x['width']==5 and x['height']==3 for x in profiles) and {tuple(x[k] for k in ['bits','channels','premultiplied','transferFunction','renderingIntent']) for x in profiles}==expected
vectors=r/'arm-vectors/reciprocal-vectors.json';replay=r/'arm-vectors/replay.json';known='25b402b28eb3dc355f00c2d3c1cd1e130f49e45c6ced1c01550a1b82e7d5453b'
checks['45826ARMVectorsExactNativeGenerationReplayAndConsumedBinding']=len(load(vectors))==45826 and vectors.read_bytes()==replay.read_bytes() and sha(vectors)==known==v['vectorsSHA256']==c['armReciprocalVectors']['sha256'] and v['architecture']=='arm64' and v['replayedByteForByte'] is True and v['sourceSHA256']==p['filesSHA256']['Scripts/Qualification/VarDCTARM/reciprocal-vectors.c'] and v['sourceRevision']==h['sourceRevision']['stdout'].strip()
cli={};expectedcounts={'cli-completion':22,'cli-foundation':98,'cli-jpeg-extended':91,'cli-low-precision':81,'cli-native-jpeg':141,'cli-nrrd':119,'cli-payload':104,'cli-pnm':299,'cli-vardct':32,'cli-vardct-encode':72};exitagreements=True
for file in sorted(r.glob('cli-*/report.json')):
 data=load(file);items=data['checks'];count=items if isinstance(items,int) else len(items);cli[file.parent.name]={'status':data['status'],'checks':count,'sha256':sha(file)}
 if isinstance(items,list):
  for item in items:
   if 'expected' in item:
    exitkey=next((k for k in ['exit','exit_code','exitCode','returncode'] if k in item),None)
    if exitkey:exitagreements &= item[exitkey]==item['expected']
checks['tenCLIReportsPassedWithExpectedCounts']=set(cli)==set(expectedcounts) and all(x['status']=='passed' and x['checks']==expectedcounts[k] for k,x in cli.items()) and exitagreements
checks['sourceAndReferenceInputsUnchanged']=c['sourcesUnchanged'] is True and c['referenceInputsUnchanged'] is True
report={'status':'passed' if all(checks.values()) else 'failed','createdUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Independent retained-evidence audit, no execution rerun; raw files unchanged. Exact discovery/execution identity comparison independently recomputed directly from split stdout and XML; no metadata derivation required. CLI semantic outputs remain qualified by source-bound original runners; expected statuses/counts independently checked here.','checks':checks,'failedChecks':[k for k,v in checks.items() if not v],'frozenSourceRevision':p['revision'],'executionRevision':h['sourceRevision']['stdout'].strip(),'reporterHeadRevision':head['sourceRevision'],'splitStreamReceipts':stream_records,'host':'native Intel x86_64, macOS 26.6.1 build 25G76','compiler':h['swift']['stdout'].strip(),'declarations':368,'cases':total,'independentProfiles':432,'armHardwareVectors':45826,'cli':cli,'inputsSHA256':{str(x.relative_to(repo)):sha(x) for x in [frozen,r/'summary.json',r/'host-and-source.json',r/'core/report.json',r/'core/tests.xml',r/'core/tests.log',r/'arm-vectors/report.json',r/'head-source-provenance.json',r/'core/normalised-test-identities.json',r/'core/discovery-process.json',r/'core/tests-process.json',r/'core/discovery.stdout.log',r/'core/discovery.stderr.log',r/'core/tests.stdout.log',r/'core/tests.stderr.log',r/'extracted-files.json',r/'artifact-metadata.json']},'auditorSHA256':sha(pathlib.Path(__file__))}
(r/'independent-audit.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':report['status'],'checks':checks,'cases':total}));raise SystemExit(0 if report['status']=='passed' else 1)
