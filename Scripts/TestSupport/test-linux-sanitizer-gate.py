#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Acceptance parser must reject missing tests, skips and sanitizer findings."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("linux_sanitizer_gate", Path(__file__).resolve().parents[1] / "qualify-linux-sanitizer.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class LinuxSanitizerGateTests(unittest.TestCase):
    def test_streams_are_separate_and_stderr_findings_reject_clean_stdout(self):
        stdout = b"SwiftJXLTests.Suite/completeName()\n"
        stderr = b"warning: unrelated \xe2\nWARNING: ThreadSanitizer: data race\n"
        entry = {"label": "test-discovery", "log": "test-discovery.log", "exitCode": 66}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            combined = gate.preserve_streams(root, entry, stdout, stderr)
            for name, raw in [("stdout", stdout), ("stderr", stderr)]:
                row = entry["streams"][name]
                self.assertEqual((root / row["log"]).read_bytes(), raw)
                self.assertEqual(row["logSHA256"], hashlib.sha256(raw).hexdigest())
            self.assertTrue(entry["streams"]["stdout"]["validUTF8"])
            self.assertFalse(entry["streams"]["stderr"]["validUTF8"])
        self.assertEqual(entry["exitCode"], 66)
        with self.assertRaises(RuntimeError):
            self.check(diagnostic=combined)

    def test_free_function_and_suite_method_identities(self):
        self.assertEqual(gate.xml_identity(ET.Element("testcase", classname="SwiftJXLTests", name="free()")),
                         "SwiftJXLTests.free()")
        self.assertEqual(gate.xml_identity(ET.Element("testcase", classname="SwiftJXLTests.Suite", name="method(_:)")),
                         "SwiftJXLTests.Suite/method(_:)")

    def test_invalid_utf8_retains_raw_bytes_and_cannot_hide_a_sanitizer_finding(self):
        raw = b"test progress \xe2\nWARNING: ThreadSanitizer: data race\n\x9c\x94done\n"
        entry = {"log": "full-tests.log", "exitCode": 66}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            decoded = gate.preserve_output(root, entry, raw)
            self.assertEqual((root / entry["log"]).read_bytes(), raw)
        self.assertEqual(entry["exitCode"], 66)
        self.assertEqual(entry["logSHA256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(entry["logBytes"], len(raw))
        self.assertFalse(entry["validUTF8"])
        self.assertIn("decodeError", entry)
        with self.assertRaises(RuntimeError):
            self.check(diagnostic=decoded)

    def test_valid_utf8_is_preserved_without_replacement(self):
        raw = "Test run passed \u2714\n".encode("utf-8")
        entry = {"log": "full-tests.log", "exitCode": 0}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(gate.preserve_output(root, entry, raw), raw.decode("utf-8"))
            self.assertEqual((root / entry["log"]).read_bytes(), raw)
        self.assertTrue(entry["validUTF8"])
        self.assertNotIn("decodeError", entry)

    def test_profile_oracle_requires_complete_unique_semantic_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(RuntimeError):
                gate.profile_evidence(root)
            records = []
            for bits in range(8, 17):
                for channels, associated in [(1, 0), (2, 0), (2, 1), (3, 0), (4, 0), (4, 1)]:
                    for transfer in (1, 13):
                        for intent in (0, 1, 2, 3):
                            records.append(dict(width=5, height=3, bits=bits, channels=channels,
                                                premultiplied=associated, transferFunction=transfer, renderingIntent=intent))
            for index, record in enumerate(records):
                target = root / ("public-matrix-" + str(index))
                target.mkdir()
                (target / "oracle.json").write_text(json.dumps(record))
            self.assertEqual(gate.profile_evidence(root)["observed"], 432)
            target = root / "public-matrix-431/oracle.json"
            target.write_text(json.dumps(records[0]))
            with self.assertRaises(RuntimeError):
                gate.profile_evidence(root)
            target.write_text(json.dumps(dict(records[-1], width=6)))
            with self.assertRaises(RuntimeError):
                gate.profile_evidence(root)

    def test_intentional_swift_race_requires_an_actual_finding_and_configured_exit(self):
        expected = ["WARNING: ThreadSanitizer: data race", "WARNING: ThreadSanitizer: Swift access race"]
        for diagnostic in expected:
            self.assertTrue(gate.negative_probe_detected(66, diagnostic + " (pid=123)", expected))
            self.assertFalse(gate.negative_probe_detected(0, diagnostic, expected))
        for text in ["", "Simultaneous accesses", "FATAL: ThreadSanitizer: unexpected memory mapping"]:
            self.assertFalse(gate.negative_probe_detected(66, text, expected))
        self.assertFalse(gate.negative_probe_detected(-11, expected[0], expected))

    def check(self, *, skip=False, failure=False, diagnostic="", omit=False, empty=False, substitute=False):
        names = ["SwiftJXLTests.Lifetime/" + name + "()" for name in gate.REQUIRED_TESTS]
        root = ET.Element("testsuites")
        suite = ET.SubElement(root, "testsuite")
        selected = [] if empty else names[:-1] if omit else names
        if substitute:
            selected = selected[:-1] + ["SwiftJXLTests.Different/unexpected()"]
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
        for option in [{"empty": True}, {"omit": True}, {"substitute": True}]:
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
