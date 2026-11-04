#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Derive explicitly corrected SBOMs; preserve and validate every original.

This narrowly handles the observed Swift 6.4.2 generator defects. It does not
repair arbitrary documents, invent component metadata or expand the inventory.
The official schemas, SPDX model and JSON-LD context must be supplied offline.
"""

import argparse
import copy
import datetime
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import uuid

spec = importlib.util.spec_from_file_location("sbom_gate", Path(__file__).with_name("validate-release-sbom.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
require = gate.require

SEMANTIC_SOURCES = {
    "spdx-model.ttl": "https://spdx.org/rdf/3.0.1/spdx-model.ttl",
    "spdx-context.jsonld": "https://spdx.org/rdf/3.0.1/spdx-context.jsonld",
}
PINS = {"jsonschema": "4.25.1", "pyshacl": "0.30.1", "rdflib": "7.1.4", "owlrl": "7.1.4"}


def change(node, path, key, value, edits, reason):
    before = node.get(key)
    edits.append({"operation": "replace" if key in node else "add", "pointer": f"{path}/{key}",
                  "before": copy.deepcopy(before), "after": copy.deepcopy(value), "reason": reason})
    node[key] = value


def remove(node, path, key, edits, reason):
    edits.append({"operation": "remove", "pointer": f"{path}/{key}", "before": node.pop(key), "reason": reason})


def expected_purls(identity, revision):
    return {f"pkg:swift/{identity}@{revision}", f"pkg:swift/{identity}/{identity}:SwiftJXL@{revision}"}


def recognised_purls(identity, revision, canonical_root=None):
    if canonical_root is None:
        return expected_purls(identity, revision)
    require(identity == "swiftjxl" and canonical_root == f"pkg:swift/github.com/raster-labs/swiftjxl@{revision}",
            "Unexpected canonical repository identity")
    return {canonical_root, f"pkg:swift/github.com/raster-labs/swiftjxl:SwiftJXL@{revision}"}


def verify_repository_alias(evidence, origin):
    rows = evidence.get("queries", [])
    require(len(rows) == 2 and {row.get("query") for row in rows} == {"raster-labs/swiftjxl", "raster-labs/SwiftJXL"}
            and len({row.get("repositoryID") for row in rows}) == 1
            and all(str(row.get("repositoryID", "")).isdigit() and row.get("canonicalFullName") == "raster-labs/SwiftJXL"
                    and row.get("cloneURL") == origin for row in rows)
            and evidence.get("sameRepository") is True, "Repository alias evidence does not establish the same source repository")


def derive_spdx(original, revision, identity, raw_hash, runner_hash, now, identifier, canonical_root=None):
    document, edits = copy.deepcopy(original), []
    require(document.get("@context") == SEMANTIC_SOURCES["spdx-context.jsonld"], "Unexpected SPDX context")
    graph = document["@graph"]
    packages = [(i, node) for i, node in enumerate(graph) if node.get("type") == "software_Package"]
    require(len(packages) == 2 and {node.get("name") for _, node in packages} == {identity, "SwiftJXL"},
            "Unexpected package graph; derivation is limited to the observed standalone graph")
    recognised = recognised_purls(identity, revision, canonical_root)
    require({node.get("externalUrl") for _, node in packages} == recognised,
            "Unrecognised package URL; do not remove an unknown or potentially valid identifier")
    if canonical_root:
        require(next(node for _, node in packages if node["name"] == identity)["externalUrl"] == canonical_root,
                "Root repository identifier is attached to the wrong package")
        # SwiftPM emits an unattached ExternalIdentifier complex value as
        # though it were an Element, then points a relationship at an Element
        # identity it never defines. An anonymous complex value alone is valid.
        # The verified root purl/version already retain the commit and origin.
        # Preserve these exact defective objects in the edit record; do not
        # invent an SPDX source Element or a different kind of Git identifier.
        source_id = "urn:spdx:" + revision
        infos = {node["creationInfo"] for _, node in packages}
        require(len(infos) == 1, "Unexpected source creation information")
        expected_identifier = {"type": "ExternalIdentifier", "externalIdentifierType": "gitoid",
            "identifier": source_id, "identifierLocator": ["https://github.com/raster-labs/SwiftJXL.git"]}
        expected_relation = {"type": "Relationship", "creationInfo": next(iter(infos)),
            "spdxId": source_id + "-generates", "from": source_id, "relationshipType": "generates",
            "to": [node["spdxId"] for _, node in packages]}
        removals = [(i, node) for i, node in enumerate(graph) if node in (expected_identifier, expected_relation)]
        require(len(removals) == 2 and sum(node == expected_identifier for _, node in removals) == 1
                and sum(node == expected_relation for _, node in removals) == 1
                and all(i > max(index for index, _ in packages) for i, _ in removals),
                "Unrecognised orphan source identifier/relationship; do not discard unknown provenance")
        removed_indices = {index for index, _ in removals}
        require(not any(value in (source_id, source_id + "-generates")
                        for index, node in enumerate(graph) if index not in removed_indices
                        for _, value in gate.walk(node)), "Other references to defective source nodes must be reviewed")
        for index, node in reversed(removals):
            edits.append({"operation": "remove", "pointer": f"/@graph/{index}", "before": graph.pop(index),
                "reason": "Malformed orphan source identifier and dangling generates edge; exact originals retained here, verified source commit/origin retained in the package version/purl and repository evidence"})
    namespace = uuid.UUID(identifier)
    ci_id = "urn:uuid:" + str(uuid.uuid5(namespace, "creationInfo"))
    agent_id = "urn:uuid:" + str(uuid.uuid5(namespace, "agent"))
    document_id = "urn:uuid:" + identifier
    provenance = f"Derived by Scripts/derive-release-sbom.py SHA-256 {runner_hash} from original SHA-256 {raw_hash}; see report.json."
    bad_creation = [(i, node) for i, node in enumerate(graph)
                    if node.get("type") == "CreationInfo" and node.get("specVersion") != "3.0.1"]
    require(len(bad_creation) == 1 and bad_creation[0][1].get("specVersion") == "6.4.2",
            "Unrecognised SPDX generator-version defect")
    index, node = bad_creation[0]
    change(node, f"/@graph/{index}", "specVersion", "3.0.1", edits, "SPDX model version, not compiler version")
    require("comment" not in node, "Do not overwrite an existing generator creation comment")
    change(node, f"/@graph/{index}", "comment", "Original generator value was 6.4.2 (compiler version). " + provenance,
           edits, "Identify the explicit correction without attributing it to SwiftPM")
    for index, node in packages:
        path = f"/@graph/{index}"
        require(node.get("software_internalVersion") == revision and "software_packageVersion" not in node
                and "software_packageUrl" not in node, "Unexpected package-version fields")
        purl = node["externalUrl"]
        if purl == canonical_root:
            remove(node, path, "externalUrl", edits, "Unknown SPDX property; preserve the verified emitted repository identifier using the standard property")
            change(node, path, "software_packageUrl", purl, edits, "Preserve the exact emitted root purl; origin, commit pedigree and GitHub repository alias were verified")
        else:
            reason = ("Product-colon suffix names a build product, not the verified source repository; optional product purl omitted without inventing a replacement"
                      if canonical_root else "Malformed Swift purl lacks the required source-host/organisation namespace; optional identifier omitted")
            remove(node, path, "externalUrl", edits, "Unknown SPDX property. " + reason)
        value = node["software_internalVersion"]
        remove(node, path, "software_internalVersion", edits, "Unknown SPDX property")
        change(node, path, "software_packageVersion", value, edits, "Preserve the exact recorded source revision using its standard property")
        change(node, path, "creationInfo", ci_id, edits, "These corrected elements were produced by the derivation tool")
    documents = [(i, node) for i, node in enumerate(graph) if node.get("type") == "SpdxDocument"]
    require(len(documents) == 1, "Expected one SPDX document")
    index, node = documents[0]
    old_id = node["spdxId"]
    require(all(value != old_id for path, value in gate.walk(document)
                if path != ("@graph", index, "spdxId")), "Unexpected references to the document identity")
    require("comment" not in node, "Do not overwrite an existing document comment")
    change(node, f"/@graph/{index}", "spdxId", document_id, edits, "New derived document identity")
    change(node, f"/@graph/{index}", "creationInfo", ci_id, edits, "Record actual derivation time and agent")
    change(node, f"/@graph/{index}", "comment", provenance + " Original document: " + old_id,
           edits, "The derived document is not unchanged SwiftPM output")
    for added in [
        {"@id": ci_id, "type": "CreationInfo", "created": now, "createdBy": [agent_id], "specVersion": "3.0.1"},
        {"spdxId": agent_id, "type": "SoftwareAgent", "name": "SwiftJXL SBOM derivation",
         "creationInfo": ci_id, "comment": "Scripts/derive-release-sbom.py SHA-256 " + runner_hash},
    ]:
        edits.append({"operation": "add", "pointer": f"/@graph/{len(graph)}", "after": added,
                      "reason": "Actual derivation provenance, not an inferred package fact"})
        graph.append(added)
    return document, edits


def derive_cyclonedx(original, revision, identity, raw_hash, runner_hash, now, canonical_root=None):
    document, edits = copy.deepcopy(original), []
    require(document.get("bomFormat") == "CycloneDX" and document.get("specVersion") == "1.7", "Unexpected CycloneDX format")
    require(document.get("version") == 1, "Expected original BOM version 1")
    require(re.fullmatch(r"urn:uuid:[0-9a-f-]{36}", document.get("serialNumber", "")), "Expected original BOM serial identifier")
    components, primary = document["components"], document["metadata"]["component"]
    require(len(components) == 2 and primary.get("name") == "SwiftJXL", "Unexpected component graph")
    matches = [i for i, item in enumerate(components) if item == primary]
    require(len(matches) == 1 and len(gate.semantic_errors(document, "cyclonedx")) == 1,
            "Expected exactly one identical duplicate of the metadata component")
    require({item.get("purl") for item in components} == recognised_purls(identity, revision, canonical_root),
            "Unrecognised package URLs; no identifier may be guessed or silently removed")
    if canonical_root:
        require(next(item for item in components if item["name"] == identity)["purl"] == canonical_root,
                "Root repository identifier is attached to the wrong component")
    index = matches[0]
    edits.append({"operation": "remove", "pointer": f"/components/{index}", "before": components.pop(index),
                  "reason": "Identical product remains at metadata.component; retain one unique bom-ref definition"})
    for path, node in [("/components/0", components[0]), ("/metadata/component", primary)]:
        require(node.get("version") == revision, "Unexpected component source revision")
        if node["purl"] != canonical_root:
            remove(node, path, "purl", edits,
                   "Product-colon suffix is not the verified source repository; optional product identifier omitted, original retained in provenance"
                   if canonical_root else "Malformed Swift purl lacks required source-host/organisation namespace; optional identifier omitted, original retained in provenance")
    change(document, "", "version", 2, edits, "Increment modified BOM version while retaining its original serialNumber")
    change(document["metadata"], "/metadata", "timestamp", now, edits, "Actual time of derived BOM creation")
    tool_container = document["metadata"].get("tools")
    require(isinstance(tool_container, dict) and isinstance(tool_container.get("components"), list),
            "Unexpected generator tools representation")
    tools = tool_container["components"]
    derived_tool = {"type": "application", "name": "SwiftJXL SBOM derivation", "version": runner_hash}
    edits.append({"operation": "add", "pointer": f"/metadata/tools/components/{len(tools)}", "after": derived_tool,
                  "reason": "Record actual enrichment tool; version is its source SHA-256"})
    tools.append(derived_tool)
    require("properties" not in document["metadata"], "Do not replace existing metadata properties")
    change(document["metadata"], "/metadata", "properties",
           [{"name": "swiftjxl:derivation:original-sha256", "value": raw_hash},
            {"name": "swiftjxl:derivation:scope", "value": "Corrected SwiftPM package graph; see report.json; not a complete system inventory"}],
           edits, "Link the derived BOM to its preserved original and scope")
    return document, edits


def check_references(document, specification):
    if specification == "cyclonedx":
        require(not gate.semantic_errors(document, specification), "Duplicate CycloneDX definitions")
        identifiers = {node["bom-ref"] for _, node in gate.walk(document) if isinstance(node, dict) and "bom-ref" in node}
        for item in document.get("dependencies", []):
            require(item["ref"] in identifiers, "Unresolved dependency source")
            require(all(value in identifiers for value in item.get("dependsOn", []) + item.get("provides", [])),
                    "Unresolved dependency target")
    else:
        nodes = document["@graph"]
        identifiers = [node.get("spdxId", node.get("@id")) for node in nodes]
        require(None not in identifiers and len(set(identifiers)) == len(identifiers), "Missing or duplicate SPDX node identity")
        for node in nodes:
            for key in ["creationInfo", "createdBy", "createdUsing", "from", "to", "rootElement", "element", "dataLicense"]:
                if key in node:
                    values = node[key] if isinstance(node[key], list) else [node[key]]
                    require(all(value in identifiers for value in values), f"Unresolved SPDX reference: {key}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-report", required=True, type=Path)
    parser.add_argument("--schemas", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repository-identity", type=Path,
                        help="Read-only GitHub alias evidence for an origin-tracked canonical SwiftJXL checkout; preserve its exact emitted root purl")
    args = parser.parse_args()
    output, schemas, build_path = args.output.resolve(), args.schemas.resolve(), args.build_report.resolve()
    output.mkdir(parents=True, exist_ok=False)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    runner_hash = gate.digest(Path(__file__).read_bytes())
    report = {"schemaVersion": 1, "status": "running", "startedUTC": now,
              "command": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]], "runnerSHA256": runner_hash,
              "scope": "Explicitly derived, validated SwiftPM package-graph SBOMs; original generator output remains defective",
              "limitations": ["No complete SDK, runtime or embedded third-party inventory is inferred",
                              "Only recognised malformed or product-only purls are omitted; a verified emitted root purl is preserved without guessing a remote identity"],
              "environment": {"python": platform.python_version()}, "artifacts": []}
    try:
        from jsonschema import FormatChecker
        from jsonschema.validators import validator_for
        from referencing import Registry, Resource
        from referencing.exceptions import NoSuchResource
        from pyshacl import validate
        from rdflib import Graph, URIRef, RDF

        versions = {name: importlib.metadata.version(name) for name in PINS}
        require(versions == PINS, "Validator versions differ from pinned toolchain")
        report["environment"]["validators"] = versions
        report["environment"]["packages"] = {item.metadata["Name"]: item.version for item in importlib.metadata.distributions()}
        command = [sys.executable, str(Path(__file__).with_name("validate-release-sbom.py")), "--build-report", str(build_path),
                   "--schemas", str(schemas), "--output", str(output / "raw-validation")]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
        (output / "raw-validation.log").write_text(completed.stdout + completed.stderr)
        report["rawValidationCommand"] = {"argv": command, "exitCode": completed.returncode}
        require(completed.returncode == 1, "Expected the original, recognised generator defects")
        raw_validation = json.loads((output / "raw-validation/report.json").read_text())
        require("failure" not in raw_validation and len(raw_validation["artifacts"]) == 2, "Raw validation failed before examining both emissions")
        for artifact in raw_validation["artifacts"]:
            if artifact["specification"] == "spdx":
                errors = artifact["schemaErrors"]
                require(len(errors) == 2 and all(error["validator"] == "unevaluatedProperties" and
                        error["message"] == "Unevaluated properties are not allowed ('externalUrl', 'software_internalVersion' were unexpected)"
                        for error in errors), "Unrecognised raw SPDX structural failure")
                require(len(artifact["semanticErrors"]) == 1 and artifact["semanticErrors"][0]["observed"] == "6.4.2",
                        "Unrecognised raw SPDX semantic failure")
            else:
                require(not artifact["schemaErrors"] and len(artifact["semanticErrors"]) == 1
                        and artifact["semanticErrors"][0]["rule"] == "CycloneDX-unique-bom-ref", "Unrecognised raw CycloneDX failure")
        build = json.loads(build_path.read_text())
        require("Apple Swift version 6.4.2 " in build["toolchain_swift"], "Derivation is qualified for Swift 6.4.2 emissions only")
        revision, identity = build["source_commit"], Path(build["repository"]).name.lower()
        require(re.fullmatch("[0-9a-f]{40}", revision) and not build["working_tree"], "Require clean committed source build evidence")
        report["sourceRevision"] = revision
        report["buildReportSHA256"] = gate.digest(build_path.read_bytes())
        canonical_root = None
        if args.repository_identity:
            repository = Path(build["repository"])
            def git(*arguments):
                return subprocess.check_output(["git", "-C", str(repository), *arguments], text=True).strip()
            origin = git("remote", "get-url", "origin")
            require(origin == "https://github.com/raster-labs/SwiftJXL.git" and identity == "swiftjxl"
                    and git("rev-parse", "HEAD") == revision and not git("status", "--porcelain"),
                    "Canonical derivation requires the same clean origin-tracked SwiftJXL source checkout")
            require(git("rev-parse", "@{upstream}") == revision, "Tracked origin revision differs from the build")
            alias_bytes = args.repository_identity.read_bytes()
            alias = json.loads(alias_bytes)
            verify_repository_alias(alias, origin)
            (output / "repository-identity.json").write_bytes(alias_bytes)
            canonical_root = f"pkg:swift/github.com/raster-labs/swiftjxl@{revision}"
            report["repositoryIdentity"] = {"origin": origin, "head": revision, "upstream": revision,
                "evidenceSHA256": gate.digest(alias_bytes), "emittedRootPURL": canonical_root,
                "note": "Observed repository alias only; Swift purl namespace/name case sensitivity is not relaxed."}
            cdx_artifact = next(item for item in raw_validation["artifacts"] if item["specification"] == "cyclonedx")
            cdx = json.loads(gate.verified_bytes(output / "raw-validation" / cdx_artifact["preservedPath"], cdx_artifact["sha256"]))
            require(len(cdx["components"]) == 2 and all(item.get("pedigree", {}).get("commits") ==
                    [{"uid": revision, "url": origin}] for item in cdx["components"]),
                    "Emitted commit pedigree does not match the verified origin and revision")
        bundle = output / "semantic-inputs"
        bundle.mkdir()
        semantic_sources = json.loads((schemas / "semantic-sources.json").read_text())
        require(len(semantic_sources) == 2 and {row["file"] for row in semantic_sources} == set(SEMANTIC_SOURCES), "Expected model and context pins")
        for row in semantic_sources:
            require(row["url"] == SEMANTIC_SOURCES[row["file"]], "Unexpected semantic source")
            (bundle / row["file"]).write_bytes(gate.verified_bytes(schemas / row["file"], row["sha256"]))
        (bundle / "sources.json").write_text(json.dumps(semantic_sources, indent=2) + "\n")
        report["semanticSources"] = semantic_sources
        resources, schema_documents = {}, {}
        for row in raw_validation["schemaSources"]:
            schema = json.loads(gate.verified_bytes(schemas / row["file"], row["sha256"]))
            schema_documents[row["file"]] = schema
            resource = Resource.from_contents(schema)
            resources[row["url"]] = resource
            if schema.get("$id"):
                resources[schema["$id"]] = resource

        def offline_only(uri):
            raise NoSuchResource(ref=uri)

        registry = Registry(retrieve=offline_only).with_resources(resources.items())
        context = json.loads((bundle / "spdx-context.jsonld").read_text())["@context"]
        require(not any(isinstance(node, dict) and "@import" in node for _, node in gate.walk(context)), "Remote JSON-LD context import is forbidden")
        model = Graph().parse(bundle / "spdx-model.ttl", format="turtle")
        require(not list(model.triples((None, URIRef("http://www.w3.org/2002/07/owl#imports"), None))), "Remote ontology imports are forbidden")
        derived_dir = output / "derived"
        derived_dir.mkdir()
        for artifact in raw_validation["artifacts"]:
            raw_path = output / "raw-validation" / artifact["preservedPath"]
            original = json.loads(gate.verified_bytes(raw_path, artifact["sha256"]))
            specification = artifact["specification"]
            if specification == "spdx":
                derived, edits = derive_spdx(original, revision, identity, artifact["sha256"], runner_hash, now, str(uuid.uuid4()), canonical_root)
            else:
                derived, edits = derive_cyclonedx(original, revision, identity, artifact["sha256"], runner_hash, now, canonical_root)
            destination = derived_dir / f"SwiftJXL-{specification}-derived.json"
            destination.write_text(json.dumps(derived, indent=2) + "\n")
            result = {"specification": specification, "rawSHA256": artifact["sha256"],
                      "derivedPath": str(destination.relative_to(output)), "derivedSHA256": gate.digest(destination.read_bytes()),
                      "edits": edits}
            report["artifacts"].append(result)
            # Reparse the actual bytes being delivered, not merely the in-memory result.
            final_document = json.loads(destination.read_text())
            schema = schema_documents[artifact["schema"]]
            validator = validator_for(schema)(schema, registry=registry, format_checker=FormatChecker())
            errors = list(validator.iter_errors(final_document))
            result["schemaErrors"] = [{"pointer": gate.pointer(error.absolute_path), "message": error.message} for error in errors]
            require(not errors, f"Final derived {specification} fails official schema")
            require(not gate.semantic_errors(final_document, specification), "Final selected semantic constraints failed")
            check_references(final_document, specification)
            result["uniqueAndReferenceChecks"] = "passed"
            if specification == "spdx":
                # Use the exact pinned global context for parsing in memory. The
                # delivered document retains the required canonical context URL.
                parsed = copy.deepcopy(final_document)
                parsed["@context"] = context
                graph = Graph().parse(data=json.dumps(parsed), format="json-ld")
                kwargs = dict(shacl_graph=model, ont_graph=model, inference="none", abort_on_first=False,
                              allow_infos=False, allow_warnings=False, advanced=False, js=False, inplace=False)
                conforms, results_graph, results_text = validate(graph, **kwargs)
                (output / "spdx-shacl.txt").write_text(results_text)
                results_graph.serialize(output / "spdx-shacl.ttl", format="turtle")
                result["shacl"] = {"conforms": bool(conforms), "dataTriples": len(graph), "modelTriples": len(model),
                                   "inference": "none", "allShapes": True, "warningsAllowed": False}
                require(conforms, "Final derived SPDX fails official OWL/SHACL model")
                # Removing a required creation timestamp must fail the same full
                # model, proving validation did not silently select zero shapes.
                negative = Graph()
                for triple in graph:
                    negative.add(triple)
                created = URIRef("https://spdx.org/rdf/3.0.1/terms/Core/created")
                creation = next(graph.subjects(RDF.type, URIRef("https://spdx.org/rdf/3.0.1/terms/Core/CreationInfo")))
                negative.remove((creation, created, None))
                rejected, _, negative_text = validate(negative, **kwargs)
                (output / "spdx-shacl-negative-sentinel.txt").write_text(negative_text)
                result["shacl"]["missingRequiredTimestampRejected"] = not rejected
                require(not rejected, "SHACL negative sentinel was not rejected")
            require(gate.digest(Path(artifact["originalPath"]).read_bytes()) == artifact["sha256"], "Original emission changed")
            result["status"] = "passed"
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(f"ERROR: {error}", file=sys.stderr)
    report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["exitCode"] = 0 if report["status"] == "passed" else 1
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{report['status']}; report: {output / 'report.json'}")
    return report["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
