"""Independent source-equivalence check; does not replace raw execution receipts."""
from pathlib import Path
import datetime
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parent
baseline = '2345c7b9fb1c329463cf4f3ba5bc3194fea51193'
current = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
sha = lambda b: hashlib.sha256(b).hexdigest()
blob = lambda rev, p: subprocess.check_output(['git', 'show', rev + ':' + p])
changed = subprocess.check_output(['git', 'diff', '--name-only', baseline, 'HEAD'], text=True).splitlines()
expected = {'Tests/SwiftJXLCoreTests/ModularDecodeParallelTests.swift': 1,
            'Tests/SwiftJXLCoreTests/ModularStorageTests.swift': 5}
assert set(changed) == set(expected) | {'Scripts/TestSupport/qualify-watch-profile.py'}
assert not subprocess.check_output(['git', 'diff', '--name-only', 'HEAD', '--', 'Sources', 'Tests', 'Package.swift', 'VERSION',
                                   'Scripts/qualify-linux-sanitizer.py', '.github/workflows/milestone5-linux-sanitizers.yml'], text=True).strip()
files = {}
for name, count in expected.items():
    before, after = blob(baseline, name), blob(current, name)
    output = []
    inside = keeping = False
    blocks = 0
    for line in after.splitlines(keepends=True):
        stripped = line.strip()
        if not inside:
            if stripped == b'#if os(watchOS)':
                inside, keeping = True, False
                blocks += 1
            else:
                output.append(line)
        elif stripped == b'#else':
            assert not keeping
            keeping = True
        elif stripped == b'#endif':
            inside = keeping = False
        else:
            assert not stripped.startswith((b'#if ', b'#elseif '))
            if keeping:
                output.append(line)
    assert not inside and blocks == count and b''.join(output) == before
    files[name] = {'baselineSHA256': sha(before), 'currentSHA256': sha(after),
                   'nonWatchProjectionSHA256': sha(b''.join(output)), 'inactiveWatchBlocks': blocks, 'nonWatchBytesUnchanged': True}
paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', current, '--', 'Sources', 'Package.swift', 'VERSION'], text=True).splitlines()
runtime = {}
for p in paths:
    actual = Path(p).read_bytes()
    assert actual == blob(current, p) == blob(baseline, p) == blob('00f03ff288a7c8e0e2b82d2e71ec22622ede71ae', p)
    runtime[p] = sha(actual)
assert len(runtime) == 122
qualification = {}
for p in ['Scripts/qualify-linux-sanitizer.py', 'Scripts/TestSupport/test-linux-sanitizer-gate.py',
          '.github/workflows/milestone5-linux-sanitizers.yml', 'Scripts/TestSupport/modular-profile-oracle.c',
          'Scripts/TestSupport/modular-info-oracle.cmake', 'Scripts/Qualification/VarDCTARM/reciprocal-vectors.c']:
    actual = Path(p).read_bytes()
    assert actual == blob(baseline, p)
    qualification[p] = sha(actual)
prior = Path('.build/watch-test-adjustment/native-projection-independent-audit.json')
prior_report = json.loads(prior.read_text())
assert prior_report['status'] == 'passed'
for p, r in files.items():
    assert r['currentSHA256'] == prior_report['files'][p]['afterSHA256'] and r['baselineSHA256'] == prior_report['files'][p]['beforeSHA256']
d = {'status': 'passed', 'auditedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
     'qualifiedRunID': 41818641469, 'qualifiedHeadRevision': baseline,
     'qualifiedMergeRevision': 'e8460d788fa0cc8a90e2ff958808fe2efdd60ce9', 'reviewedCurrentRevision': current,
     'scope': 'Linux qualification retains the original run and exact source hashes. Current native Linux active code is unchanged: all runtime/manifest/VERSION bytes are identical, and the only two test changes are inactive #if os(watchOS) branches whose exact non-Watch projection matches the executed sources. No new Linux execution at the current revision is claimed. Watch branch execution is separately qualified.',
     'runtimeManifestAndVersionFiles': runtime, 'runtimeManifestAndVersionCount': len(runtime),
     'nonWatchTestProjection': files, 'unchangedLinuxQualificationFiles': qualification,
     'otherCommittedChange': {'path': 'Scripts/TestSupport/qualify-watch-profile.py',
                             'scope': 'Watch-only qualification driver, not invoked by the Linux workflow or driver',
                             'currentSHA256': sha(Path('Scripts/TestSupport/qualify-watch-profile.py').read_bytes())},
     'independentlyReviewedPriorProjection': {'path': str(prior), 'sha256': sha(prior.read_bytes()), 'agreement': True},
     'auditorSHA256': sha(Path(__file__).read_bytes())}
(root / 'current-source-binding.json').write_text(json.dumps(d, indent=2) + '\n')
(root / 'watch-test-source-delta.diff').write_bytes(subprocess.check_output(['git', 'diff', baseline, current, '--', *expected]))
(root / 'watch-native-projection-prior-audit.json').write_bytes(prior.read_bytes())
print(json.dumps({'status': d['status'], 'runtimeManifestAndVersionCount': len(runtime), 'currentRevision': current, 'inactiveWatchBlocks': sum(r['inactiveWatchBlocks'] for r in files.values())}))
