from pathlib import Path
from datetime import datetime, timezone
import json, hashlib, shutil, subprocess
w = Path(__file__).resolve().parent
repo = Path('/Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/SwiftJXL-vardct-public')
evidence = repo / 'Documentation/Engineering/Migration/Evidence/CIRepair/HierarchyDeadline'
base = '68af0caae2509b72c91d81ae0cf0553c2817bef8'
labels = ['swift62-compatible-debug', 'swift62-compatible-tsan']
runs = []
for label in labels:
    row = json.loads((w / (label + '.json')).read_text())
    assert row['exit'] == 0 and row['xml'] == {'cases': 6, 'failures': 0, 'errors': 0, 'skips': 0}
    assert all(hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest for name, digest in row['sourceHashes'].items())
    log = (w / (label + '.log')).read_text()
    assert 'WARNING: ThreadSanitizer' not in log and 'ERROR: AddressSanitizer' not in log
    row.update(testDeclarations=6, argumentCases=19)
    runs.append(row)
assert subprocess.check_output(['git', 'diff', base, '--', 'Sources', '.github/workflows'], cwd=repo) == b''
contracts = {}
for line in (repo / 'Documentation/COMMON_CONTRACT_SHA256.txt').read_text().splitlines():
    if not line.strip(): continue
    expected, name = line.split(maxsplit=1); name = name.lstrip('*')
    actual = hashlib.sha256((repo / 'Documentation' / name).read_bytes()).hexdigest()
    assert actual == expected
    contracts[name] = actual
assert len(contracts) == 7
report = {
    'asOfUTC': datetime.now(timezone.utc).isoformat(), 'base': base,
    'previousRepairHead': '4097588b64b202b6a23f963d3644304d38044e3a',
    'pullRequest': 'https://github.com/raster-labs/SwiftJXL/pull/24',
    'diagnosis': 'Hosted Swift 6.2 Linux compilation could not type-check the nested laterPatch map expression in reasonable time. Complete job log retained in hosted-swift62-compile.json.',
    'change': 'Replace two nested map expressions with explicit typed arrays and row/column-index loops, preserving the same 8x8 first/later patch samples. Bring authorised PR23 main into the repair branch, preserving both history entries.',
    'validation': 'Focused debug and TSan each 6 declarations / 19 cases, no failures or skips. Local compiler is Swift 6.4; labels describe the intended compatibility correction, not a locally executed Swift 6.2 compiler.',
    'commonContractHashes': contracts, 'runs': runs,
    'limits': 'Original four-configuration validation remains retained for 4097588. Only focused debug and TSan were rerun after this test-only expression correction. All current-head hosted checks remain required before any separately authorised merge. No runtime or workflow changes relative to current main.'
}
(w / 'swift62-followup.json').write_text(json.dumps(report, indent=2) + '\n')
files = ['hosted-swift62-compile.json', 'swift62-followup.json', 'finalise-swift62.py']
for label in labels: files.extend(label + '.' + suffix for suffix in ['json', 'log', 'xml'])
for name in files: shutil.copy2(w / name, evidence / name)
manifest = evidence / 'SHA256SUMS'
old_names = [line.split(maxsplit=1)[1] for line in manifest.read_text().splitlines() if line.strip()]
names = sorted(set(old_names + files))
manifest.write_text(''.join(hashlib.sha256((evidence / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in names))
out = w.parent.parent / 'outputs/thread-sanitizer-repair.json'
summary = json.loads(out.read_text()); summary['swift62Followup'] = report
out.write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({'configurations': labels, 'sourceTestHashes': len(runs[0]['sourceHashes']), 'contracts': len(contracts), 'evidenceFiles': len(names)}))
