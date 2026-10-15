#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Qualify precompiled owning API probes against installed Apple simulators.

Uses the recorded runtime inventory and a new disposable device set. This bounded
32 MiB smoke profile is not the full runtime suite or physical-device evidence.
"""
import argparse, json, pathlib, subprocess, sys, uuid
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=pathlib.Path)
parser.add_argument('--platform', action='append', choices=['ios', 'tvos', 'visionos', 'watchos'])
parser.add_argument('--runtime-version', help='Require this exact runtime version rather than selecting an installed eligible runtime')
args = parser.parse_args()
root = args.root.resolve()
records = json.loads((root / 'compile.json').read_text())
runtimes = json.loads((root / 'runtimes.json').read_text())['runtimes']
device_set = root / ('devices-' + str(uuid.uuid4()))
device_set.mkdir(exist_ok=False)
report = {'deviceSet': str(device_set), 'commands': [], 'runs': [],
          'scope': 'Simulator smoke checks only; no physical-device or native Intel claim.'}
base = ['xcrun', 'simctl', '--set', str(device_set)]
def save():
    (root / 'runtime-report.json').write_text(json.dumps(report, indent=2) + '\n')
def run(args, timeout=180, check=True):
    command = base + args
    try:
        p = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        entry = {'command': command, 'exitCode': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}
    except subprocess.TimeoutExpired as e:
        entry = {'command': command, 'timeoutSeconds': timeout, 'stdout': str(e.stdout), 'stderr': str(e.stderr)}
        report['commands'].append(entry); save(); raise
    report['commands'].append(entry); save()
    if check and p.returncode: raise RuntimeError(entry)
    return p
try:
    names = {'ios': 'iOS', 'tvos': 'tvOS', 'visionos': 'xrOS', 'watchos': 'watchOS'}
    for platform in args.platform or names:
        def version(runtime):
            return tuple(int(part) for part in runtime['version'].split('.'))
        eligible = [r for r in runtimes if r['platform'] == names[platform] and r['isAvailable']
                    and version(r) >= (26, 0) and
                    (args.runtime_version is None or r['version'] == args.runtime_version)]
        if not eligible:
            raise RuntimeError('Required simulator runtime unavailable: ' + platform + ' ' + str(args.runtime_version or '>=26.0'))
        # Prefer the deployment floor when installed; otherwise record the
        # actual lowest eligible version without treating it as floor proof.
        runtime = min(eligible, key=version)
        binary = next(r['binary'] for r in records if r['platform'] == platform)
        device = None
        try:
            created = run(['create', 'SwiftJXL-Smoke-' + platform, runtime['supportedDeviceTypes'][0]['identifier'], runtime['identifier']])
            device = str(uuid.UUID(created.stdout.strip()))
            run(['boot', device])
            run(['bootstatus', device, '-b'], timeout=240)
            result = run(['spawn', device, binary, str(root / 'fixtures')], timeout=90)
            payload = json.loads(result.stdout)
            if payload['status'] != 'passed': raise RuntimeError(payload)
            report['runs'].append({'platform': platform, 'runtime': runtime, 'deviceUUID': device, 'result': payload})
            print(platform + ': passed', flush=True)
        finally:
            if device:
                shutdown = run(['shutdown', device], check=False)
                deleted = run(['delete', device], check=False)
                report.setdefault('cleanup', []).append({'uuid': device, 'shutdownExit': shutdown.returncode, 'deleteExit': deleted.returncode})
                save()
                if deleted.returncode: raise RuntimeError('Disposable device deletion failed')
    report['status'] = 'passed'
except Exception as e:
    report['status'] = 'failed'; report['failure'] = str(e)
    print(str(e), file=sys.stderr)
finally:
    report['finalDevices'] = json.loads(run(['list', 'devices', '-j']).stdout)
    save()
sys.exit(0 if report['status'] == 'passed' else 1)
