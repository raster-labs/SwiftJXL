# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,json,sys
w=Path(__file__).resolve().parent;o=w/sys.argv[1]
cmd=['xcrun','swiftc','-O','-g','-swift-version','6','-strict-concurrency=complete','-package-name','SwiftJXL','-module-cache-path',str(o/'cache'),'-I',str(o),str(w/'probe.swift'),str(o/'libSwiftJXLCore.a'),'-o',str(o/'successor')]
r=subprocess.run(cmd,capture_output=True,text=True);(o/'successor-probe-build.json').write_text(json.dumps({'command':cmd,'exit':r.returncode,'output':r.stdout+r.stderr},indent=2));print(r.returncode,(r.stdout+r.stderr)[-1000:]);sys.exit(r.returncode)
