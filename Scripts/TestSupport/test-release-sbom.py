#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed checks for unchanged SBOM validation and semantic constraints."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_sbom", Path(__file__).resolve().parents[1] / "validate-release-sbom.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseSBOMGateTests(unittest.TestCase):
    def test_compiler_version_is_not_an_spdx_specification(self):
        errors = gate.semantic_errors({"@graph": [{"type": "CreationInfo", "specVersion": "6.4.2"}]}, "spdx")
        self.assertEqual(errors[0]["pointer"], "/@graph/0/specVersion")
        self.assertEqual(len(errors), 1)
        self.assertEqual(gate.semantic_errors({"@graph": [{"type": "CreationInfo", "specVersion": "3.0.1"}]}, "spdx"), [])

    def test_duplicate_component_reference_is_rejected(self):
        document = {"components": [{"bom-ref": "product"}], "metadata": {"component": {"bom-ref": "product"}}}
        errors = gate.semantic_errors(document, "cyclonedx")
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["firstPointer"], "/components/0/bom-ref")
        self.assertEqual(errors[0]["pointer"], "/metadata/component/bom-ref")

    def test_dependency_references_do_not_define_components(self):
        document = {"components": [{"bom-ref": "product"}], "dependencies": [{"ref": "product", "dependsOn": []}]}
        self.assertEqual(gate.semantic_errors(document, "cyclonedx"), [])

    def test_changed_emission_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "emission.json"
            original = b'{"original":true}\n'
            path.write_bytes(original)
            self.assertEqual(gate.verified_bytes(path, gate.digest(original)), original)
            path.write_bytes(b'{"repaired":true}\n')
            with self.assertRaises(RuntimeError):
                gate.verified_bytes(path, gate.digest(original))


if __name__ == "__main__":
    unittest.main()
