#!/usr/bin/env python3
"""Derive exact Swift Testing/xUnit identity reconciliation without editing raw evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runtime_directory", type=Path)
parser.add_argument("output_prefix", type=Path)
parser.add_argument("--expected-declarations", type=int, default=368)
args = parser.parse_args()
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
raw_log = args.runtime_directory / "discovery.log"
raw_inventory = args.runtime_directory / "discovered-tests.json"
xml = args.runtime_directory / "tests.xml"
warning = "warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.\n"
raw = raw_log.read_text()
count = raw.count(warning)
if count > 1:
    raise RuntimeError("Multiple native-build warnings need explicit review")
derived = raw.replace(warning, "", count)
identities, normalisations = [], []
for line in derived.splitlines():
    if not line.startswith(("SwiftJXLTests.", "SwiftJXLCoreTests.")):
        continue
    name = line.strip()
    canonical = name if "/" in name else name.replace(".", "/", 1)
    if canonical != name:
        normalisations.append({"from": name, "to": canonical})
    identities.append(canonical)
nodes = ET.parse(xml).findall(".//testcase")
executed = [row.attrib["classname"] + "/" + row.attrib["name"] for row in nodes]
passed = (len(identities) == len(set(identities)) == len(executed) == len(set(executed)) == args.expected_declarations
          and set(identities) == set(executed))
log_path = Path(str(args.output_prefix) + "-derived.txt")
inventory_path = Path(str(args.output_prefix) + "-identities.json")
receipt_path = Path(str(args.output_prefix) + "-derivation.json")
if any(path.exists() for path in (log_path, inventory_path, receipt_path)):
    raise RuntimeError("Derived output already exists; raw and prior evidence are preserved")
log_path.write_text(derived)
inventory_path.write_text(json.dumps(identities, indent=2) + "\n")
receipt = {"status": "passed" if passed else "failed", "scope": "Derived discovery identities only; raw receipts unchanged",
           "driverSHA256": sha(Path(__file__)), "rawLogSHA256": sha(raw_log), "rawInventorySHA256": sha(raw_inventory),
           "xmlSHA256": sha(xml), "removedDiagnostic": warning, "diagnosticOccurrences": count,
           "separatorNormalisations": normalisations, "derivedLogSHA256": sha(log_path), "derivedInventorySHA256": sha(inventory_path),
           "declarations": len(identities), "executionDeclarations": len(executed), "exactIdentitySetAgreement": passed,
           "missing": sorted(set(executed) - set(identities)), "unexpected": sorted(set(identities) - set(executed))}
receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({"status": receipt["status"], "declarations": len(identities), "removedWarnings": count}))
raise SystemExit(0 if passed else 1)
