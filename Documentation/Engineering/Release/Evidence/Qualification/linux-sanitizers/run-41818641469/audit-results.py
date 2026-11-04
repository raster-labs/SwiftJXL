import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
revision = '2345c7b9fb1c329463cf4f3ba5bc3194fea51193'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
paths = ['Package.swift', 'VERSION', 'Sources', 'Tests', 'Scripts/TestSupport/modular-profile-oracle.c',
         'Scripts/TestSupport/modular-info-oracle.cmake', 'Scripts/Qualification/VarDCTARM/reciprocal-vectors.c']
archive = subprocess.check_output(['git', 'archive', revision, *paths])
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    expected = {m.name: hashlib.sha256(tar.extractfile(m).read()).hexdigest() for m in tar if m.isfile()}
runner = hashlib.sha256(subprocess.check_output(['git', 'show', revision + ':Scripts/qualify-linux-sanitizer.py'])).hexdigest()
expected_profiles = {(b, c, a, t, i) for b in range(8, 17) for c, a in [(1, 0), (2, 0), (2, 1), (3, 0), (4, 0), (4, 1)]
                     for t in [1, 13] for i in range(4)}
results = []
expected_cells = {f'linux-{a}-swift-{v}-{s}' for a in ['aarch64', 'x86_64']
                  for v in ['6.2', '6.4'] for s in ['address', 'thread']}
for p in sorted(root.glob('linux-*-swift-*/report.json')):
    r = json.loads(p.read_text())
    directory = p.parent
    row = {'cell': directory.name, 'reportedStatus': r['status'], 'reportSHA256': sha(p), 'sourceRevision': r['sourceRevision']}
    assert r['sourceSHA256'] == expected and r['runnerSHA256'] == runner and r['workingTree'] == ''
    row['matchesFrozenSourceAndRunner'] = True
    if r['status'] != 'passed':
        row.update(qualified=False, failure=r.get('failure'), xunitOutcome=r.get('xunitOutcome'))
        results.append(row)
        continue
    assert r['exitCode'] == 0 and r['sourceUnchanged'] and r['oracleInputsUnchanged']
    arch = r['environment']['architecture']
    version = '6.2.4' if 'swift-6.2-' in directory.name else '6.4.2'
    assert r['environment']['swift'].startswith(f'Swift version {version} ')
    assert r['environment']['swiftTargetInfo']['target']['triple'] == f'{arch}-unknown-linux-gnu'
    assert r['environment']['githubRunID'] == '41818641469'
    assert r['configuration'] == 'release' and r['buildEngine'] == 'native'
    assert directory.name == f'linux-{arch}-swift-{version[:3]}-{r["sanitizer"]}'
    labels = {c['label']: c for c in r['commands']}
    log_hashes = {}
    for label, c in labels.items():
        path = directory / c['log']
        raw = path.read_bytes()
        text = raw.decode('utf-8', errors='replace')
        log_hashes[c['log']] = sha(path)
        assert c['logSHA256'] == sha(path) and c['logBytes'] == len(raw)
        assert set(c['streams']) == {'stdout', 'stderr'}
        for stream, record in c['streams'].items():
            stream_path = directory / record['log']
            assert sha(stream_path) == record['logSHA256'] and stream_path.stat().st_size == record['logBytes']
            stream_raw = stream_path.read_bytes()
            try:
                stream_raw.decode('utf-8')
                assert record['validUTF8'] is True
            except UnicodeDecodeError:
                assert record['validUTF8'] is False and 'decodeError' in record
        out = (directory / c['streams']['stdout']['log']).read_bytes()
        err = (directory / c['streams']['stderr']['log']).read_bytes()
        assert raw == out + (b'\n' if out and err else b'') + err
        if label == 'probe-negative-run':
            assert c['exitCode'] == 66 and any(s in text for s in c['expectedDiagnostics'])
        elif label.startswith('vector-'):
            assert c['exitCode'] == 1 and c['expectedTestFailure'] in text
        else:
            assert c['exitCode'] == 0
        if label != 'probe-negative-run':
            assert not re.search(r'ERROR: (?:AddressSanitizer|LeakSanitizer)|WARNING: ThreadSanitizer|FATAL: ThreadSanitizer', text)
    command = labels['full-tests']['argv']
    assert command[command.index('--sanitize') + 1] == r['sanitizer']
    for label in ['full-tests', 'test-discovery']:
        argv = labels[label]['argv']
        assert argv[argv.index('--build-system') + 1] == 'native'
        assert argv[argv.index('-c') + 1] == 'release'
        assert argv[argv.index('--sanitize') + 1] == r['sanitizer']
    assert r['sanitizerOptions'] == {'ASAN_OPTIONS': 'halt_on_error=1:exitcode=66:detect_leaks=1',
                                     'TSAN_OPTIONS': 'halt_on_error=1:exitcode=66'}
    xml = directory / 'tests.xml'
    cases = ET.parse(xml).findall('.//testcase')
    # Discovery uses module.function for free functions, module.Suite/function
    # for suite methods. xUnit records the module as the free-function class.
    names = [c.get('classname') + ('/' if '.' in c.get('classname') else '.') + c.get('name') for c in cases]
    assert set(names) == set(json.loads((directory / 'discovered-tests.json').read_text()))
    discovered_stdout = (directory / 'test-discovery.stdout.log').read_text(errors='replace')
    assert set(names) == {line for line in discovered_stdout.splitlines()
                          if line.startswith(('SwiftJXLTests.', 'SwiftJXLCoreTests.'))}
    assert len(names) == len(set(names)) == 374
    assert all(c.find('failure') is None and c.find('error') is None and c.find('skipped') is None for c in cases)
    assert sha(xml) == r['xunitSHA256']
    counts = []
    for line in (directory / 'full-tests.stdout.log').read_text(errors='replace').splitlines():
        if re.search(r'\bTest (?!run\b|case\b).+ passed after', line):
            match = re.search(r'with (\d+) test cases passed', line)
            counts.append(int(match.group(1)) if match else 1)
    assert len(counts) == 374 and sum(counts) == 2059
    profiles = []
    for f in sorted((directory / 'oracle-fixtures').glob('public-matrix-*/oracle.json')):
        d = json.loads(f.read_text())
        assert d['width'] == 5 and d['height'] == 3
        profiles.append(tuple(d[k] for k in ['bits', 'channels', 'premultiplied', 'transferFunction', 'renderingIntent']))
        assert sha(f) == r['independentProfileCoverage']['sha256'][str(f.relative_to(directory / 'oracle-fixtures'))]
    assert len(profiles) == 432 and set(profiles) == expected_profiles
    for sentinel in r['hardwareReciprocalVectors']['sentinels']:
        f = directory / ('vector-' + sentinel['name'] + '.xml')
        selected = ET.parse(f).findall('.//testcase')
        assert sentinel['verified'] and sha(f) == sentinel['xunitSHA256']
        assert len(selected) == 1 and selected[0].find('failure') is not None and selected[0].find('skipped') is None
    assert len(r['hardwareReciprocalVectors']['sentinels']) == 3
    arch = r['environment']['architecture']
    assert r['oracleManifestSHA256'] == sha(root / ('linux-sanitizer-oracle-' + arch) / 'manifest.json')
    assert r['hardwareReciprocalVectors']['manifestSHA256'] == sha(root / 'linux-sanitizer-arm-vectors/manifest.json')
    row.update(qualified=True, declarations=len(cases), argumentCases=sum(counts), independentProfiles=len(profiles),
               vectorSentinels=3, logSHA256=log_hashes)
    results.append(row)
assert {r['cell'] for r in results} == expected_cells
jobs = json.loads((root / 'github-jobs.json').read_text())['jobs']
assert len(jobs) == 10 and all(j['status'] == 'completed' and j['conclusion'] == 'success' for j in jobs)
summary = {'runID': 41818641469, 'headRevision': revision, 'frozenSourceFixtureAndInputFileCount': len(expected),
           'auditorSHA256': sha(Path(__file__)), 'qualifiedCells': sum(r['qualified'] for r in results),
           'allEightQualified': len(results) == 8 and all(r['qualified'] for r in results), 'cells': results,
           'scope': 'Independent separate-stream, exact-test-identity, profile, sentinel and frozen-source audit; no historical warning reconstruction'}
(root / 'independent-result-audit.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({k: v for k, v in summary.items() if k != 'cells'}))
