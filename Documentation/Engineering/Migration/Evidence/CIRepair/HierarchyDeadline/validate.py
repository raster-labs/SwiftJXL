from pathlib import Path
import json,sys,subprocess,os,time,hashlib,xml.etree.ElementTree as ET
w=Path(__file__).resolve().parent
repo=Path('/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public')
kind,label,selection=sys.argv[1:4]
base=json.loads((w.parent/'storage-read/validation'/f'{kind}.json').read_text())
cmd=base['command'].copy();cmd[cmd.index('--xunit-output')+1]=str(w/(label+'.xml'));cmd[cmd.index('--filter')+1]=selection
sources={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ['Sources','Tests'] for p in (repo/folder).rglob('*.swift')}
env={**os.environ,'SWIFTJXL_ORACLE_BIN':'/opt/homebrew/bin'}
start=time.monotonic()
with (w/(label+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
row={'configuration':kind,'label':label,'command':cmd,'environment':{'SWIFTJXL_ORACLE_BIN':env['SWIFTJXL_ORACLE_BIN']},'exit':r.returncode,'seconds':time.monotonic()-start,'sourceHashes':sources}
xml=w/(label+'.xml')
if xml.exists():
 root=ET.parse(xml).getroot();row['xml']={'cases':len(list(root.iter('testcase'))),'failures':len(list(root.iter('failure'))),'errors':len(list(root.iter('error'))),'skips':len(list(root.iter('skipped')))}
assert all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==h for p,h in sources.items()),'Sources changed during tests'
(w/(label+'.json')).write_text(json.dumps(row,indent=2)+'\n')
print(json.dumps({k:v for k,v in row.items() if k!='sourceHashes'},indent=2));print((w/(label+'.log')).read_text()[-2400:]);sys.exit(r.returncode)
