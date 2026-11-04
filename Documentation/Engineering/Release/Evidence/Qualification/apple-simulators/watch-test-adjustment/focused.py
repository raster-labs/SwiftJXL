import datetime,hashlib,json,pathlib,subprocess,sys,uuid
r=pathlib.Path.cwd();out=r/'.build/watch-test-adjustment/focused';out.mkdir();report={'status':'running','commands':[],'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat()};device=None
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(label,cmd,required=True):
 x=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);p=out/(label+'.log');p.write_text(x.stdout);report['commands'].append({'label':label,'command':cmd,'exitCode':x.returncode,'logSHA256':sha(p)});save()
 if required and x.returncode:raise RuntimeError(label+' exit '+str(x.returncode))
 return x.stdout
try:
 report['testSourcesSHA256']={str(p):sha(p) for p in sorted(pathlib.Path('Tests').rglob('*.swift'))};save()
 device=run('create',['xcrun','simctl','create','SwiftJXL-M5-watch-focused-'+str(uuid.uuid4())[:8],'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm','com.apple.CoreSimulator.SimRuntime.watchOS-26-0']).strip();report['simulatorUUID']=device
 run('boot',['xcrun','simctl','boot',device]);run('bootstatus',['xcrun','simctl','bootstatus',device,'-b'])
 run('tests',['xcodebuild','-scheme','SwiftJXL-Package','-configuration','Release','ENABLE_TESTABILITY=YES','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','-destination','platform=watchOS Simulator,id='+device,'-derivedDataPath',str(r/'.build/m5-watchos26-suite-prebuild/DerivedData'),'-jobs','2','-parallel-testing-enabled','NO','-only-testing:SwiftJXLCoreTests/ModularDecodeParallelTests','-only-testing:SwiftJXLCoreTests/ModularStorageTests','test','-resultBundlePath',str(out/'tests.xcresult')])
 raw=run('summary',['xcrun','xcresulttool','get','test-results','summary','--path',str(out/'tests.xcresult'),'--format','json']);summary=json.loads(raw);report['summary']=summary
 if summary['failedTests'] or summary['skippedTests'] or summary['passedTests']!=14:raise RuntimeError('Unexpected focused summary: '+str({k:summary[k] for k in ['passedTests','failedTests','skippedTests']}))
 report['status']='passed'
except Exception as error:report.update(status='failed',failure=str(error));print(str(error),flush=True)
finally:
 if device:run('shutdown',['xcrun','simctl','shutdown',device],False);run('delete',['xcrun','simctl','delete',device],False)
 report['testSourcesUnchanged']=report['testSourcesSHA256']=={str(p):sha(p) for p in sorted(pathlib.Path('Tests').rglob('*.swift'))};report['finishedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();save();print(report['status'],flush=True)
sys.exit(0 if report['status']=='passed' else 1)
