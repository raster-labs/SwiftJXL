#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Execute native macOS or explicitly selected physical Apple-device gates.

A missing host/device/runtime is UNEXECUTED and exits 2. Cross-compilation and
Rosetta never satisfy native Intel. Run after implementation is frozen. For a
physical device, supply its ID and an Xcode project/workspace that hosts the
package tests; the runner never signs, installs or chooses a device implicitly.
Native suites require pinned cjxl/djxl through SWIFTJXL_ORACLE_BIN and the
profile oracle through SWIFTJXL_PROFILE_ORACLE, with retained output coverage.
SWIFTJXL_ARM_RECIPROCAL_VECTORS must bind the native ARM reference supplement.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


def normalise_test_identity(identity, modules):
    """Reconcile only Swift Testing's top-level function separator with xUnit."""
    for module in modules:
        if identity.startswith(module + '/'):
            return identity
        if identity.startswith(module + '.'):
            suffix = identity[len(module) + 1:]
            return identity if '/' in suffix else module + '/' + suffix
    raise ValueError('Test identity does not belong to a declared test module: ' + identity)


def suite_identity_coverage(discovered, executed, modules, required):
    discovered = [normalise_test_identity(name, modules) for name in discovered]
    executed = [normalise_test_identity(name, modules) for name in executed]
    missing = sorted(set(discovered) - set(executed))
    unexpected = sorted(set(executed) - set(discovered))
    unique = len(discovered) == len(set(discovered)) and len(executed) == len(set(executed))
    required_present = all(any(name.rsplit('/', 1)[-1].split('(', 1)[0] == item for name in executed)
                           for item in required)
    return {'passed': bool(discovered) and unique and not missing and not unexpected and required_present,
            'discoveredDeclarations': len(discovered), 'executedDeclarations': len(executed),
            'identitiesUnique': unique, 'exactIdentitySetAgreement': not missing and not unexpected,
            'missing': missing, 'unexpected': unexpected,
            'requiredLifetimeRaceAndOracleTests': required, 'requiredTestsPresent': required_present,
            'normalisedDiscovered': sorted(discovered), 'normalisedExecuted': sorted(executed)}


def console_coverage(stdout, stderr, expected):
    summaries, failures = [], []
    for stream, text in [('stdout', stdout), ('stderr', stderr)]:
        summaries += [{'stream': stream, 'declarations': int(match.group(1))}
                      for match in re.finditer(r'^✔ Test run with (\d+) tests?(?: in \d+ suites?)? passed after [0-9.]+ seconds\.$', text, re.M)]
        failures += [{'stream': stream, 'line': line} for line in text.splitlines()
                     if line.startswith('✘') or re.search(r'(?:ERROR|SUMMARY): (?:AddressSanitizer|LeakSanitizer|ThreadSanitizer)|(?:WARNING|FATAL): ThreadSanitizer', line)]
    return {'passed': len(summaries) == 1 and summaries[0]['declarations'] == expected and not failures,
            'passingSummaries': summaries, 'failureDiagnostics': failures,
            'bothStreamsInspected': True}


def run_raw(argv, output, stem, cwd, env, timeout=3600):
    """Persist exact streams and process outcome before attempting text decoding."""
    stdout_path, stderr_path = output/(stem + '.stdout.log'), output/(stem + '.stderr.log')
    record = {'command': argv, 'exitCode': None, 'stdout': stdout_path.name, 'stderr': stderr_path.name}
    started = time.monotonic()
    try:
        with stdout_path.open('wb') as stdout, stderr_path.open('wb') as stderr:
            result = subprocess.run(argv, cwd=cwd, stdout=stdout, stderr=stderr, timeout=timeout, env=env)
        record['exitCode'] = result.returncode
        return result, record
    except (OSError, subprocess.SubprocessError) as error:
        record['processFailure'] = str(error)
        raise
    finally:
        record['seconds'] = time.monotonic() - started
        for stream, path in [('stdout', stdout_path), ('stderr', stderr_path)]:
            if path.exists():
                data = path.read_bytes()
                record[stream + 'Bytes'] = len(data)
                record[stream + 'SHA256'] = hashlib.sha256(data).hexdigest()
        if stdout_path.exists() and stderr_path.exists():
            combined = output/(stem + '.log')
            combined.write_bytes(stdout_path.read_bytes() + stderr_path.read_bytes())
            record['combinedLog'] = {'path': combined.name, 'ordering': 'stdout then stderr; not chronological',
                                     'sha256': hashlib.sha256(combined.read_bytes()).hexdigest()}
        (output/(stem + '-process.json')).write_text(json.dumps(record, indent=2) + '\n')


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--output', type=Path, required=True)
p.add_argument('--mode', choices=['native-intel', 'native-macos', 'physical'], required=True)
p.add_argument('--minimum-runtime', action='store_true', help='Require exactly the 26.0 major/minor runtime')
p.add_argument('--build-system', choices=['native', 'swiftbuild'], default='swiftbuild',
               help='Explicit SwiftPM engine; use native for Swift 6.2, never silently fall back')
p.add_argument('--testing-framework-path', type=Path,
               help='Explicit native Swift Testing framework directory for a Command Line Tools installation')
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
          'packageManifestSHA256': sha(a.repo/'Package.swift'),
          'minimumRuntimeRequired': a.minimum_runtime, 'buildSystem': a.build_system}
if a.testing_framework_path:
    a.testing_framework_path = a.testing_framework_path.resolve()
    report['testingFrameworkPath'] = str(a.testing_framework_path)
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
if a.testing_framework_path and (a.mode == 'physical' or not (a.testing_framework_path/'Testing.framework').is_dir()):
    unavailable('An existing native Testing.framework directory is required for --testing-framework-path.')
if a.mode != 'physical':
    translated = command(['sysctl', '-n', 'sysctl.proc_translated'])
    if translated.stdout.strip() == '1': unavailable('Rosetta is not native runtime evidence.')
    if a.mode == 'native-intel' and platform.machine() != 'x86_64':
        unavailable('Native Intel Mac unavailable: host architecture is ' + platform.machine())
    version = command(['sw_vers', '-productVersion']).stdout.strip()
    report['runtimeVersion'] = version
    if a.minimum_runtime and tuple(version.split('.')[:2]) != ('26', '0'):
        unavailable('macOS 26.0 runtime unavailable: host runs ' + version)
    oracle_bin = os.environ.get('SWIFTJXL_ORACLE_BIN')
    profile_oracle = os.environ.get('SWIFTJXL_PROFILE_ORACLE')
    if not oracle_bin or not profile_oracle:
        unavailable('Native qualification requires SWIFTJXL_ORACLE_BIN and SWIFTJXL_PROFILE_ORACLE.')
    oracle_paths = [Path(oracle_bin).resolve()/name for name in ['cjxl', 'djxl']] + [Path(profile_oracle).resolve()]
    if not all(path.is_file() and os.access(path, os.X_OK) for path in oracle_paths):
        unavailable('All three independent native oracle executables are required.')
    report['oracleExecutables'] = {str(path): sha(path) for path in oracle_paths}
    vector_path = os.environ.get('SWIFTJXL_ARM_RECIPROCAL_VECTORS')
    if not vector_path or not Path(vector_path).is_file():
        unavailable('Native qualification requires retained SWIFTJXL_ARM_RECIPROCAL_VECTORS.')
    vector_path = Path(vector_path).resolve()
    try:
        vectors = json.loads(vector_path.read_text())
        if not isinstance(vectors, list) or len(vectors) < 40000:
            unavailable('The native ARM reference supplement is incomplete.')
    except (OSError, ValueError) as e:
        unavailable('The native ARM reference supplement is unreadable: ' + str(e))
    report['armReciprocalVectors'] = {'path': str(vector_path), 'sha256': sha(vector_path), 'count': len(vectors)}
    oracle_output = Path(os.environ.get('SWIFTJXL_ORACLE_OUTPUT', str(a.output/'oracle-outputs'))).resolve()
    if any(oracle_output.glob('public-matrix-*/oracle.json')):
        unavailable('Use a fresh oracle output directory; existing profile results cannot establish coverage.')
    report['oracleOutput'] = str(oracle_output)
    test_env = dict(os.environ, SWIFTJXL_ORACLE_BIN=str(Path(oracle_bin).resolve()),
                    SWIFTJXL_PROFILE_ORACLE=str(Path(profile_oracle).resolve()),
                    SWIFTJXL_ARM_RECIPROCAL_VECTORS=str(vector_path),
                    SWIFTJXL_ORACLE_OUTPUT=str(oracle_output))
    argv = ['xcrun', 'swift', 'test', '-c', 'release', '--disable-sandbox', '--build-system', a.build_system,
            '--no-parallel', '--enable-swift-testing', '--disable-xctest', '--jobs', '2',
            '--xunit-output', str(a.output/'tests.xml')]
    if a.testing_framework_path:
        path = str(a.testing_framework_path)
        argv += ['-Xswiftc', '-F', '-Xswiftc', path, '-Xlinker', '-F'+path,
                 '-Xlinker', '-rpath', '-Xlinker', path]
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
    test_env = None
report['status'] = 'running'; save()
start = time.monotonic()
try:
    discovered = []
    if a.mode != 'physical':
        discovery = list(argv)
        index = discovery.index('--xunit-output')
        del discovery[index:index+2]
        discovery.append('list')
        discovery_result, discovery_process = run_raw(discovery, a.output, 'discovery', a.repo, test_env)
        report.update(discoveryCommand=discovery, discoveryExitCode=discovery_result.returncode,
                      discoveryProcess=discovery_process)
        save()
        if discovery_result.returncode != 0:
            raise RuntimeError('Native test discovery/build failed; inspect discovery stdout/stderr logs.')
        modules = set(re.findall(r'\.testTarget\s*\(\s*name:\s*"([^"]+)"', (a.repo/'Package.swift').read_text()))
        discovered = [line.strip() for line in (a.output/'discovery.stdout.log').read_text(encoding='utf-8').splitlines()
                      if line.split('.', 1)[0] in modules]
        (a.output/'discovered-tests.json').write_text(json.dumps(discovered, indent=2)+'\n')
        if not discovered:
            raise RuntimeError('No native test declarations discovered.')
        argv.append('--skip-build')
    result, test_process = run_raw(argv, a.output, 'tests', a.repo, test_env)
    report.update(command=argv, exitCode=result.returncode, elapsedSeconds=time.monotonic()-start,
                  testProcess=test_process,
                  sourcesUnchanged=sources() == report['sourceSHA256'] and sha(a.repo/'Package.swift') == report['packageManifestSHA256'])
    save()
    if a.mode == 'physical':
        summary = command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(a.output/'runtime.xcresult')])
        try: report['testSummary'] = json.loads(summary.stdout)
        except ValueError: report['testSummary'] = None
        # An external Xcode host must separately prove which package sources it
        # linked. Record execution without falsely qualifying this checkout.
        report['status'] = 'executed-unverified-source' if result.returncode == 0 else 'failed'
        report['sourceVerification'] = 'Required: retain test-host package resolution and linked-object/source manifest before qualification.'
    else:
        if result.returncode != 0:
            raise RuntimeError('Native test execution failed; inspect test stdout/stderr logs.')
        test_stdout = (a.output/'tests.stdout.log').read_text(encoding='utf-8')
        test_stderr = (a.output/'tests.stderr.log').read_text(encoding='utf-8')
        tests = ET.parse(a.output/'tests.xml').getroot()
        counts = {key: len(list(tests.iter(tag))) for key, tag in
                  [('executed', 'testcase'), ('failed', 'failure'), ('errors', 'error'), ('skipped', 'skipped')]}
        report['testCounts'] = counts
        names = [case.get('classname', '')+'/'+case.get('name', '') for case in tests.iter('testcase')]
        required_tests = ['imageRetainsAdapterAndAllocationUntilLastReader', 'concurrentReadersPreserveEveryLogicalSample',
            'sharedSourceSurvivesCallerReleaseAndOneCancelledEncode', 'concurrentEncodersShareOneImmutableSource',
            'cancellationInsideWorkerIsObservedAndAllWorkersJoin', 'independentBothDirections',
            'optionalFullRangeHardwareReciprocalVectors']
        coverage = suite_identity_coverage(discovered, names, modules, required_tests)
        (a.output/'normalised-test-identities.json').write_text(json.dumps(
            {key: coverage.pop(key) for key in ['normalisedDiscovered', 'normalisedExecuted']}, indent=2) + '\n')
        report['fullSuiteCoverage'] = coverage
        report['fullSuiteCoverage']['identityInventorySHA256'] = sha(a.output/'normalised-test-identities.json')
        report['executionConsoleCoverage'] = console_coverage(test_stdout, test_stderr, counts['executed'])
        complete_suite = coverage['passed'] and report['executionConsoleCoverage']['passed']
        expected_profiles = {(bits, channels, associated, transfer, intent)
            for bits in range(8, 17) for channels in range(1, 5)
            for associated in ([0, 1] if channels % 2 == 0 else [0])
            for transfer in [1, 13] for intent in range(4)}
        profiles = []
        dimensions_valid = True
        profile_files = sorted(oracle_output.glob('public-matrix-*/oracle.json'))
        for path in profile_files:
            data = json.loads(path.read_text())
            dimensions_valid &= data.get('width') == 5 and data.get('height') == 3
            profiles.append(tuple(data.get(k) for k in
                ['bits', 'channels', 'premultiplied', 'transferFunction', 'renderingIntent']))
        profile_passed = dimensions_valid and len(profiles) == len(expected_profiles) and set(profiles) == expected_profiles
        report['independentProfileCoverage'] = {'passed': profile_passed,
            'expected': len(expected_profiles), 'observed': len(profiles),
            'sha256': {str(path.relative_to(oracle_output)): sha(path) for path in profile_files}}
        report['referenceInputsUnchanged'] = all(sha(Path(path)) == value for path, value in report['oracleExecutables'].items()) and sha(vector_path) == report['armReciprocalVectors']['sha256']
        report['status'] = 'passed' if result.returncode == 0 and report['sourcesUnchanged'] and report['referenceInputsUnchanged'] and counts['executed'] > 0 and not any(counts[k] for k in ['failed', 'errors', 'skipped']) and profile_passed and complete_suite else 'failed'
except (OSError, subprocess.SubprocessError, ET.ParseError, ValueError, RuntimeError) as e:
    report.update(status='failed', failure=str(e))
save()
raise SystemExit(0 if report['status'] == 'passed' else 1)
