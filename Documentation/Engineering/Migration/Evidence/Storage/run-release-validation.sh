#!/bin/bash
set -euo pipefail
python3 - <<'PYTHON'
import datetime, hashlib, json, os, re, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path('/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl')
previous = root / 'work/evidence/scalar-storage-qualification-v2-release'
old = json.loads((previous / 'report.json').read_text())
repo = Path(old['repository'])
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
output = root / 'outputs' / ('release-validation-' + stamp)
output.mkdir()
env = dict(os.environ, DEVELOPER_DIR=old['developer_dir'],
    CLANG_MODULE_CACHE_PATH=str(previous / 'clang-cache'),
    SWIFTPM_MODULECACHE_OVERRIDE=str(previous / 'swift-cache'),
    SWIFTJXL_ORACLE_BIN='/opt/homebrew/bin',
    SWIFTJXL_ORACLE_OUTPUT=str(output / 'oracle'))
report = {'status': 'running', 'commands': [], 'source_files_sha256': {}}
for folder in ('Sources', 'Tests'):
    for path in sorted((repo / folder).rglob('*.swift')):
        report['source_files_sha256'][str(path.relative_to(repo))] = hashlib.sha256(path.read_bytes()).hexdigest()
report['manifest_sha256'] = hashlib.sha256((repo / 'Package.swift').read_bytes()).hexdigest()
def save():
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
def run(label, command):
    print('Running ' + label + '...', flush=True)
    with (output / (label + '.log')).open('w') as log:
        result = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    report['commands'].append({'label': label, 'argv': command, 'exit_code': result.returncode})
    save()
    if result.returncode:
        raise RuntimeError(label + ' failed; inspect ' + str(output / (label + '.log')))
    print(label + ': passed', flush=True)
    return (output / (label + '.log')).read_text()
try:
    for name in ('cjxl', 'djxl'):
        tool = Path(env['SWIFTJXL_ORACLE_BIN']) / name
        if not os.access(tool, os.X_OK):
            raise RuntimeError('Reference codec is unavailable: ' + str(tool))
    command = next(c['argv'] for c in old['commands'] if c['label'] == 'release-clean-build')
    run('release-incremental-build', command)
    tests = list(command)
    tests[2] = 'test'
    xctest = any(re.search(r'\bimport\s+XCTest\b|:\s*XCTestCase\b', p.read_text()) for p in (repo / 'Tests').rglob('*.swift'))
    frameworks = ['--enable-swift-testing', '--enable-xctest' if xctest else '--disable-xctest']
    listing = run('release-discovery', tests + ['list'] + frameworks)
    modules = set(re.findall(r'\.testTarget\s*\(\s*name:\s*"([^"]+)"', (repo / 'Package.swift').read_text()))
    names = [line.strip() for line in listing.splitlines() if line.split('.', 1)[0] in modules]
    if not names:
        raise RuntimeError('No tests discovered')
    xml = output / 'release-tests.xml'
    log = run('release-tests', tests + frameworks + ['--skip-build', '--xunit-output', str(xml)])
    cases = ET.parse(xml).findall('.//testcase')
    failed = sum(c.find('failure') is not None or c.find('error') is not None for c in cases)
    skipped = sum(c.find('skipped') is not None for c in cases)
    executions = 0
    for line in log.splitlines():
        if re.search(r'\bTest (?!run\b|case\b).+ passed after', line):
            match = re.search(r'with (\d+) test cases passed', line)
            executions += int(match.group(1)) if match else 1
    report.update(discovered_declarations=len(names), executed_declarations=len(cases), failed_declarations=failed, skipped_declarations=skipped, passed_case_executions=executions)
    if len(cases) != len(names) or failed or skipped:
        raise RuntimeError('Test inventory, failure or skip check failed')
    report['status'] = 'passed_requested_release_checks'
    print('PASS: ' + str(len(cases)) + ' test declarations; ' + str(executions) + ' case executions.', flush=True)
except Exception as error:
    report['status'] = 'failed'
    report['failure'] = str(error)
    print(str(error), file=sys.stderr)
finally:
    report['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
    print('Results: ' + str(output), flush=True)
if report['status'] == 'failed':
    sys.exit(1)
PYTHON
