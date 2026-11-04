set -eu
cd /Users/admin/m5
mkdir source-00f03ff
tar -xf source-00f03ff.tar -C source-00f03ff
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
/Library/Developer/CommandLineTools/usr/bin/python3 - <<'VERIFY'
import hashlib,json,subprocess,time
from pathlib import Path
base=Path('/Users/admin/m5');proof=json.loads((base/'source-00f03ff-provenance.json').read_text());repo=base/'source-00f03ff'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(base/'source-00f03ff.tar')==proof['archiveSHA256']
assert all(sha(repo/name)==digest for name,digest in proof['filesSHA256'].items())
commands=[]
for argv in [['sw_vers'],['uname','-a'],['xcrun','swift','--version'],['sysctl','-n','sysctl.proc_translated'],['sysctl','-n','hw.memsize']]:
 r=subprocess.run(argv,text=True,capture_output=True);commands.append({'command':argv,'exitCode':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
record={'sourceRevision':proof['revision'],'sourceArchiveSHA256':proof['archiveSHA256'],'allArchiveFilesVerified':len(proof['filesSHA256']),'commands':commands,'startedUnix':time.time(),'virtualMachine':True,'physicalDeviceEvidence':False,'parentFreezeGroups':proof['parentFreezeGroups']}
(base/'execution-00f03ff-provenance.json').write_text(json.dumps(record,indent=2)+'\n')
VERIFY
cd /Users/admin/m5/source-00f03ff
export SWIFTJXL_ORACLE_BIN=/Users/admin/m5/oracles/tools
export SWIFTJXL_PROFILE_ORACLE=/Users/admin/m5/oracles/swiftjxl-modular-profile-oracle
export SWIFTJXL_ORACLE_OUTPUT=/Users/admin/m5/runtime-00f03ff-oracle-outputs
export SWIFTJXL_ARM_RECIPROCAL_VECTORS=/Users/admin/m5/reciprocal-vectors.json
/Library/Developer/CommandLineTools/usr/bin/python3 Scripts/TestSupport/qualify-native-runtime.py --repo /Users/admin/m5/source-00f03ff --mode native-macos --minimum-runtime --build-system native --testing-framework-path /Library/Developer/CommandLineTools/Library/Developer/Frameworks --output /Users/admin/m5/runtime-00f03ff
