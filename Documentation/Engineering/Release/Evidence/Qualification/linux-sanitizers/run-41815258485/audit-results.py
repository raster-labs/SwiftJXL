import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
revision = '00f03ff288a7c8e0e2b82d2e71ec22622ede71ae'
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
    labels = {c['label']: c for c in r['commands']}
    log_hashes = {}
    for label, c in labels.items():
        path = directory / c['log']
        raw = path.read_bytes()
        text = raw.decode('utf-8', errors='replace')
        log_hashes[c['log']] = sha(path)
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
    assert r['sanitizerOptions'] == {'ASAN_OPTIONS': 'halt_on_error=1:exitcode=66:detect_leaks=1',
                                     'TSAN_OPTIONS': 'halt_on_error=1:exitcode=66'}
    xml = directory / 'tests.xml'
    cases = ET.parse(xml).findall('.//testcase')
    # Discovery uses module.function for free functions, module.Suite/function
    # for suite methods. xUnit records the module as the free-function class.
    names = [c.get('classname') + ('/' if '.' in c.get('classname') else '.') + c.get('name') for c in cases]
    reported_discovery = set(json.loads((directory / 'discovered-tests.json').read_text()))
    if set(names) != reported_discovery:
        warning = "warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.\n"
        discovery_log = (directory / 'test-discovery.log').read_text()
        assert discovery_log.count(warning) == 1
        # Analyse the preserved raw log without changing it. Its warning split
        # one otherwise intact test name across two lines on Swift 6.4.
        reconstructed = discovery_log.replace(warning, '')
        reconstructed_names = {line for line in reconstructed.splitlines()
                               if line.startswith(('SwiftJXLTests.', 'SwiftJXLCoreTests.'))}
        assert reconstructed_names == set(names)
        row['discoveryWarningInterleaving'] = {
            'originalReportedListMatches': False,
            'rawLogSHA256': sha(directory / 'test-discovery.log'),
            'analysisOnlyRemovedExactWarning': warning,
            'reconstructedRawLogNamesMatchAllExecutedDeclarations': True,
            'originalArtifactsUnmodified': True,
        }
    else:
        row['discoveryWarningInterleaving'] = None
    assert len(names) == len(set(names)) == 374
    assert all(c.find('failure') is None and c.find('error') is None and c.find('skipped') is None for c in cases)
    assert sha(xml) == r['xunitSHA256']
    counts = []
    for line in (directory / 'full-tests.log').read_text(errors='replace').splitlines():
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
summary = {'runID': 41815258485, 'headRevision': revision, 'frozenRuntimeFileCount': len(expected),
           'auditorSHA256': sha(Path(__file__)), 'qualifiedCells': sum(r['qualified'] for r in results),
           'allEightQualified': len(results) == 8 and all(r['qualified'] for r in results), 'cells': results,
           'scope': 'Independent raw-log/xUnit/profile/sentinel/source audit; reporter-failed cell remains unqualified'}
(root / 'independent-result-audit.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({k: v for k, v in summary.items() if k != 'cells'}))
