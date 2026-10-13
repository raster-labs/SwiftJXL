from pathlib import Path
import json,sys,subprocess,os,time,hashlib,xml.etree.ElementTree as ET
w=Path(__file__).resolve().parent;repo=Path('/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public');kind=sys.argv[1];out=w/'validation';out.mkdir(exist_ok=True)
base=json.loads((repo/'Documentation/Engineering/Migration/Evidence/ModularColour/Performance/UnfoldedTokens/validation.json').read_text())
label='debug' if kind=='focused' else kind;cmd=next(r['command'].copy() for r in base['runs'] if r['configuration']==label)
cmd[cmd.index('--xunit-output')+1]=str(out/(kind+'.xml'))
selection='SampleAccessTests|StorageTests|DescriptorTests|cancellationInProviderFinalisationPreventsPublication|ScalarMemoryTests'
if '--filter' in cmd:cmd[cmd.index('--filter')+1]=selection
elif kind=='focused':cmd+=['--filter',selection]
env={**os.environ,'SWIFTJXL_ORACLE_BIN':'/opt/homebrew/bin'}
sources={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ['Sources','Tests'] for p in (repo/folder).rglob('*.swift')};start=time.time()
with (out/(kind+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
row={'configuration':kind,'command':cmd,'environment':{'SWIFTJXL_ORACLE_BIN':env['SWIFTJXL_ORACLE_BIN']},'exit':r.returncode,'seconds':time.time()-start,'sourceHashes':sources}
xml=out/(kind+'.xml')
if xml.exists():
 root=ET.parse(xml).getroot();row['xml']={'cases':len(list(root.iter('testcase'))),'failures':len(list(root.iter('failure'))),'errors':len(list(root.iter('error'))),'skips':len(list(root.iter('skipped')))}
assert all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==h for p,h in sources.items()),'Sources changed while testing'
(out/(kind+'.json')).write_text(json.dumps(row,indent=2)+'\n');print(kind,'exit',r.returncode,'seconds',round(row['seconds'],1),row.get('xml',{}),flush=True)
print((out/(kind+'.log')).read_text()[-1500:]);sys.exit(r.returncode)
