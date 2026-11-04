"""Read-only independent review of the final archived simulator qualification."""
from pathlib import Path
import copy
import datetime
import hashlib
import importlib.util
import json
import re
import sys

sys.dont_write_bytecode = True
base = Path('Documentation/Engineering/Release/Evidence/Qualification/apple-simulators')
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
load = lambda p: json.loads(Path(p).read_text())
index = load(base / 'qualification-index.json')
assert index['status'] == 'passed' and not index['failedChecks'] and not index['physicalDevicesQualified']
actual = {str(p.relative_to(base)) for p in base.rglob('*') if p.is_file() and p.name != 'qualification-index.json'}
assert actual == set(index['archivedFilesSHA256']) and len(actual) == 820
assert sum((base / p).stat().st_size for p in actual) == index['archiveBytes'] == 32336784
assert all(sha(base / p) == digest for p, digest in index['archivedFilesSHA256'].items())
assert all(sha(p) == digest for p, digest in index['currentSourcesSHA256'].items())
assert len(index['currentSourcesSHA256']) == 1199
spec = importlib.util.spec_from_file_location('simulator_auditor', 'Scripts/TestSupport/audit-apple-simulator-receipt.py')
auditor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auditor)
assert auditor.suite.source_hashes(Path.cwd()) == index['currentSourcesSHA256']
binding_path = Path('Documentation/Engineering/Release/Evidence/Qualification/linux-sanitizers/run-41818641469/current-source-binding.json')
binding = load(binding_path)
assert binding['status'] == 'passed'
for p, record in index['watchOnlyTestProjection'].items():
    own = binding['nonWatchTestProjection'][p]
    assert record['beforeSHA256'] == own['baselineSHA256'] and record['afterSHA256'] == own['currentSHA256']
    assert record['inactiveWatchBlocks'] == own['inactiveWatchBlocks'] and own['nonWatchBytesUnchanged']
results = []
binary_checks = []
diagnostics = re.compile(r'(?:ERROR|WARNING|SUMMARY):\s*(?:AddressSanitizer|LeakSanitizer|ThreadSanitizer)|AddressSanitizer:DEADLYSIGNAL|ThreadSanitizer: (?:data race|reported)')
for name, configurations in [('ios26', ['debug', 'asan', 'tsan']), ('tvos26', ['release']), ('visionos26', ['release']), ('watchos26', ['release'])]:
    directory = base / name
    report = load(directory / 'report.json')
    original_audit = load(directory / 'audit.json')
    assert report['status'] == original_audit['status'] == 'passed'
    assert original_audit['receiptSHA256'] == sha(directory / 'report.json') and not original_audit['failedChecks']
    assert set(original_audit['selectedConfigurations']) == set(configurations) and not original_audit['excludedConfigurations']
    review = auditor.audit(directory / 'report.json', configurations, base / 'hardware-reciprocal/reciprocal-vectors.json')
    expected_failures = [] if name == 'watchos26' else ['sourcesMatchCurrent']
    assert review['failedChecks'] == expected_failures
    changed = {p for p in set(report['sourceHashesAfter']) | set(index['currentSourcesSHA256'])
               if report['sourceHashesAfter'].get(p) != index['currentSourcesSHA256'].get(p)}
    assert changed == (set() if name == 'watchos26' else set(index['watchOnlyTestProjection']))
    for p in changed:
        assert report['sourceHashesAfter'][p] == index['watchOnlyTestProjection'][p]['beforeSHA256']
    commands = {c['label']: c for c in report['commands']}
    logs = {label: (directory / c['log']).read_text() for label, c in commands.items()}
    for run in report['runs']:
        cfg = run['configuration']
        assert run['tree']['declarationsCount'] == 362 and run['tree']['totalCases'] == 1960
        assert run['tree']['passedCases'] == 1960 and run['tree']['failedCases'] == run['tree']['skippedCases'] == 0
        assert run['acceptance']['passed'] and run['acceptance']['device']['osVersion'] == '26.0'
        assert run['acceptance']['device']['architecture'] == 'arm64'
        assert not diagnostics.search(logs[cfg + '-tests'])
        for sentinel in run['reciprocalSentinels']:
            label = cfg + '-sentinel-' + sentinel['name']
            assert commands[label]['exitCode'] == 65 and not diagnostics.search(logs[label])
            assert sentinel['verified'] and sentinel['summary']['failedTests'] == sentinel['summary']['totalTestCount'] == 1
        if cfg in ('asan', 'tsan'):
            proof = run['instrumentationProof']
            checked = auditor.suite.assess_instrumentation(cfg, proof, logs, report['commands'], run['artifacts'])
            assert checked == proof['acceptance'] and checked['passed']
            for entry in proof['entries']:
                assert sha(entry['absolutePath']) == entry['sha256Before'] == entry['sha256After']
                if 'linkFileList' in entry:
                    link = entry['linkFileList']
                    assert sha(link['path']) == link['sha256Before'] == link['sha256After']
            no_hooks = dict(logs)
            no_hooks[proof['entries'][0]['symbolLog']] = ''
            assert not auditor.suite.assess_instrumentation(cfg, proof, no_hooks, report['commands'], run['artifacts'])['passed']
            altered = copy.deepcopy(proof)
            altered['entries'][0]['sha256After'] = '0' * 64
            assert not auditor.suite.assess_instrumentation(cfg, altered, logs, report['commands'], run['artifacts'])['passed']
            binary_checks.append({'configuration': cfg, 'fourRetainedProductHashesVerified': True,
                                  'actualHookLinkageAndLinkInputProofReconciled': True, 'missingHooksAndChangedBinaryControlsRejected': True})
        results.append({'platform': name, 'configuration': cfg, 'declarations': 362, 'cases': 1960,
                        'failures': 0, 'skips': 0, 'negativeVectorSentinels': 3})
    results[-1]['rawReceiptSHA256'] = sha(directory / 'report.json')
    results[-1]['reconciledAuditCheckCount'] = len(review['checks'])
    results[-1]['strictCurrentByteDifference'] = expected_failures
assert len(results) == 6
watch = load(base / 'watch-profile/report.json')
assert watch['status'] == 'passed' and watch['sourcesAndDriversUnchanged'] and watch['jpegOracleUnchanged']
assert watch['sourceHashes'] == index['currentSourcesSHA256']
assert watch['suiteReportSHA256'] == sha(base / 'watchos26/report.json')
assert all(sha(p) == digest for p, digest in watch['driverHashes'].items())
assert len(watch['result']['checks']) == len(set(watch['result']['checks'])) == 15
assert watch['result']['jpegExtendedCases'] == 91 and watch['result']['memoryCeilingBytes'] == 33554432
for command in watch['commands']:
    assert command['exitCode'] == 0 and sha(base / 'watch-profile' / command['log']) == command['logSHA256']
assert json.loads((base / 'watch-profile/probe.log').read_text()) == watch['result']
assert all(c['exitCode'] == 0 for c in watch['cleanup'])
reference = watch['jpegReference']
assert reference == load(base / index['oraclePreflight'])['jpegReference']
assert reference['replayedByteForByte'] and sha(reference['oracle']) == reference['oracleSHA256']
assert reference['nonSystemDependencySHA256'] and all(sha(p) == digest for p, digest in reference['nonSystemDependencySHA256'].items())
for directory in [base / 'watch-profile', base / 'watch-profile-oracle-preflight']:
    pgm = (directory / 'gray-reference.pgm').read_bytes()
    assert pgm == (directory / 'gray-reference-replay.pgm').read_bytes()
    assert sha(directory / 'gray-reference.pgm') == reference['pgmSHA256']
    header = re.match(rb'P5\n([0-9]+) ([0-9]+)\n255\n', pgm)
    assert tuple(map(int, header.groups())) == (31, 17)
    assert pgm[header.end():] == (directory / 'fixtures/gray.raw').read_bytes()
    assert len(pgm[header.end():]) == reference['bytes'] == 527
    assert sha(directory / 'fixtures/gray.raw') == reference['rawSHA256']
    assert sha(directory / 'fixtures/gray.jpg') == reference['sourceSHA256']
assert all(load(base / p)['status'] == 'failed' for p in index['preservedFailures'])
vectors = base / 'hardware-reciprocal/reciprocal-vectors.json'
assert len(load(vectors)) == 45826 and sha(vectors) == '25b402b28eb3dc355f00c2d3c1cd1e130f49e45c6ced1c01550a1b82e7d5453b'
report = {'status': 'passed', 'auditedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'indexPath': str(base / 'qualification-index.json'), 'indexSHA256': sha(base / 'qualification-index.json'),
          'archivedFileCountVerified': len(actual), 'archivedBytesVerified': index['archiveBytes'],
          'sourceAndFixtureCountVerified': 1199, 'configurations': results, 'instrumentation': binary_checks,
          'watchSupplement': {'checks': 15, 'jpegCases': 91, 'configuredMemoryCeilingBytes': 33554432,
                              'measuredRSSBytes': None, 'independentJPEGOracleBinaryLibraryAndReplayVerified': True},
          'preservedFailedReceipts': index['preservedFailures'], 'inactiveWatchProjectionAudit': {'path': str(binding_path), 'sha256': sha(binding_path)},
          'scope': 'Independent raw archive/hash/source review, re-parsed discovery/results/console and instrumentation acceptance. Three non-Watch strict current-byte re-audits differ only in the two explicitly reviewed inactive Watch test branches; original raw receipts and audits remain unchanged. Actual retained ASan/TSan products and link lists still match recorded hashes. Simulator qualification only; no physical-device or measured-RSS claim.',
          'auditorSHA256': sha(Path(__file__))}
Path('.build/simulator-independent-final-audit.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k in ['status', 'archivedFileCountVerified', 'archivedBytesVerified', 'sourceAndFixtureCountVerified']}))
