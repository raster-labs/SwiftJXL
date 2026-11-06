#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Negative acceptance checks for the release-consumer evidence gate."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_consumer", Path(__file__).resolve().parents[1] / "validate-release-consumer.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseConsumerGateTests(unittest.TestCase):
    def setUp(self):
        self.revision = "a" * 40
        self.version = "2.0.0"
        self.url = "file:///private/rehearsal/SwiftJXL.git"
        self.pin = {"identity": "swiftjxl", "kind": "localSourceControl", "location": "/private/rehearsal/SwiftJXL.git",
                    "state": {"revision": self.revision, "version": self.version}}

    def test_exact_pin_is_accepted(self):
        gate.validate_lockfile({"pins": [self.pin]}, self.revision, self.version, self.url)

    def test_revision_pin_rejects_a_moving_branch(self):
        pin = copy.deepcopy(self.pin)
        del pin["state"]["version"]
        gate.validate_lockfile({"pins": [pin]}, self.revision, None, self.url)
        pin["state"]["branch"] = "main"
        with self.assertRaises(RuntimeError):
            gate.validate_lockfile({"pins": [pin]}, self.revision, None, self.url)

    def test_wrong_revision_or_version_is_rejected(self):
        for key, value in [("revision", "b" * 40), ("version", "2.1.0")]:
            pin = copy.deepcopy(self.pin)
            pin["state"][key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                gate.validate_lockfile({"pins": [pin]}, self.revision, self.version, self.url)

    def test_path_dependency_or_unexpected_remote_is_rejected(self):
        for key, value in [("kind", "fileSystem"), ("location", "/sibling/SwiftJXL.git")]:
            pin = copy.deepcopy(self.pin)
            pin[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                gate.validate_lockfile({"pins": [pin]}, self.revision, self.version, self.url)

    def test_https_requires_remote_source_control(self):
        url = "https://github.com/raster-labs/SwiftJXL.git"
        pin = copy.deepcopy(self.pin)
        pin.update(kind="remoteSourceControl", location=url)
        gate.validate_lockfile({"pins": [pin]}, self.revision, self.version, url)
        pin["kind"] = "localSourceControl"
        with self.assertRaises(RuntimeError):
            gate.validate_lockfile({"pins": [pin]}, self.revision, self.version, url)

    def test_missing_or_extra_pins_are_rejected(self):
        for pins in [[], [self.pin, self.pin]]:
            with self.subTest(count=len(pins)), self.assertRaises(RuntimeError):
                gate.validate_lockfile({"pins": pins}, self.revision, self.version, self.url)

    def test_transitive_dependency_is_rejected(self):
        package = {"name": "SwiftJXL", "url": self.url, "version": self.version, "dependencies": []}
        gate.validate_graph({"dependencies": [package]}, self.url, self.version)
        package["dependencies"].append({"name": "ForeignCodec"})
        with self.assertRaises(RuntimeError):
            gate.validate_graph({"dependencies": [package]}, self.url, self.version)

    def test_manifest_dependency_and_unsafe_flags_are_rejected(self):
        manifest = {"name": "SwiftJXL", "dependencies": [], "toolsVersion": {"_version": "6.2.0"},
                    "swiftLanguageVersions": ["6"],
                    "platforms": [{"platformName": name, "version": "26.0"}
                                  for name in ["macos", "ios", "tvos", "visionos", "watchos"]],
                    "products": [{"name": "SwiftJXL", "targets": ["SwiftJXL"], "type": {"library": []}},
                                 {"name": "swiftjxl-cli", "targets": ["SwiftJXLCLI"], "type": {"executable": None}}],
                    "targets": [{"name": "SwiftJXL", "type": "regular", "dependencies": [{"byName": ["SwiftJXLCore", None]}]},
                                {"name": "SwiftJXLCore", "type": "regular", "dependencies": []},
                                {"name": "SwiftJXLCLI", "type": "executable", "dependencies": [{"byName": ["SwiftJXL", None]}]}]}
        gate.validate_manifest(manifest)
        external = copy.deepcopy(manifest)
        external["dependencies"] = [{"sourceControl": [{"identity": "foreign-codec"}]}]
        with self.assertRaises(RuntimeError):
            gate.validate_manifest(external)
        unsafe = copy.deepcopy(manifest)
        unsafe["targets"][0]["settings"] = [{"kind": {"unsafeFlags": ["-suppress-warnings"]}}]
        with self.assertRaises(RuntimeError):
            gate.validate_manifest(unsafe)


if __name__ == "__main__":
    unittest.main()
