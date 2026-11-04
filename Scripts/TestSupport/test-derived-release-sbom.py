#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Guard narrowly qualified derivations against data loss and invented facts."""

import copy
import importlib.util
from pathlib import Path
import unittest
import uuid

spec = importlib.util.spec_from_file_location("derive_sbom", Path(__file__).resolve().parents[1] / "derive-release-sbom.py")
derive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(derive)


class DerivedSBOMTests(unittest.TestCase):
    def setUp(self):
        self.revision = "a" * 40
        self.identity = "synthetic-checkout"
        self.raw_hash = "b" * 64
        self.runner_hash = "c" * 64
        self.timestamp = "2026-11-04T00:00:00Z"
        self.identifier = "c74c7f22-245b-43ac-9423-594654dd8178"
        self.package = {"type": "application", "name": self.identity, "bom-ref": "package", "version": self.revision,
                        "purl": f"pkg:swift/{self.identity}@{self.revision}"}
        self.product = {"type": "library", "name": "SwiftJXL", "bom-ref": "product", "version": self.revision,
                        "purl": f"pkg:swift/{self.identity}/{self.identity}:SwiftJXL@{self.revision}"}
        self.cyclonedx = {"bomFormat": "CycloneDX", "specVersion": "1.7", "version": 1,
                         "serialNumber": "urn:uuid:" + self.identifier,
                         "components": [self.package, self.product],
                         "metadata": {"component": copy.deepcopy(self.product), "timestamp": "2026-11-03T00:00:00Z",
                                      "tools": {"components": [{"type": "application", "name": "swift-package-manager",
                                                                 "purl": "pkg:swift/github.com/swiftlang/swift-package-manager@6.4.2"}]}},
                         "dependencies": [{"ref": "package", "dependsOn": ["product"]}]}
        self.spdx = {"@context": derive.SEMANTIC_SOURCES["spdx-context.jsonld"], "@graph": [
            {"@id": "_:ci", "type": "CreationInfo", "specVersion": "6.4.2"},
            {"type": "software_Package", "spdxId": "urn:package", "creationInfo": "_:ci", "name": self.identity,
             "externalUrl": self.package["purl"], "software_internalVersion": self.revision},
            {"type": "software_Package", "spdxId": "urn:product", "creationInfo": "_:ci", "name": "SwiftJXL",
             "externalUrl": self.product["purl"], "software_internalVersion": self.revision},
            {"type": "SpdxDocument", "spdxId": "urn:original-document", "creationInfo": "_:ci"}]}

    def cdx(self, original):
        return derive.derive_cyclonedx(original, self.revision, self.identity, self.raw_hash, self.runner_hash, self.timestamp)

    def spdx_result(self, original):
        return derive.derive_spdx(original, self.revision, self.identity, self.raw_hash, self.runner_hash,
                                  self.timestamp, self.identifier)

    def test_cyclonedx_preserves_original_and_tool_identity(self):
        before = copy.deepcopy(self.cyclonedx)
        result, edits = self.cdx(self.cyclonedx)
        self.assertEqual(self.cyclonedx, before)
        self.assertEqual(result["serialNumber"], before["serialNumber"])
        self.assertEqual(result["version"], 2)
        self.assertEqual(result["metadata"]["tools"]["components"][0], before["metadata"]["tools"]["components"][0])
        self.assertEqual(result["dependencies"], before["dependencies"])
        self.assertEqual(len(result["components"]), 1)
        self.assertNotIn("purl", result["components"][0])
        self.assertNotIn("purl", result["metadata"]["component"])
        derive.check_references(result, "cyclonedx")
        self.assertTrue(any(row["pointer"] == "/version" for row in edits))

    def test_nonidentical_duplicate_and_unrecognised_purl_reject(self):
        altered = copy.deepcopy(self.cyclonedx)
        altered["metadata"]["component"]["description"] = "additional information"
        with self.assertRaises(RuntimeError):
            self.cdx(altered)
        altered = copy.deepcopy(self.cyclonedx)
        altered["components"][0]["purl"] = "pkg:swift/github.com/owner/repo@1.0.0"
        with self.assertRaises(RuntimeError):
            self.cdx(altered)

    def test_spdx_derivation_has_distinct_provenance_and_exact_revision(self):
        before = copy.deepcopy(self.spdx)
        result, edits = self.spdx_result(self.spdx)
        self.assertEqual(self.spdx, before)
        document = next(row for row in result["@graph"] if row["type"] == "SpdxDocument")
        self.assertEqual(document["spdxId"], "urn:uuid:" + self.identifier)
        self.assertIn(self.raw_hash, document["comment"])
        for row in result["@graph"][-2:]:
            value = row.get("spdxId", row.get("@id"))
            uuid.UUID(value.removeprefix("urn:uuid:"))
        for row in result["@graph"]:
            if row["type"] == "software_Package":
                self.assertEqual(row["software_packageVersion"], self.revision)
                self.assertNotIn("externalUrl", row)
                self.assertNotIn("software_packageUrl", row)
                self.assertEqual(row["creationInfo"], document["creationInfo"])
        self.assertTrue(any(row["before"] == "6.4.2" for row in edits if "before" in row))

    def test_unknown_spdx_defect_and_unresolved_reference_reject(self):
        altered = copy.deepcopy(self.spdx)
        altered["@graph"][0]["specVersion"] = "unknown"
        with self.assertRaises(RuntimeError):
            self.spdx_result(altered)
        result, _ = self.cdx(self.cyclonedx)
        result["dependencies"][0]["dependsOn"] = ["missing"]
        with self.assertRaises(RuntimeError):
            derive.check_references(result, "cyclonedx")


if __name__ == "__main__":
    unittest.main()
