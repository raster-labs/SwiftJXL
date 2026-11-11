#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail-closed tests for current-source simulator discovery and acceptance."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("apple_suite", Path(__file__).with_name("qualify-apple-simulator-suite.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.runtime = {"version": "26.0", "buildversion": "23A343"}
        self.device = {"platform": "iOS Simulator", "architecture": "arm64", "osVersion": "26.0", "osBuildNumber": "23A343"}
        self.summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2, "failedTests": 0,
                        "skippedTests": 0, "expectedFailures": 0,
                        "devicesAndConfigurations": [{"device": self.device, "passedTests": 3, "failedTests": 0, "skippedTests": 0}]}
        self.tree = {"declarations": [{"identity": "A/x()", "result": "Passed"}, {"identity": "B/y(_:)", "result": "Passed"}],
                     "leafCases": [{"nodeIdentifierURL": str(i), "result": "Passed"} for i in range(3)]}
        self.console = {"declarationsPassed": 2, "totalCasesPassed": 3, "declarationsFailed": 0,
                        "armIntegerOracleCases": 123, "optionalFullRangeHardwareReciprocalVectorsPassed": True}

    def assess(self, configuration="debug", text="", instrumentation=None):
        return suite.assess(self.summary, self.tree, self.console, {"A/x()", "B/y(_:)"}, 3,
                            "iOS Simulator", self.runtime, configuration, text, instrumentation)

    def test_accepts_consistent_evidence(self):
        self.assertTrue(self.assess()["passed"])

    def test_rejects_distinct_result_mutations(self):
        mutations = [
            lambda: self.tree["declarations"].pop(),
            lambda: self.tree["declarations"][1].update(identity="A/x()"),
            lambda: self.tree["leafCases"].pop(),
            lambda: self.tree["leafCases"][1].update(nodeIdentifierURL="0"),
            lambda: self.tree["leafCases"][0].update(result="Failed"),
            lambda: self.tree["leafCases"][0].update(result="Skipped"),
            lambda: self.summary.update(result="Failed"),
            lambda: self.summary.update(skippedTests=1),
            lambda: self.summary.update(expectedFailures=1),
            lambda: self.console.update(totalCasesPassed=2),
            lambda: self.console.update(armIntegerOracleCases=122),
            lambda: self.console.update(optionalFullRangeHardwareReciprocalVectorsPassed=False),
            lambda: self.device.update(osBuildNumber="other"),
            lambda: self.device.update(platform="macOS"),
            lambda: self.device.update(architecture="x86_64"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                self.setUp()
                mutate()
                self.assertFalse(self.assess()["passed"])

    def test_sanitizers_require_binary_proof_even_if_compiler_logs_look_valid(self):
        self.assertFalse(self.assess("asan", "-sanitize=address")["passed"])
        self.assertFalse(self.assess("asan", "libclang_rt.asan_iossim_dynamic.dylib")["passed"])
        self.assertFalse(self.assess("asan", "-sanitize\\=address libclang_rt.asan_iossim_dynamic.dylib")["passed"])
        self.assertTrue(self.assess("asan", instrumentation={"passed": True})["passed"])
        self.assertFalse(self.assess("asan", instrumentation={"passed": False})["passed"])

    def test_rejects_sanitizer_diagnostics_even_when_tests_pass(self):
        for message in ("ERROR: AddressSanitizer: heap-use-after-free", "WARNING: ThreadSanitizer: data race", "AddressSanitizer:DEADLYSIGNAL"):
            with self.subTest(message=message):
                self.assertFalse(self.assess(text=message)["passed"])

    def test_rejects_ambiguous_destination(self):
        self.summary["devicesAndConfigurations"].append(copy.deepcopy(self.summary["devicesAndConfigurations"][0]))
        with self.assertRaises(RuntimeError):
            self.assess()

    def test_discovery_failures(self):
        valid = {"errors": [], "values": [{"enabledTests": [{"identifier": "A/x/y()"}], "disabledTests": []}]}
        self.assertEqual(suite.enumerate_identities(valid), {"A.x/y()"})
        mutations = [
            {"errors": ["build failed"], "values": valid["values"]},
            {"errors": [], "values": []},
            {"errors": [], "values": [{"enabledTests": [], "disabledTests": []}]},
            {"errors": [], "values": [{"enabledTests": valid["values"][0]["enabledTests"] * 2}]},
            {"errors": [], "values": [{"enabledTests": valid["values"][0]["enabledTests"], "disabledTests": ["z"]}]},
        ]
        for document in mutations:
            with self.subTest(document=document), self.assertRaises(RuntimeError):
                suite.enumerate_identities(document)


class InstrumentationTests(unittest.TestCase):
    def sample(self, configuration="asan"):
        digest = "a" * 64
        entries, logs, commands = [], {}, []
        object_paths = ["/derived/" + name + ".o" for name in ("SwiftJXL", "SwiftJXLCore")]
        contents = " ".join(object_paths) + "\n"
        link_digest = hashlib.sha256(contents.encode()).hexdigest()
        artifacts = {"xctestBinaries": {}}
        for kind, names in (("library", ("SwiftJXL", "SwiftJXLCore")), ("testBundle", ("SwiftJXLTests", "SwiftJXLCoreTests"))):
            for name in names:
                relative = name + (".o" if kind == "library" else ".xctest/" + name)
                path, symbol_label = "/derived/" + relative, name + "-symbols"
                entry = {"kind": kind, "name": name, "absolutePath": path, "relativePath": relative,
                         "sha256Before": digest, "sha256After": digest, "symbolLog": symbol_label}
                commands.append({"label": symbol_label, "command": ["xcrun", "nm", "-arch", "arm64", "-u", path]})
                logs[symbol_label] = "___asan_report_load1\n___asan_report_store8\n" if configuration == "asan" else "___tsan_read8\n___tsan_write1\n"
                if kind == "testBundle":
                    load_label = name + "-loads"
                    entry.update(loadLog=load_label, linkFileList={"sha256Before": link_digest, "sha256After": link_digest, "contents": contents, "entries": object_paths.copy()})
                    commands.append({"label": load_label, "command": ["xcrun", "otool", "-arch", "arm64", "-L", path]})
                    logs[load_label] = "@rpath/libclang_rt." + configuration + "_iossim_dynamic.dylib"
                    artifacts["xctestBinaries"][relative] = {"sha256": digest}
                entries.append(entry)
        proof = {"architecture": "arm64", "configuration": configuration, "derivedData": "/derived", "entries": entries}
        return proof, logs, commands, artifacts

    def test_accepts_actual_hook_shapes_without_any_compiler_log(self):
        for configuration in ("asan", "tsan"):
            self.assertTrue(suite.assess_instrumentation(configuration, *self.sample(configuration))["passed"])

    def test_rejects_missing_or_mismatched_binary_proof(self):
        for mutation in range(9):
            proof, logs, commands, artifacts = self.sample()
            if mutation == 0: proof["entries"].pop()
            if mutation == 1: proof["architecture"] = "x86_64"
            if mutation == 2: proof["entries"][0]["sha256After"] = "b" * 64
            if mutation == 3: logs[proof["entries"][0]["symbolLog"]] = "___asan_init\n"
            if mutation == 4: logs[proof["entries"][2]["loadLog"]] = "@rpath/libclang_rt.tsan_iossim_dynamic.dylib"
            if mutation == 5: proof["entries"][2]["linkFileList"]["entries"].pop()
            if mutation == 6: commands[0]["command"][-1] = "/different/object.o"
            if mutation == 7: artifacts["xctestBinaries"][proof["entries"][2]["relativePath"]]["sha256"] = "b" * 64
            if mutation == 8: proof["entries"][2]["linkFileList"]["contents"] = "/different/object.o\n"
            with self.subTest(mutation=mutation):
                self.assertFalse(suite.assess_instrumentation("asan", proof, logs, commands, artifacts)["passed"])


if __name__ == "__main__":
    unittest.main()
