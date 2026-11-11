#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Audit source-bound release gates without treating unavailable work as a pass.

Exit 0: valid checklist (which may be blocked); 1: invalid evidence/checklist;
2: valid but blocked with --require-ready. Readiness never authorises publication.

A passed gate needs JSON evidence with resultPointer resolving to "passed" and
sourceBindings mapping every declared source group to a JSON pointer containing
that group's SHA-256. Optional jsonChecks assert other exact report properties.
For example: {"path": "report.json", "resultPointer": "/status",
"sourceBindings": {"runtime": "/sourceGroupDigests/runtime"}}.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


REQUIRED = {
    "M4-LINUX-SANITIZERS": "stable",
    "M4-MACOS-MINIMUM": "stable",
    "M4-MACOS-INTEL": "stable",
    "M4-PHYSICAL-DEVICES": "stable",
    "M4-IOS-SANITIZERS": "stable",
    "M4-CLI-TSAN": "stable",
    "M4-OTHER-SIMULATORS": "stable",
    "M5-URL-CONSUMER": "preparation",
    "M5-VERSIONED-CONSUMER": "preparation",
    "M5-DOCS-EXAMPLES": "preparation",
    "M5-LICENCE-PROVENANCE": "preparation",
    "M5-EVIDENCE-REVIEW": "preparation",
    "RELEASE-SBOM-SCHEMA": "stable",
    "RELEASE-SECURITY-POLICY": "stable",
}
RUNTIME_INCLUDES = ["Package.swift", "Sources/**/*", "VERSION"]
CONTRACT_FILES = {
    "CLI_CONTRACT.md", "COMMON_API.md", "MEMORY_CONTRACT.md",
    "PERFORMANCE.md", "PLATFORMS.md", "SUITE_POLICY.md", "TESTING.md",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory_digest(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


def local_file(repo, value):
    require(isinstance(value, str) and bool(value), "Missing repository file path")
    relative = Path(value)
    require(not relative.is_absolute() and ".." not in relative.parts,
            "Evidence/source paths must stay inside the repository: " + value)
    path = repo / relative
    require(path.is_file(), "Missing evidence/source file: " + value)
    require(path.resolve().is_relative_to(repo.resolve()), "File escapes repository: " + value)
    require(not any(part.is_symlink() for part in [path, *path.parents]
                    if part != repo and part.is_relative_to(repo)),
            "Symlink evidence/source is not accepted: " + value)
    return path


def pointer(document, value):
    require(isinstance(value, str) and value.startswith("/"), "Expected a JSON pointer")
    current = document
    for token in value[1:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            require(bool(re.fullmatch(r"0|[1-9][0-9]*", token)), "Invalid array JSON pointer")
            current = current[int(token)]
        else:
            require(isinstance(current, dict), "JSON pointer traverses a scalar")
            current = current[token]
    return current


def audit(repo, checklist):
    require(isinstance(checklist, dict) and checklist.get("schemaVersion") == 1,
            "Unsupported release-gate schema")
    require(checklist.get("contractVersion") == "0.10.0", "Unexpected contract version")
    for name in ("baselineRevision", "predecessorRevision"):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", checklist.get(name, ""))),
                "Invalid " + name)
    require(checklist.get("developmentVersion") == (repo / "VERSION").read_text().strip(),
            "Development version does not match VERSION")
    manifest = local_file(repo, "Documentation/COMMON_CONTRACT_SHA256.txt")
    require(sha256(manifest) == checklist.get("contractManifestSHA256"),
            "Contract manifest hash changed")
    contract_names = set()
    for line in manifest.read_text().splitlines():
        digest, name = line.split()
        require(name in CONTRACT_FILES and name not in contract_names,
                "Unexpected or duplicate contract file")
        require(sha256(local_file(repo, "Documentation/" + name)) == digest,
                "Contract file hash mismatch: " + name)
        contract_names.add(name)
    require(contract_names == CONTRACT_FILES, "Incomplete common contract")

    groups = checklist.get("sourceGroups")
    require(isinstance(groups, dict) and "runtime" in groups, "Missing runtime source group")
    digests = {}
    for name, group in groups.items():
        require(isinstance(group, dict) and isinstance(group.get("includes"), list)
                and bool(group["includes"]), "Empty source inventory: " + name)
        if name == "runtime":
            require(group["includes"] == RUNTIME_INCLUDES, "Runtime inventory scope changed")
        actual = {}
        for pattern in group["includes"]:
            require(isinstance(pattern, str) and pattern and not Path(pattern).is_absolute()
                    and ".." not in Path(pattern).parts, "Invalid source pattern")
            matches = [p for p in repo.glob(pattern) if p.is_file()]
            require(bool(matches), "Source pattern matches no files: " + pattern)
            for path in matches:
                relative = str(path.relative_to(repo))
                actual[relative] = sha256(local_file(repo, relative))
        require(actual == group.get("files"), "Source inventory changed: " + name)
        digest = inventory_digest(actual)
        require(digest == group.get("sha256"), "Source inventory digest mismatch: " + name)
        digests[name] = digest

    gates = checklist.get("gates")
    require(isinstance(gates, list), "Missing gate list")
    identifiers = set()
    for gate in gates:
        require(isinstance(gate, dict), "Invalid gate")
        identifier = gate.get("id")
        require(isinstance(identifier, str) and identifier not in identifiers, "Duplicate/missing gate ID")
        identifiers.add(identifier)
        require(gate.get("required") is True, "A required gate cannot be waived: " + identifier)
        require(gate.get("phase") in ("preparation", "stable"), "Unknown gate phase: " + identifier)
        if identifier in REQUIRED:
            require(gate["phase"] == REQUIRED[identifier], "Required gate phase changed: " + identifier)
        require(gate.get("status") in ("passed", "pending", "unavailable", "failed"),
                "Unknown gate status: " + identifier)
        for field in ("title", "reason"):
            require(isinstance(gate.get(field), str) and gate[field].strip(),
                    "Missing " + field + ": " + identifier)
        source_groups = gate.get("sourceGroups")
        require(isinstance(source_groups, list) and bool(source_groups)
                and "runtime" in source_groups
                and len(set(source_groups)) == len(source_groups)
                and all(name in digests for name in source_groups),
                "Missing/unknown gate source group: " + identifier)
        evidence = gate.get("evidence")
        require(isinstance(evidence, list) and bool(evidence), "Missing evidence: " + identifier)
        bindings = set()
        passing_report = False
        for item in evidence:
            require(isinstance(item, dict), "Invalid evidence item: " + identifier)
            path = local_file(repo, item.get("path"))
            if "sha256" in item:
                require(sha256(path) == item["sha256"], "Evidence hash mismatch: " + item["path"])
            if "line" in item:
                require(type(item["line"]) is int and 1 <= item["line"] <= len(path.read_text().splitlines()),
                        "Invalid evidence line: " + item["path"])
            if any(key in item for key in ("resultPointer", "sourceBindings", "jsonChecks")):
                document = json.loads(path.read_text())
                passed = False
                if "resultPointer" in item:
                    require(bool(re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", ""))),
                            "Passing evidence needs a pinned SHA-256: " + item["path"])
                    require(pointer(document, item["resultPointer"]) == "passed",
                            "Evidence result is not passed: " + item["path"])
                    passed = True
                    passing_report = True
                for name, location in item.get("sourceBindings", {}).items():
                    require(name in source_groups, "Undeclared evidence source group")
                    require(pointer(document, location) == digests[name],
                            "Evidence source binding mismatch: " + name)
                    if passed:
                        bindings.add(name)
                for check in item.get("jsonChecks", []):
                    actual = pointer(document, check["pointer"])
                    expected = check["equals"]
                    require(type(actual) is type(expected) and actual == expected,
                            "Evidence property mismatch: " + check["pointer"])
        if gate["status"] == "passed":
            require(passing_report and bindings == set(source_groups),
                    "Passed gate lacks a passing source-bound report: " + identifier)
    require(set(REQUIRED) <= identifiers,
            "Missing required gates: " + ", ".join(sorted(set(REQUIRED) - identifiers)))
    # A task exclusion is not a stable-release waiver. The owner's 4 November
    # instruction excludes only physical-device execution from this assignment.
    scope = checklist.get("taskScope", {})
    excluded = scope.get("excludedGates", [])
    require(isinstance(excluded, list) and excluded in ([], ["M4-PHYSICAL-DEVICES"]),
            "Only physical-device testing may be excluded from the assigned task")
    if excluded:
        require(scope.get("ownerInstruction") == "complete all the milestone 5 except the physical device testing."
                and scope.get("recordedDate") == "2026-11-04",
                "Task exclusion needs the recorded owner instruction")
    blocked = [gate["id"] for gate in gates if gate["status"] != "passed"]
    preparation_complete = all(gate["status"] == "passed" for gate in gates
                               if gate["phase"] == "preparation")
    return {"schemaVersion": 1, "status": "blocked" if blocked else "ready",
            "checklistValid": True, "preparationComplete": preparation_complete,
            "stableReleaseReady": not blocked, "publicationAuthorised": False,
            "assignedTaskComplete": not any(identifier not in excluded for identifier in blocked),
            "excludedFromAssignedTask": excluded,
            "sourceGroupDigests": digests, "blockedGates": blocked,
            "gateStatuses": {gate["id"]: gate["status"] for gate in gates}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--checklist", type=Path,
                        default=Path("Documentation/Engineering/Release/release-gates.json"))
    parser.add_argument("--output", type=Path)
    readiness = parser.add_mutually_exclusive_group()
    readiness.add_argument("--require-ready", action="store_true")
    readiness.add_argument("--require-assigned-complete", action="store_true",
                           help="Require every assigned gate, keeping physical-device exclusion separate from release readiness")
    args = parser.parse_args()
    repo = args.repo.resolve()
    checklist = args.checklist if args.checklist.is_absolute() else repo / args.checklist
    try:
        result = audit(repo, json.loads(checklist.read_text()))
        blocked = ((args.require_ready and not result["stableReleaseReady"]) or
                   (args.require_assigned_complete and not result["assignedTaskComplete"]))
        code = 2 if blocked else 0
    except (ValueError, TypeError, KeyError, IndexError, OSError, AttributeError) as error:
        result = {"schemaVersion": 1, "status": "invalid", "checklistValid": False,
                  "preparationComplete": False, "stableReleaseReady": False,
                  "assignedTaskComplete": False,
                  "publicationAuthorised": False, "error": str(error)}
        code = 1
    output = json.dumps(result, indent=2) + "\n"
    if args.output:
        if args.output.resolve() == checklist.resolve():
            print("Output must not overwrite checklist", file=sys.stderr)
            return 1
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output)
    sys.stdout.write(output)
    return code


if __name__ == "__main__":
    sys.exit(main())
