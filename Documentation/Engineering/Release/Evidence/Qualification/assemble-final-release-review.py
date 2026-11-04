#!/usr/bin/env python3
"""Assemble reviewed Milestone 5 receipts; never waive the physical-device gate."""
from pathlib import Path
import datetime
import hashlib
import json
import subprocess

repo = Path.cwd()
base = repo / 'Documentation/Engineering/Release/Evidence/Qualification'
checklist_path = repo / 'Documentation/Engineering/Release/release-gates.json'
frozen = '00f03ff288a7c8e0e2b82d2e71ec22622ede71ae'
checks = []

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def require(value, description):
    if not value:
        raise ValueError(description)
    checks.append(description)

def read(name, status='passed'):
    path = base / name
    data = json.loads(path.read_text())
    require(data.get('status') == status, 'Passing receipt: ' + name)
    return data

def verify_files(files, root=repo):
    for name, digest in files.items():
        require(sha(root / name) == digest, 'Current input hash: ' + name)

checklist = json.loads(checklist_path.read_text())
for group in checklist['sourceGroups'].values():
    files = {str(path.relative_to(repo)): sha(path)
             for pattern in group['includes'] for path in repo.glob(pattern) if path.is_file()}
    require(bool(files), 'Nonempty source group')
    group['files'] = dict(sorted(files.items()))
    group['sha256'] = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
runtime = checklist['sourceGroups']['runtime']['files']
for name, digest in runtime.items():
    original = subprocess.check_output(['git', 'show', frozen + ':' + name], cwd=repo)
    require(hashlib.sha256(original).hexdigest() == digest, 'Frozen runtime: ' + name)
require(checklist['sourceGroups']['runtime']['sha256'] ==
        '30a591977a593e9487429c5289b62a6ed30216d86d029124f31401c67164b753', 'Exact frozen runtime group')
require(sha(repo / 'Documentation/COMMON_CONTRACT_SHA256.txt') == checklist['contractManifestSHA256'], 'Contract manifest unchanged')
for line in (repo / 'Documentation/COMMON_CONTRACT_SHA256.txt').read_text().splitlines():
    digest, name = line.split()
    require(sha(repo / 'Documentation' / name) == digest, 'Contract byte identity: ' + name)

linux = read('linux-sanitizers/final-review.json')
require(linux['qualifiedCells'] == 8 and linux['allEightQualified'] is True and
        all(linux['checks'].values()) and linux['perCell']['declarations'] == 374 and
        linux['perCell']['argumentCases'] == 2059 and linux['perCell']['failures'] == 0 and
        linux['perCell']['skips'] == 0, 'Complete native Linux sanitizer matrix')
minimum = read('macos26/audit-00f03ff.json')
require(minimum['testCounts'] == {'executed': 368, 'failed': 0, 'errors': 0, 'skipped': 0} and
        minimum['argumentCaseExecutionsFromLog'] == 2053 and minimum['cliFoundationChecks'] == 98,
        'Exact-floor native macOS library and CLI execution')
intel = read('native-intel-41818641616/independent-audit.json')
require(intel['declarations'] == 368 and intel['cases'] == 2053 and len(intel['cli']) == 10 and
        sum(row['checks'] for row in intel['cli'].values()) == 1059 and
        all(row['status'] == 'passed' for row in intel['cli'].values()), 'Complete native Intel library and CLI execution')
simulators = read('apple-simulators/qualification-index.json')
simulator_independent = read('apple-simulators-independent-audit.json')
verify_files(simulators['currentSourcesSHA256'])
verify_files(simulators['archivedFilesSHA256'], base / 'apple-simulators')
configurations = [row for platform in simulators['platforms'].values() for row in platform['configurations']]
require(len(configurations) == 6 and all(row['declarations'] == 362 and row['cases'] == 1960 and
        row['failedCases'] == 0 and row['skippedCases'] == 0 and row['reciprocalNegativeSentinels'] == 3
        for row in configurations), 'All six full simulator configurations and vector controls')
cli = read('cli-tsan/independent-audit.json')
require(cli['totalChecks'] == 1059 and len(cli['groups']) == 10 and
        cli['runtimeBytesMatchFrozenAndCurrent'] is True and cli['tsanRuntimeLinked'] is True and
        cli['runtimeDigest'] == checklist['sourceGroups']['runtime']['sha256'], 'Complete source-bound CLI TSan execution')
benchmark = read('linux-lock-benchmark-independent-audit.json', 'audit-passed')
require(benchmark['candidateSourceMatchesFrozenCommit'] is True, 'Benchmark candidate source binding')
code = read('final-code-review.json')

for name in ['consumer-https', 'consumer-versioned']:
    consumer = read(name + '/report.json')
    require(consumer['sourceRevision'] == frozen, name + ' exact source revision')
    verify_files(consumer['sourceSHA256'])
    require(all(value == 'passed' for value in consumer['checks'].values()), name + ' complete acceptance checks')
provenance = read('provenance.json')
require(provenance['sourceCount'] == 120 and provenance['fixtureCount'] == 995, 'Complete source/fixture provenance counts')
sbom = read('sbom/qualified/report.json')
sbom_audit = read('sbom/m5-canonical-origin-sbom-independent-audit.json')
require(sbom['sourceRevision'] == frozen and sbom['runnerSHA256'] == sha(repo / 'Scripts/derive-release-sbom.py'), 'Current SBOM derivation and frozen build')
for artifact in sbom['artifacts']:
    require(artifact['status'] == 'passed' and sha(base / 'sbom/qualified' / artifact['derivedPath']) == artifact['derivedSHA256'], 'Validated derived SBOM: ' + artifact['specification'])
require(sbom['artifacts'][0]['shacl']['conforms'] is True and
        sbom['artifacts'][0]['shacl']['missingRequiredTimestampRejected'] is True, 'Active full SPDX semantic validation')
security = read('security-policy.json')
require(security['policySHA256'] == sha(repo / 'SECURITY.md') and security['checks'][0]['stdout'] == {'enabled': True}, 'Current support policy and enabled private reporting')
docs = read('docs.json')
verify_files(docs['filesSHA256'])
regressions = read('validator-regressions.json')
require(regressions['totalTests'] == 74 and all(row['exitCode'] == 0 for row in regressions['commands']), 'All 74 validator regression tests passed')
for row in regressions['commands']:
    require(sha(repo / row['command'][1]) == row['testScriptSHA256'], 'Unchanged tested validator: ' + row['command'][1])

facts = {
    'M4-LINUX-SANITIZERS': ['linux-sanitizers/final-review.json'],
    'M4-MACOS-MINIMUM': ['macos26/audit-00f03ff.json'],
    'M4-MACOS-INTEL': ['native-intel-41818641616/independent-audit.json'],
    'M4-IOS-SANITIZERS': ['apple-simulators/qualification-index.json', 'apple-simulators-independent-audit.json'],
    'M4-CLI-TSAN': ['cli-tsan/independent-audit.json'],
    'M4-OTHER-SIMULATORS': ['apple-simulators/qualification-index.json', 'apple-simulators-independent-audit.json'],
    'M5-URL-CONSUMER': ['consumer-https/report.json'],
    'M5-VERSIONED-CONSUMER': ['consumer-versioned/report.json'],
    'M5-DOCS-EXAMPLES': ['docs.json', 'consumer-https/report.json', 'consumer-versioned/report.json'],
    'M5-LICENCE-PROVENANCE': ['provenance.json'],
    'M5-EVIDENCE-REVIEW': ['final-code-review.json', 'validator-regressions.json', 'linux-lock-benchmark-independent-audit.json'],
    'RELEASE-SBOM-SCHEMA': ['sbom/qualified/report.json', 'sbom/m5-canonical-origin-sbom-independent-audit.json'],
    'RELEASE-SECURITY-POLICY': ['security-policy.json'],
}
gate_results = {name: {'status': 'passed', 'receipts': [{'path': path, 'sha256': sha(base / path)} for path in paths]}
                for name, paths in facts.items()}
excluded = {'final-review.json', 'readiness.json', 'stable-readiness.json', 'archive-manifest.json', 'SHA256SUMS'}
inventory = {str(path.relative_to(base)): sha(path) for path in sorted(base.rglob('*'))
             if path.is_file() and not (path.parent == base and path.name in excluded)}
report = {'schemaVersion': 1, 'status': 'passed',
          'recordedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'scope': 'All assigned Milestone 5 library gates; physical devices and DICOMKit remain excluded. No stable publication authority.',
          'baselineRevision': checklist['baselineRevision'], 'predecessorRevision': checklist['predecessorRevision'],
          'runtimeRevision': frozen, 'testRevision': '24cbd10cd7b08062d68dfdf7abc462b4a77a3fb5',
          'checkoutBaseRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'contractVersion': checklist['contractVersion'],
          'sourceGroupDigests': {name: group['sha256'] for name, group in checklist['sourceGroups'].items()},
          'checksPerformed': len(checks), 'gates': gate_results, 'artifactSHA256': inventory,
          'sourceReconciliation': 'Runtime unchanged from00f03ff. Current simulator inventory is rehashed. Independent Linux/native receipts prove the six Watch-only conditional blocks project to exact qualified non-Watch bytes. Reporter fixes and the corrected Watch oracle are bound to their actual runs; older receipts are not relabelled.',
          'assignedTaskComplete': True, 'stableReleaseReady': False, 'publicationAuthorised': False,
          'limitations': ['Physical-device qualification remains required for stable readiness.', 'DICOMKit/downstream integration remains deferred.', 'No stable tag/release or production cutover.', 'Allocation/peak workspace unknown where nil; process RSS is not exact allocation accounting.', 'Derived SBOMs cover the package graph; original generator defects remain preserved.'],
          'assemblerSHA256': sha(Path(__file__))}
target = base / 'final-review.json'
target.write_text(json.dumps(report, indent=2) + '\n')
for gate in checklist['gates']:
    if gate['id'] not in facts:
        require(gate['id'] == 'M4-PHYSICAL-DEVICES' and gate['status'] == 'unavailable' and gate['required'] is True,
                'Only owner-excluded physical-device gate remains open')
        continue
    gate.update(status='passed', reason='Passed source-bound execution and independent review; exact receipts and reconciliation are retained in the final review.',
                evidence=[{'path': str(target.relative_to(repo)), 'sha256': sha(target),
                           'resultPointer': '/gates/' + gate['id'] + '/status',
                           'sourceBindings': {name: '/sourceGroupDigests/' + name for name in gate['sourceGroups']}}])
checklist_path.write_text(json.dumps(checklist, indent=2) + '\n')
print(json.dumps({'review': str(target.relative_to(repo)), 'checks': len(checks), 'passingAssignedGates': len(facts), 'archiveFiles': len(inventory)}))
