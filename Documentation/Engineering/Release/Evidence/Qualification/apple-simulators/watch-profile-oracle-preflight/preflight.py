import hashlib,importlib.util,json,pathlib,subprocess,sys
root=pathlib.Path.cwd();out=root/'.build/m5-watch-jpeg-reference-preflight';spec=importlib.util.spec_from_file_location('watchhelper',root/'Scripts/TestSupport/qualify-watch-profile.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);original=subprocess.run
marker='INTENTIONAL ORACLE-ONLY PREFLIGHT STOP BEFORE BUILD'
def intercepted(command,*args,**kwargs):
 if command[0]=='xcodebuild':
  assert command[1]=='build'
  return subprocess.CompletedProcess(command,73,stdout=marker,stderr='')
 return original(command,*args,**kwargs)
module.subprocess.run=intercepted
sys.argv=['preflight','--suite-report',str(root/'.build/m5-watchos26-24cbd10-final/report.json'),'--output',str(out),'--jobs','2']
result=module.main();report=json.loads((out/'report.json').read_text());reference=report['jpegReference'];commands=report['commands'];assert result==1 and report['status']=='failed' and commands[-1]['label']=='build' and commands[-1]['exitCode']==73 and (out/'build.log').read_text()==marker
assert all(c['exitCode']==0 for c in commands[:-1]);assert reference['width']==31 and reference['height']==17 and reference['bytes']==527 and reference['replayedByteForByte'] and len(reference['nonSystemDependencySHA256'])==1 and report['jpegOracleUnchanged'] and report['sourcesAndDriversUnchanged']
for source in ['Tests/SwiftJXLCoreTests/Fixtures/JBRD/gray.raw']:
 import re
 assert re.match(rb'P5\n([0-9]+) ([0-9]+)\n255\n',pathlib.Path(source).read_bytes()) is None
receipt={'status':'passed','scope':'Executed actual oracle dependency/version/preparation/replay path; intercepted only the subsequent xcodebuild build with explicit exit73 to avoid a runtime test during preflight. Original diagnostic report correctly remains failed.','jpegReference':reference,'rawReportSHA256':hashlib.sha256((out/'report.json').read_bytes()).hexdigest(),'driverSHA256':hashlib.sha256((root/'Scripts/TestSupport/qualify-watch-profile.py').read_bytes()).hexdigest(),'preflightSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'metadataBodyRejectedByPGMHeader':True};(out/'preflight.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
