#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Execute native macOS or explicitly selected physical Apple-device gates.

A missing host/device/runtime is UNEXECUTED and exits 2. Cross-compilation and
Rosetta never satisfy native Intel. Run after implementation is frozen. For a
physical device, supply its ID and an Xcode project/workspace that hosts the
package tests; the runner never signs, installs or chooses a device implicitly.
"""
import argparse
import hashlib
import json
import platform
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--output', type=Path, required=True)
p.add_argument('--mode', choices=['native-intel', 'native-macos', 'physical'], required=True)
p.add_argument('--minimum-runtime', action='store_true', help='Require exactly the 26.0 major/minor runtime')
p.add_argument('--device-id')
p.add_argument('--platform', choices=['iOS', 'tvOS', 'watchOS', 'visionOS'])
p.add_argument('--project', type=Path)
p.add_argument('--workspace', type=Path)
p.add_argument('--scheme', default='SwiftJXL')
a = p.parse_args()
a.repo = a.repo.resolve(); a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
def sources():
    return {str(f.relative_to(a.repo)): sha(f) for folder in ['Sources', 'Tests']
            for f in sorted((a.repo/folder).rglob('*.swift'))}
report = {'status': 'unexecuted', 'mode': a.mode, 'host': platform.platform(),
          'machine': platform.machine(), 'sourceSHA256': sources(), 'commands': [],
          'minimumRuntimeRequired': a.minimum_runtime}
def save(): (a.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
def command(argv, timeout=60):
    started = time.monotonic()
    r = subprocess.run(argv, cwd=a.repo, text=True, capture_output=True, timeout=timeout)
    report['commands'].append({'command': argv, 'exitCode': r.returncode,
                              'seconds': time.monotonic()-started, 'stdout': r.stdout, 'stderr': r.stderr})
    save(); return r

def unavailable(reason):
    report['reason'] = reason; save(); print(reason); raise SystemExit(2)

save()
if platform.system() != 'Darwin': unavailable('An Apple host is required by this runner.')
if a.mode != 'physical':
    translated = command(['sysctl', '-n', 'sysctl.proc_translated'])
    if translated.stdout.strip() == '1': unavailable('Rosetta is not native runtime evidence.')
    if a.mode == 'native-intel' and platform.machine() != 'x86_64':
        unavailable('Native Intel Mac unavailable: host architecture is ' + platform.machine())
    version = command(['sw_vers', '-productVersion']).stdout.strip()
    report['runtimeVersion'] = version
    if a.minimum_runtime and tuple(version.split('.')[:2]) != ('26', '0'):
        unavailable('macOS 26.0 runtime unavailable: host runs ' + version)
    argv = ['xcrun', 'swift', 'test', '-c', 'release', '--disable-sandbox', '--build-system', 'swiftbuild',
            '--no-parallel', '--enable-swift-testing', '--disable-xctest', '--jobs', '2',
            '--xunit-output', str(a.output/'tests.xml')]
else:
    if not a.device_id or not a.platform or bool(a.project) == bool(a.workspace):
        unavailable('Supply a physical device ID/platform and exactly one test-host project or workspace.')
    inventory = a.output/'device.json'
    result = command(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', a.device_id,
                      '--json-output', str(inventory)])
    if result.returncode or not inventory.is_file(): unavailable('Physical device details unavailable.')
    data = json.loads(inventory.read_text()).get('result', {})
    hardware = data.get('hardwareProperties', {})
    device = data.get('deviceProperties', {})
    report['deviceDetails'] = data
    if hardware.get('reality') != 'physical': unavailable('Selected target is not confirmed physical hardware.')
    version = str(device.get('osVersionNumber', ''))
    if not version: unavailable('Device OS version unavailable.')
    if a.minimum_runtime and tuple(version.split('.')[:2]) != ('26', '0'):
        unavailable('Selected physical device does not run OS 26.0.')
    container = ['-project', str(a.project.resolve())] if a.project else ['-workspace', str(a.workspace.resolve())]
    argv = ['xcodebuild', *container, '-scheme', a.scheme, '-destination',
            'platform='+a.platform+',id='+a.device_id, '-resultBundlePath', str(a.output/'runtime.xcresult'), 'test']
report['status'] = 'running'; save()
start = time.monotonic()
try:
    with (a.output/'tests.log').open('w') as log:
        result = subprocess.run(argv, cwd=a.repo, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
    report.update(command=argv, exitCode=result.returncode, elapsedSeconds=time.monotonic()-start,
                  sourcesUnchanged=sources() == report['sourceSHA256'])
    if a.mode == 'physical':
        summary = command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(a.output/'runtime.xcresult')])
        try: report['testSummary'] = json.loads(summary.stdout)
        except ValueError: report['testSummary'] = None
        # An external Xcode host must separately prove which package sources it
        # linked. Record execution without falsely qualifying this checkout.
        report['status'] = 'executed-unverified-source' if result.returncode == 0 else 'failed'
        report['sourceVerification'] = 'Required: retain test-host package resolution and linked-object/source manifest before qualification.'
    else:
        tests = ET.parse(a.output/'tests.xml').getroot()
        counts = {key: len(list(tests.iter(tag))) for key, tag in
                  [('executed', 'testcase'), ('failed', 'failure'), ('errors', 'error'), ('skipped', 'skipped')]}
        report['testCounts'] = counts
        report['status'] = 'passed' if result.returncode == 0 and report['sourcesUnchanged'] and counts['executed'] > 0 and not any(counts[k] for k in ['failed', 'errors', 'skipped']) else 'failed'
except (OSError, subprocess.SubprocessError, ET.ParseError) as e:
    report.update(status='failed', failure=str(e))
save()
raise SystemExit(0 if report['status'] == 'passed' else 1)
