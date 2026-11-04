#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate unchanged build-associated SBOMs with an offline schema bundle.

Requires jsonschema 4.25.1 and its dependencies. The schema directory contains
sources.json entries with file, official URL and SHA-256. No schema is downloaded
at runtime. JSON Schema and named semantic checks are not full SPDX SHACL or
CycloneDX conformance certification. Original emissions are never repaired.
"""

import argparse
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import sys
from urllib.parse import urldefrag, urljoin


SCHEMAS = {
    "spdx-3.0.1.schema.json": "https://spdx.org/schema/3.0.1/spdx-json-schema.json",
    "bom-1.7.schema.json": "https://cyclonedx.org/schema/bom-1.7.schema.json",
    "spdx.schema.json": "https://cyclonedx.org/schema/spdx.schema.json",
    "jsf-0.82.schema.json": "https://cyclonedx.org/schema/jsf-0.82.schema.json",
    "cryptography-defs.schema.json": "https://cyclonedx.org/schema/cryptography-defs.schema.json",
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verified_bytes(path, expected):
    data = path.read_bytes()
    require(digest(data) == expected, f"SHA-256 mismatch: {path}")
    return data


def pointer(parts):
    return "".join("/" + str(part).replace("~", "~0").replace("/", "~1") for part in parts)


def walk(value, path=()):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, path + (index,))


def semantic_errors(document, specification):
    errors = []
    if specification == "spdx":
        for path, value in walk(document):
            if isinstance(value, dict) and value.get("type") == "CreationInfo" and value.get("specVersion") != "3.0.1":
                errors.append({"rule": "SPDX-CreationInfo-specVersion", "pointer": pointer(path + ("specVersion",)),
                               "message": "CreationInfo must name SPDX specification 3.0.1, not the compiler version",
                               "observed": value.get("specVersion")})
    elif specification == "cyclonedx":
        references = {}
        for path, value in walk(document):
            if isinstance(value, dict) and "bom-ref" in value:
                reference = value["bom-ref"]
                if not isinstance(reference, str):
                    continue  # The schema reports its type error.
                if reference in references:
                    errors.append({"rule": "CycloneDX-unique-bom-ref", "pointer": pointer(path + ("bom-ref",)),
                                   "firstPointer": references[reference], "observed": reference,
                                   "message": "A bom-ref definition must be unique throughout the BOM"})
                else:
                    references[reference] = pointer(path + ("bom-ref",))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-report", type=Path, required=True)
    parser.add_argument("--schemas", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    args = parser.parse_args()
    output, schema_dir, build_path = args.output.resolve(), args.schemas.resolve(), args.build_report.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {
        "schemaVersion": 1, "status": "running", "fullConformanceQualified": False,
        "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "command": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]],
        "runnerSHA256": digest(Path(__file__).read_bytes()),
        "environment": {"python": platform.python_version(), "platform": platform.platform()},
        "scope": "Official offline JSON Schema plus explicitly named semantic checks on unchanged emitted bytes",
        "unexecuted": ["Full SPDX SHACL/RDF semantic validation", "Complete CycloneDX semantic validation",
                       "Completeness of non-SwiftPM/system/embedded third-party component inventory"],
        "artifacts": [],
    }
    try:
        from jsonschema import FormatChecker
        from jsonschema.validators import validator_for
        from referencing import Registry, Resource
        from referencing.exceptions import NoSuchResource

        version = importlib.metadata.version("jsonschema")
        report["environment"]["jsonschema"] = version
        report["environment"]["referencing"] = importlib.metadata.version("referencing")
        require(version == "4.25.1", "Use the pinned jsonschema 4.25.1 validator")
        build_bytes = build_path.read_bytes()
        build = json.loads(build_bytes)
        require(build.get("status") == "passed_requested_checks" and "sbom" in build.get("selected_checks", []),
                "Input must be a successful build-associated SBOM generation report")
        for label in ["sbom-spdx", "sbom-cyclonedx"]:
            commands = [row for row in build.get("commands", []) if row.get("label") == label]
            require(len(commands) == 1 and commands[0].get("exit_code") == 0, f"Missing successful {label} build command")
        report["buildReport"] = {"path": str(build_path), "sha256": digest(build_bytes),
                                 "sourceRevision": build.get("source_commit"),
                                 "manifestSHA256": build.get("manifest_sha256"),
                                 "compiler": build.get("toolchain_swift"), "buildEngine": build.get("build_engine"),
                                 "generatorOpenGates": build.get("open_gates", [])}
        (output / "build-report.json").write_bytes(build_bytes)
        sources_path = schema_dir / "sources.json"
        sources_bytes = sources_path.read_bytes()
        sources = json.loads(sources_bytes)
        require(len(sources) == len(SCHEMAS) and {row["file"] for row in sources} == set(SCHEMAS),
                "Expected the complete five-file official schema bundle")
        copied_schemas = output / "schemas"
        copied_schemas.mkdir()
        (copied_schemas / "sources.json").write_bytes(sources_bytes)
        report["schemaSourcesManifestSHA256"] = digest(sources_bytes)
        documents, resources = {}, {}
        for source in sources:
            name = source["file"]
            require(source["url"] == SCHEMAS[name], f"Unexpected schema source URL: {name}")
            data = verified_bytes(schema_dir / name, source["sha256"])
            (copied_schemas / name).write_bytes(data)
            schema = json.loads(data)
            validator_for(schema).check_schema(schema)
            documents[name] = schema
            resource = Resource.from_contents(schema)
            resources[source["url"]] = resource
            if schema.get("$id"):
                resources[schema["$id"]] = resource
        # Prove that every external schema reference is available locally before
        # validation. The registry callback below never attempts network I/O.
        for name, schema in documents.items():
            base = schema.get("$id", SCHEMAS[name])
            for _, value in walk(schema):
                if isinstance(value, dict) and "$ref" in value and not value["$ref"].startswith("#"):
                    uri = urldefrag(urljoin(base, value["$ref"]))[0]
                    require(uri in resources, f"Missing offline schema dependency: {uri}")

        def offline_only(uri):
            raise NoSuchResource(ref=uri)

        registry = Registry(retrieve=offline_only).with_resources(resources.items())
        report["schemaSources"] = sources
        originals = output / "originals"
        originals.mkdir()
        sboms = build.get("sboms", [])
        require(len(sboms) == 2, "Expected exactly one SPDX and one CycloneDX emission")
        formats = set()
        for row in sboms:
            require(row.get("build_associated") is True, "Graph-only SBOM does not satisfy this build-associated gate")
            source_path = (build_path.parent / row["path"]).resolve()
            require(source_path.is_relative_to(build_path.parent), "SBOM must remain inside its build evidence directory")
            original = verified_bytes(source_path, row["sha256"])
            document = json.loads(original)
            if document.get("@context") == "https://spdx.org/rdf/3.0.1/spdx-context.jsonld":
                specification, schema_name = "spdx", "spdx-3.0.1.schema.json"
            elif document.get("bomFormat") == "CycloneDX" and document.get("specVersion") == "1.7":
                specification, schema_name = "cyclonedx", "bom-1.7.schema.json"
            else:
                raise RuntimeError(f"Unsupported SBOM specification: {source_path.name}")
            require(specification not in formats, "Duplicate SBOM format")
            formats.add(specification)
            (originals / source_path.name).write_bytes(original)
            schema = documents[schema_name]
            validator = validator_for(schema)(schema, registry=registry, format_checker=FormatChecker())
            schema_errors = [{"pointer": pointer(error.absolute_path), "schemaPointer": pointer(error.absolute_schema_path),
                              "validator": error.validator, "message": error.message}
                             for error in validator.iter_errors(document)]
            semantics = semantic_errors(document, specification)
            report["artifacts"].append({"specification": specification, "originalPath": str(source_path),
                                        "preservedPath": f"originals/{source_path.name}", "sha256": row["sha256"],
                                        "schema": schema_name, "schemaSHA256": digest((schema_dir / schema_name).read_bytes()),
                                        "schemaErrors": schema_errors, "semanticErrors": semantics,
                                        "status": "failed" if schema_errors or semantics else "passed_selected_checks"})
            require(digest(source_path.read_bytes()) == row["sha256"], "Original emission changed during validation")
        require(formats == {"spdx", "cyclonedx"}, "Missing an emitted SBOM format")
        report["status"] = ("failed" if any(row["status"] == "failed" for row in report["artifacts"])
                            else "passed_selected_checks")
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(f"ERROR: {error}", file=sys.stderr)
    report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["exitCode"] = 0 if report["status"] == "passed_selected_checks" else 1
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    for artifact in report["artifacts"]:
        print(f"{artifact['specification']}: {len(artifact['schemaErrors'])} schema errors, "
              f"{len(artifact['semanticErrors'])} selected semantic errors")
    print(f"{report['status']}; report: {output / 'report.json'}")
    return report["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
