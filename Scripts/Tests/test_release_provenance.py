#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Negative controls for the release fixture/notice audit; no codec execution."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_provenance", ROOT / "Scripts/audit-release-provenance.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class ReleaseProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="swiftjxl-provenance-tests-")
        cls.root = Path(cls.temporary.name)
        cls.inventory = json.loads((ROOT / AUDIT.INVENTORY).read_text())
        cls.inventory_path = cls.root / AUDIT.INVENTORY
        paths = set(cls.inventory["preservedNotices"])
        for group in cls.inventory["noticeGroups"].values():
            paths.update(group["evidence"])
        for name, row in cls.inventory["files"].items():
            paths.add(cls.inventory["fixtureRoot"] + "/" + name)
            if not row["hashEvidence"].startswith("git:"):
                paths.add(row["hashEvidence"].split("#", 1)[0])
        paths.add(AUDIT.INVENTORY)
        paths.update(str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift"))
        for relative in paths:
            destination = cls.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        for command in (["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Fixture audit", "-c", "user.email=fixture-audit@example.invalid",
                         "commit", "-qm", "Fixture audit test snapshot"]):
            subprocess.run(command, cwd=cls.root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Share immutable objects only, so baseline Git bindings are exercised
        # without copying history or changing the working repository.
        objects = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-path", "objects"],
            cwd=ROOT, text=True).strip()
        cls.alternates = cls.root / ".git/objects/info/alternates"
        cls.alternates.write_text(objects + "\n")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def tearDown(self):
        self.inventory_path.write_text(json.dumps(self.inventory))

    def test_unmodified_inventory_passes(self):
        result = AUDIT.audit(self.root, self.inventory_path)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["fixtureCount"], len(self.inventory["files"]))

    def test_modified_fixture_rejected(self):
        name = next(iter(self.inventory["files"]))
        path = self.root / self.inventory["fixtureRoot"] / name
        saved = path.read_bytes()
        try:
            path.write_bytes(saved + b"mutation")
            with self.assertRaisesRegex(AUDIT.AuditFailure, "Fixture hash mismatch"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.write_bytes(saved)

    def test_unlisted_fixture_rejected(self):
        path = self.root / self.inventory["fixtureRoot"] / "unlisted.bin"
        try:
            path.write_bytes(b"unreviewed distribution input")
            with self.assertRaisesRegex(AUDIT.AuditFailure, "unlisted"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.unlink()

    def test_missing_fixture_rejected(self):
        path = self.root / self.inventory["fixtureRoot"] / next(iter(self.inventory["files"]))
        saved = path.read_bytes()
        try:
            path.unlink()
            with self.assertRaisesRegex(AUDIT.AuditFailure, "Missing"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.write_bytes(saved)

    def test_upstream_notice_change_rejected(self):
        path = self.root / "Documentation/ThirdParty/brotli-LICENSE.txt"
        saved = path.read_bytes()
        try:
            path.write_bytes(b"Apache-2.0")
            with self.assertRaisesRegex(AUDIT.AuditFailure, "Preserved notice changed"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.write_bytes(saved)

    def test_removed_notice_requirement_rejected(self):
        changed = copy.deepcopy(self.inventory)
        del changed["preservedNotices"]["Documentation/ThirdParty/brotli-LICENSE.txt"]
        self.inventory_path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(AUDIT.AuditFailure, "notice set differs"):
            AUDIT.audit(self.root, self.inventory_path)

    def test_source_without_licence_rejected(self):
        path = self.root / "Sources/SwiftJXL/Errors.swift"
        saved = path.read_bytes()
        try:
            path.write_bytes(saved.replace(b"SPDX-License-Identifier", b"Missing-License-Identifier"))
            with self.assertRaisesRegex(AUDIT.AuditFailure, "source licence"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.write_bytes(saved)

    def test_unknown_notice_group_rejected(self):
        changed = copy.deepcopy(self.inventory)
        changed["files"][next(iter(changed["files"]))]["noticeGroup"] = "unreviewed"
        self.inventory_path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(AUDIT.AuditFailure, "Unknown fixture notice group"):
            AUDIT.audit(self.root, self.inventory_path)

    def test_false_retained_evidence_rejected(self):
        changed = copy.deepcopy(self.inventory)
        row = next(v for v in changed["files"].values() if not v["hashEvidence"].startswith("git:"))
        row["hashEvidence"] = "Tests/SwiftJXLCoreTests/Fixtures/JPEG/manifest.json#/licence"
        self.inventory_path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(AUDIT.AuditFailure, "evidence hash disagrees"):
            AUDIT.audit(self.root, self.inventory_path)

    def test_changed_baseline_payload_and_inventory_rejected(self):
        changed = copy.deepcopy(self.inventory)
        name, row = next((k, v) for k, v in changed["files"].items()
                         if v["hashEvidence"].startswith("git:"))
        path = self.root / changed["fixtureRoot"] / name
        saved = path.read_bytes()
        try:
            path.write_bytes(saved + b"\n ")
            row["sha256"] = AUDIT.digest(path)
            self.inventory_path.write_text(json.dumps(changed))
            with self.assertRaisesRegex(AUDIT.AuditFailure, "Pinned baseline hash disagrees"):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            path.write_bytes(saved)

    def test_unavailable_baseline_rejected(self):
        saved = self.alternates.read_text()
        try:
            self.alternates.write_text("")
            with self.assertRaises(subprocess.CalledProcessError):
                AUDIT.audit(self.root, self.inventory_path)
        finally:
            self.alternates.write_text(saved)

    def test_path_traversal_rejected(self):
        with self.assertRaisesRegex(AUDIT.AuditFailure, "Unsafe inventory path"):
            AUDIT.repository_path(self.root, "../outside")


if __name__ == "__main__":
    unittest.main(verbosity=2)
