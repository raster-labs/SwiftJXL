#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify the release fixture inventory and retained source/fixture notices.

This is a distribution inventory, not a generated-build SBOM or a legal opinion.
No fixture, licence, source or historical evidence is modified by this command.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

INVENTORY = "Documentation/Engineering/Release/fixture-inventory.json"
SOURCE_LICENCES = {"Apache-2.0", "Apache-2.0 AND BSD-3-Clause", "Apache-2.0 AND MIT", "MIT"}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")


class AuditFailure(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditFailure(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repository_path(root: Path, relative: str) -> Path:
    require(isinstance(relative, str) and bool(relative), "Empty inventory path")
    parts = PurePosixPath(relative).parts
    require(not relative.startswith("/") and ".." not in parts and "\\" not in relative,
            f"Unsafe inventory path: {relative}")
    path = root / relative
    require(not path.is_symlink(), f"Symlink is not an audited regular file: {relative}")
    require(path.resolve().is_relative_to(root.resolve()), f"Path escapes repository: {relative}")
    require(path.is_file(), f"Missing inventory evidence or payload: {relative}")
    return path


def read_json(path: Path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key {key} in {path.name}")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique_keys)


def at_pointer(document, pointer: str):
    require(pointer.startswith("/"), f"Invalid JSON pointer: {pointer}")
    value = document
    for part in pointer.split("/")[1:]:
        key = part.replace("~1", "/").replace("~0", "~")
        value = value[int(key)] if isinstance(value, list) else value[key]
    return value


def audit(root: Path, inventory_path: Path) -> dict:
    inventory = read_json(inventory_path)
    require(inventory.get("schemaVersion") == 1, "Unknown inventory schema")
    baseline = inventory.get("baselineRevision", "")
    require(bool(REVISION.fullmatch(baseline)), "Unpinned baseline revision")
    fixture_root = inventory.get("fixtureRoot")
    require(fixture_root == "Tests/SwiftJXLCoreTests/Fixtures", "Unexpected fixture scope")
    groups, files = inventory.get("noticeGroups"), inventory.get("files")
    require(isinstance(groups, dict) and bool(groups), "Missing notice groups")
    require(isinstance(files, dict) and bool(files), "Missing fixture inventory")
    for group, record in groups.items():
        require(isinstance(record.get("licence"), str) and bool(record["licence"]),
                f"Missing licence declaration: {group}")
        require(bool(record.get("scope")) and bool(record.get("evidence")),
                f"Missing provenance context: {group}")
        for path in record["evidence"]:
            repository_path(root, path)
    required_notices = {"LICENSE", "Documentation/ThirdParty/libjxl-LICENSE.txt",
                        "Documentation/ThirdParty/brotli-LICENSE.txt",
                        fixture_root + "/VarDCT/Conformance/LICENSE.txt",
                        fixture_root + "/VarDCT/Conformance/SOURCE-LICENCES.md"}
    notices = inventory.get("preservedNotices", {})
    require(set(notices) == required_notices, "Required licence notice set differs")
    for path, expected in notices.items():
        require(digest(repository_path(root, path)) == expected, f"Preserved notice changed: {path}")
    # The Git index defines the distributed resource set. Nonignored additions
    # are included so an accidentally unindexed fixture cannot pass locally.
    listing = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", fixture_root],
        cwd=root).decode().split("\0")
    actual = {p[len(fixture_root) + 1:] for p in listing if p}
    require(actual == set(files), "Fixture inventory differs: " +
            json.dumps({"unlisted": sorted(actual - set(files)), "missing": sorted(set(files) - actual)}))
    evidence_cache = {}
    fixtures = []
    evidence_counts = {"retainedManifestOrValidation": 0, "baselineSnapshot": 0}
    for name, record in sorted(files.items()):
        relative = fixture_root + "/" + name
        path = repository_path(root, relative)
        expected = record.get("sha256", "")
        require(bool(SHA256.fullmatch(expected)), f"Invalid expected hash: {relative}")
        require(digest(path) == expected, f"Fixture hash mismatch: {relative}")
        group = record.get("noticeGroup")
        require(group in groups, f"Unknown fixture notice group: {relative}")
        evidence = record.get("hashEvidence", "")
        if evidence.startswith("git:"):
            require(evidence == "git:" + baseline + ":" + relative,
                    f"Invalid baseline source binding: {relative}")
            # Verify the immutable source object, not merely the spelling of
            # its provenance reference. A shallow checkout must fetch this
            # pinned baseline before auditing; missing history is not a pass.
            baseline_bytes = subprocess.check_output(
                ["git", "show", baseline + ":" + relative], cwd=root, stderr=subprocess.PIPE)
            require(hashlib.sha256(baseline_bytes).hexdigest() == expected,
                    f"Pinned baseline hash disagrees: {relative}")
            evidence_counts["baselineSnapshot"] += 1
        else:
            require("#" in evidence, f"Missing retained hash evidence: {relative}")
            evidence_path, pointer = evidence.split("#", 1)
            if evidence_path not in evidence_cache:
                evidence_cache[evidence_path] = read_json(repository_path(root, evidence_path))
            require(at_pointer(evidence_cache[evidence_path], pointer) == expected,
                    f"Retained evidence hash disagrees: {relative}")
            evidence_counts["retainedManifestOrValidation"] += 1
        fixtures.append({"path": relative, "sha256": expected, "bytes": path.stat().st_size,
                         "noticeGroup": group, "licence": groups[group]["licence"],
                         "hashEvidence": evidence})
    source_listing = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "Sources"],
        cwd=root).decode().split("\0")
    sources = []
    for relative in sorted(set(source_listing) - {""}):
        path = repository_path(root, relative)
        require(path.suffix == ".swift", f"New source kind needs notice review: {relative}")
        headers = re.findall(r"^// SPDX-License-Identifier: (.+)$", path.read_text(), re.MULTILINE)
        require(len(headers) == 1 and headers[0] in SOURCE_LICENCES,
                f"Missing or unreviewed source licence: {relative}")
        sources.append({"path": relative, "sha256": digest(path), "licence": headers[0]})
    require(bool(sources), "Source inventory is empty")
    return {"schemaVersion": 1, "status": "passed", "baselineRevision": baseline,
            "sourceRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
            "inventorySHA256": digest(inventory_path), "fixtureCount": len(fixtures),
            "sourceCount": len(sources), "fixtureHashEvidence": evidence_counts,
            "preservedNotices": notices, "noticeGroups": groups,
            "scope": inventory["scope"],
            "limitations": ["SPDX declarations and retained provenance are inventoried; this is not an independent legal determination.",
                            "Baseline-only fixture hashes attest committed bytes, not independent sample correctness.",
                            "Historical engineering evidence archives, toolchains and system SDKs are outside the test-resource inventory.",
                            "This source/fixture inventory is not a build-associated or schema-validated CycloneDX/SPDX SBOM."],
            "sources": sources, "fixtures": fixtures}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--inventory", type=Path, help="Alternate inventory for controlled audit tests")
    parser.add_argument("--output", type=Path, required=True, help="New JSON report path (refuses overwrite)")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("--output already exists; preserve earlier evidence and select a new path")
    try:
        report = audit(args.root.resolve(), args.inventory or args.root / INVENTORY)
        code = 0
    except (AuditFailure, OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError) as error:
        report = {"schemaVersion": 1, "status": "failed", "error": str(error)}
        code = 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps({k: report[k] for k in ("status", "sourceCount", "fixtureCount", "fixtureHashEvidence", "error") if k in report}))
    return code


if __name__ == "__main__":
    sys.exit(main())
