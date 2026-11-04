#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed mutation checks for the release evidence validator; no Swift build."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_gates", ROOT / "Scripts/check-release-gates.py")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ReleaseGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="swiftjxl-release-gates-")
        cls.repo = Path(cls.temporary.name)
        cls.baseline = json.loads((ROOT / "Documentation/Engineering/Release/release-gates.json").read_text())
        files = {"VERSION", "Documentation/COMMON_CONTRACT_SHA256.txt"}
        files.update("Documentation/" + name for name in VALIDATOR.CONTRACT_FILES)
        for group in cls.baseline["sourceGroups"].values():
            files.update(group["files"])
        for gate in cls.baseline["gates"]:
            files.update(item["path"] for item in gate["evidence"])
        for relative in files:
            path = cls.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, path)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.checklist = copy.deepcopy(self.baseline)
        # This suite tests the gate mechanism, independently of later closeout
        # reports added to the real checklist.
        for gate in self.checklist["gates"]:
            gate["status"] = "pending"
            gate["evidence"] = [{"path": "Documentation/TESTING.md"}]

    def passing_evidence(self, gate):
        report = {"status": "passed", "checksPassed": True,
                  "sourceGroupDigests": {name: self.checklist["sourceGroups"][name]["sha256"]
                                         for name in gate["sourceGroups"]}}
        # Different gates may bind different source groups. Each fixture needs
        # its own file; rewriting one shared file invalidates earlier hashes.
        path = self.repo / ("synthetic-" + gate["id"] + ".json")
        path.write_text(json.dumps(report))
        gate["status"] = "passed"
        gate["evidence"] = [{"path": path.name, "sha256": VALIDATOR.sha256(path),
                             "resultPointer": "/status",
                             "sourceBindings": {name: "/sourceGroupDigests/" + name
                                                for name in gate["sourceGroups"]},
                             "jsonChecks": [{"pointer": "/checksPassed", "equals": True}]}]

    def test_valid_blocked_is_not_ready(self):
        result = VALIDATOR.audit(self.repo, self.checklist)
        self.assertTrue(result["checklistValid"])
        self.assertFalse(result["preparationComplete"])
        self.assertFalse(result["stableReleaseReady"])

    def test_preparation_complete_keeps_stable_blocked(self):
        for gate in self.checklist["gates"]:
            if gate["phase"] == "preparation":
                self.passing_evidence(gate)
        result = VALIDATOR.audit(self.repo, self.checklist)
        self.assertTrue(result["preparationComplete"])
        self.assertFalse(result["stableReleaseReady"])

    def test_all_verified_gates_ready_without_publication_authority(self):
        for gate in self.checklist["gates"]:
            self.passing_evidence(gate)
        result = VALIDATOR.audit(self.repo, self.checklist)
        self.assertTrue(result["stableReleaseReady"])
        self.assertFalse(result["publicationAuthorised"])

    def test_required_gate_cannot_disappear(self):
        self.checklist["gates"].pop()
        with self.assertRaisesRegex(ValueError, "Missing required gates"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_required_gate_cannot_be_waived(self):
        self.checklist["gates"][0]["required"] = False
        with self.assertRaisesRegex(ValueError, "cannot be waived"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_physical_task_exclusion_does_not_authorise_release(self):
        self.checklist['taskScope'] = {
            'excludedGates': ['M4-PHYSICAL-DEVICES'], 'recordedDate': '2026-11-04',
            'ownerInstruction': 'complete all the milestone 5 except the physical device testing.'}
        for gate in self.checklist['gates']:
            if gate['id'] != 'M4-PHYSICAL-DEVICES':
                self.passing_evidence(gate)
        result = VALIDATOR.audit(self.repo, self.checklist)
        self.assertTrue(result['assignedTaskComplete'])
        self.assertFalse(result['stableReleaseReady'])
        self.assertFalse(result['publicationAuthorised'])
        self.assertEqual(result['blockedGates'], ['M4-PHYSICAL-DEVICES'])

    def test_other_platform_gate_cannot_be_excluded(self):
        self.checklist['taskScope'] = {'excludedGates': ['M4-MACOS-MINIMUM']}
        with self.assertRaisesRegex(ValueError, 'Only physical-device'):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_task_exclusion_requires_recorded_instruction(self):
        self.checklist['taskScope'] = {'excludedGates': ['M4-PHYSICAL-DEVICES']}
        with self.assertRaisesRegex(ValueError, 'recorded owner instruction'):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_unknown_status_is_invalid(self):
        self.checklist["gates"][0]["status"] = "accepted-risk"
        with self.assertRaisesRegex(ValueError, "Unknown gate status"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_historical_prose_cannot_pass_gate(self):
        self.checklist["gates"][0]["status"] = "passed"
        with self.assertRaisesRegex(ValueError, "lacks a passing source-bound report"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_missing_evidence_fails(self):
        self.checklist["gates"][0]["evidence"] = [{"path": "missing.json"}]
        with self.assertRaisesRegex(ValueError, "Missing evidence"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_wrong_report_property_fails(self):
        gate = self.checklist["gates"][0]
        self.passing_evidence(gate)
        gate["evidence"][0]["jsonChecks"][0]["equals"] = False
        with self.assertRaisesRegex(ValueError, "Evidence property mismatch"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_stale_report_source_binding_fails(self):
        gate = self.checklist["gates"][0]
        self.passing_evidence(gate)
        item = gate["evidence"][0]
        path = self.repo / item["path"]
        report = json.loads(path.read_text())
        report["sourceGroupDigests"]["runtime"] = "0" * 64
        path.write_text(json.dumps(report))
        item["sha256"] = VALIDATOR.sha256(path)
        with self.assertRaisesRegex(ValueError, "Evidence source binding mismatch"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_added_source_cannot_escape_inventory(self):
        path = self.repo / "Sources/Unrecorded.swift"
        path.write_text("// new implementation\n")
        try:
            with self.assertRaisesRegex(ValueError, "Source inventory changed"):
                VALIDATOR.audit(self.repo, self.checklist)
        finally:
            path.unlink()

    def test_runtime_inventory_scope_cannot_shrink(self):
        self.checklist["sourceGroups"]["runtime"]["includes"] = ["VERSION"]
        with self.assertRaisesRegex(ValueError, "Runtime inventory scope changed"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_path_escape_is_invalid(self):
        self.checklist["gates"][0]["evidence"] = [{"path": "../report.json"}]
        with self.assertRaisesRegex(ValueError, "inside the repository"):
            VALIDATOR.audit(self.repo, self.checklist)

    def test_cli_exit_codes_distinguish_blocked_from_invalid(self):
        path = self.repo / "checklist.json"
        path.write_text(json.dumps(self.checklist))
        command = [sys.executable, str(ROOT / "Scripts/check-release-gates.py"),
                   "--repo", str(self.repo), "--checklist", str(path)]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(command + ["--require-ready"], capture_output=True).returncode, 2)
        self.checklist["gates"].clear()
        path.write_text(json.dumps(self.checklist))
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)


if __name__ == "__main__":
    unittest.main()
