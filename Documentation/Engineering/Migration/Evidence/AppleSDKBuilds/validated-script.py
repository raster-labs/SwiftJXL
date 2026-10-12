#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Cross-build the public library at the OS 26 floor. This is not runtime evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

PROFILES = {
    'ios-device': ('iphoneos', 'arm64-apple-ios26.0'),
    'ios-simulator': ('iphonesimulator', 'arm64-apple-ios26.0-simulator'),
    'tvos-device': ('appletvos', 'arm64-apple-tvos26.0'),
    'tvos-simulator': ('appletvsimulator', 'arm64-apple-tvos26.0-simulator'),
    'visionos-device': ('xros', 'arm64-apple-xros26.0'),
    'visionos-simulator': ('xrsimulator', 'arm64-apple-xros26.0-simulator'),
    'watchos-device': ('watchos', 'arm64-apple-watchos26.0'),
    'watchos-device-32': ('watchos', 'arm64_32-apple-watchos26.0'),
    'watchos-simulator': ('watchsimulator', 'arm64-apple-watchos26.0-simulator'),
    'macos-intel': ('macosx', 'x86_64-apple-macosx26.0'),
}
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--profile', choices=PROFILES, action='append')
a = p.parse_args()
repo = Path(__file__).resolve().parent.parent
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
sources = lambda: {str(f.relative_to(repo)): sha(f) for f in (repo/'Sources').rglob('*.swift')}
record = {'method': __doc__, 'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
          'sourceSHA256': sources(), 'scriptSHA256': sha(Path(__file__)),
          'swift': subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip(),
          'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(), 'runs': []}
def save():
    (out/'report.json').write_text(json.dumps(record, indent=2)+'\n')
save()
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(out/'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(out/'module-cache')
for name in a.profile or PROFILES:
    sdk, triple = PROFILES[name]
    run = {'profile': name, 'sdk': sdk, 'triple': triple, 'runtimeTested': False}
    start = time.monotonic()
    try:
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        run['sdkPath'] = sdk_path
        run['sdkVersion'] = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip()
        scratch = out/name
        command = ['xcrun', 'swift', 'build', '--disable-sandbox', '--cache-path', str(out/'cache'),
            '--config-path', str(out/'config'), '--security-path', str(out/'security'),
            '--scratch-path', str(scratch), '--build-system', 'swiftbuild', '--jobs', '2',
            '--target', 'SwiftJXL', '--triple', triple, '--sdk', sdk_path]
        run['command'] = command
        log = out/(name+'.log')
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=repo, env=env, stdout=stream,
                stderr=subprocess.STDOUT, timeout=1200)
        run['exitCode'] = result.returncode
        run['logSHA256'] = sha(log)
        # Retain emitted target identities to detect accidentally building the host.
        modules = sorted(scratch.glob('out/Products/**/SwiftJXL.swiftmodule/*.swiftmodule'))
        run['modules'] = {str(f.relative_to(out)): sha(f) for f in modules}
        architecture = triple.split('-apple-')[0]
        expected_system = {'xros': 'xros', 'macosx': 'macos'}.get(triple.split('-apple-')[1].split('26.0')[0], triple.split('-apple-')[1].split('26.0')[0])
        expected = architecture+'-apple-'+expected_system+('-simulator' if triple.endswith('-simulator') else '')+'.swiftmodule'
        if result.returncode == 0 and not any(f.name == expected for f in modules):
            run['identityFailure'] = 'Expected emitted module '+expected
    except (OSError, subprocess.SubprocessError) as error:
        run['failure'] = str(error)
    run['elapsedSeconds'] = time.monotonic()-start
    record['runs'].append(run); save()
    print(name, run.get('exitCode', 'unavailable'), run.get('identityFailure', ''), flush=True)
record['sourcesUnchanged'] = record['sourceSHA256'] == sources()
record['passed'] = record['sourcesUnchanged'] and all(r.get('exitCode') == 0 and 'identityFailure' not in r for r in record['runs'])
save()
raise SystemExit(0 if record['passed'] else 1)
