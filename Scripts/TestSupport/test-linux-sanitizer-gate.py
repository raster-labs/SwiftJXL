#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Acceptance parser must reject missing tests, skips and sanitizer findings."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("linux_sanitizer_gate", Path(__file__).resolve().parents[1] / "qualify-linux-sanitizer.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class LinuxSanitizerGateTests(unittest.TestCase):
    def test_intentional_swift_race_requires_an_actual_finding_and_configured_exit(self):
        expected = ["WARNING: ThreadSanitizer: data race", "WARNING: ThreadSanitizer: Swift access race"]
        for diagnostic in expected:
            self.assertTrue(gate.negative_probe_detected(66, diagnostic + " (pid=123)", expected))
            self.assertFalse(gate.negative_probe_detected(0, diagnostic, expected))
        for text in ["", "Simultaneous accesses", "FATAL: ThreadSanitizer: unexpected memory mapping"]:
            self.assertFalse(gate.negative_probe_detected(66, text, expected))
        self.assertFalse(gate.negative_probe_detected(-11, expected[0], expected))

    def check(self, *, skip=False, failure=False, diagnostic="", omit=False, empty=False):
        names = ["SwiftJXLTests.Lifetime/" + name + "()" for name in gate.REQUIRED_TESTS]
        root = ET.Element("testsuites")
        suite = ET.SubElement(root, "testsuite")
        selected = [] if empty else names[:-1] if omit else names
        for index, name in enumerate(selected):
            cls, method = name.split("/")
            case = ET.SubElement(suite, "testcase", classname=cls, name=method)
            if index == 0 and skip:
                ET.SubElement(case, "skipped")
            if index == 0 and failure:
                ET.SubElement(case, "failure")
        log = "\n".join("Test " + name + " passed after 0.001 seconds." for name in selected) + diagnostic
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / "tests.xml"
            ET.ElementTree(root).write(xml)
            return gate.test_evidence(xml, names, log)

    def test_complete_suite_reports_measured_counts(self):
        result = self.check()
        self.assertEqual(result["executedDeclarations"], len(gate.REQUIRED_TESTS))
        self.assertEqual(result["passedArgumentCasesFromLog"], len(gate.REQUIRED_TESTS))

    def test_skips_and_failures_reject(self):
        for option in [{"skip": True}, {"failure": True}]:
            with self.subTest(option=option), self.assertRaises(RuntimeError):
                self.check(**option)

    def test_empty_or_incomplete_execution_rejects(self):
        for option in [{"empty": True}, {"omit": True}]:
            with self.subTest(option=option), self.assertRaises(RuntimeError):
                self.check(**option)

    def test_sanitizer_findings_cannot_hide_behind_passing_xml(self):
        for diagnostic in ["ERROR: AddressSanitizer: heap-buffer-overflow", "WARNING: ThreadSanitizer: data race",
                           "WARNING: ThreadSanitizer: Swift access race",
                           "ERROR: LeakSanitizer: detected memory leaks", "FATAL: ThreadSanitizer: unexpected memory mapping"]:
            with self.subTest(diagnostic=diagnostic), self.assertRaises(RuntimeError):
                self.check(diagnostic=diagnostic)


if __name__ == "__main__":
    unittest.main()
