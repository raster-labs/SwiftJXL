#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Qualify precompiled owning API probes against installed iOS/tvOS/xrOS 26.5.

Uses the recorded runtime inventory and a new disposable device set. This bounded
32 MiB smoke profile is not the full runtime suite or physical-device evidence.
"""
import json, pathlib, subprocess, sys, uuid
root = pathlib.Path(sys.argv[1]).resolve()
records = json.loads((root / 'compile.json').read_text())
runtimes = json.loads((root / 'runtimes.json').read_text())['runtimes']
device_set = root / ('devices-' + str(uuid.uuid4()))
device_set.mkdir(exist_ok=False)
report = {'deviceSet': str(device_set), 'commands': [], 'runs': [], 'watchOS': 'Runtime unavailable; compiler-only qualification.'}
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
    for platform, runtime_platform in [('ios', 'iOS'), ('tvos', 'tvOS'), ('visionos', 'xrOS')]:
        runtime = next(r for r in runtimes if r['platform'] == runtime_platform and r['isAvailable'] and r['version'] == '26.5')
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
