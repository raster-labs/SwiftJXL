#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Execute and audit the full SwiftJXL library test suite on an iOS Simulator.

Uses official Xcode test bundle execution (`xcodebuild test -scheme SwiftJXL-Package`)
against a disposable CoreSimulator device with task-local DerivedData and xcresult
bundles. Enforces fail-closed acceptance across:
- Complete expected test identity set (365 baseline macOS declarations minus the 6
  explicit `#if os(macOS) || os(Linux)` exclusions = 359 declarations).
- Exact declaration (359) and recursive leaf case (1,955) counts consistently across
  `xcresult` summary, `xcresult` test tree (counting `Repetition` leaves under
  `Arguments`), and console output, with all leaf IDs and results preserved.
- Zero failures, zero skips, and zero expected failures.
- Actual simulator device runtime version/build and architecture (`arm64`) matching
  the selected runtime.
- Sanitizer compiler/runtime instrumentation (`-sanitize=address` / `-sanitize=thread`)
  when `asan` or `tsan` configurations are requested.
- Explicit `SWIFTJXL_ARM_RECIPROCAL_VECTORS` binding (45,826 vectors) and negative
  sentinel proof (`missing_file_path`, `short_vector_count_below_40000`,
  `corrupted_vector_bitpattern`).
- For live runs: contemporaneous pre/post source/test/fixture/Package.swift/runner
  SHA-256 non-drift, non-empty built artifact and `.SwiftFileList` bindings captured
  before `DerivedData` removal, and disposable simulator cleanup verification.
- For offline historical re-audits (`--audit-existing`): preserves the original
  execution report bytes (`report.original.json`) and original timestamps/hashes,
  records auditor identity and timestamp in a separate `reaudit` block, and marks
  any uncaptured historical runner/binary hashes explicitly as unknown/not-captured
  rather than fabricating contemporaneous bindings.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse
import uuid
from collections import Counter
from typing import Any


CONFIG_SPECS: dict[str, dict[str, Any]] = {
    "release": {
        "xcodeConfiguration": "Release",
        "extraArgs": ["ENABLE_TESTABILITY=YES"],
        "sanitizers": [],
    },
    "debug": {
        "xcodeConfiguration": "Debug",
        "extraArgs": [],
        "sanitizers": [],
    },
    "asan": {
        "xcodeConfiguration": "Debug",
        "extraArgs": ["-enableAddressSanitizer", "YES"],
        "sanitizers": ["address"],
    },
    "tsan": {
        "xcodeConfiguration": "Debug",
        "extraArgs": ["-enableThreadSanitizer", "YES"],
        "sanitizers": ["thread"],
    },
}

EXPECTED_MACOS_ONLY_DECLARATIONS: list[dict[str, Any]] = [
    {
        "identity": "SwiftJXLCoreTests.JPEGBridgeFrameTests/nativeFrameAndMetadataRestoreWithIndependentDecoder(_:)",
        "suite": "JPEGBridgeFrameTests",
        "declaration": "nativeFrameAndMetadataRestoreWithIndependentDecoder(_:)",
        "file": "Tests/SwiftJXLCoreTests/JPEGBridgeFrameTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Spawns external libjxl djxl/cjxl reference executables via Foundation.Process, which is unavailable on iOS.",
        "macOSCases": 19,
    },
    {
        "identity": "SwiftJXLCoreTests.JPEGReconstructionMetadataTests/independentDecoderReconstructsEveryOriginalByte(_:)",
        "suite": "JPEGReconstructionMetadataTests",
        "declaration": "independentDecoderReconstructsEveryOriginalByte(_:)",
        "file": "Tests/SwiftJXLCoreTests/JPEGReconstructionMetadataTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Spawns external libjxl djxl reference executable via Foundation.Process, which is unavailable on iOS.",
        "macOSCases": 23,
    },
    {
        "identity": "SwiftJXLCoreTests.ModularGroupBoundaryTests/twoDimensionalGroupsAndDCBoundaries(_:)",
        "suite": "ModularGroupBoundaryTests",
        "declaration": "twoDimensionalGroupsAndDCBoundaries(_:)",
        "file": "Tests/SwiftJXLCoreTests/ModularGroupBoundaryTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Suite guarded by #if os(macOS) || os(Linux) for 4 GiB workspace / 6 GiB memory boundary stress and optional cjxl subprocess oracle.",
        "macOSCases": 15,
    },
    {
        "identity": "SwiftJXLCoreTests.ModularGroupBoundaryTests/defaultWorkspaceStillRefusesLargeProfiles(_:)",
        "suite": "ModularGroupBoundaryTests",
        "declaration": "defaultWorkspaceStillRefusesLargeProfiles(_:)",
        "file": "Tests/SwiftJXLCoreTests/ModularGroupBoundaryTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Suite guarded by #if os(macOS) || os(Linux) alongside twoDimensionalGroupsAndDCBoundaries.",
        "macOSCases": 4,
    },
    {
        "identity": "SwiftJXLCoreTests.NativeTranscoderPublicTests/independentPublicInteroperability(_:)",
        "suite": "NativeTranscoderPublicTests",
        "declaration": "independentPublicInteroperability(_:)",
        "file": "Tests/SwiftJXLCoreTests/NativeTranscoderPublicTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Spawns external libjxl djxl/cjxl reference executables via Foundation.Process, which is unavailable on iOS.",
        "macOSCases": 27,
    },
    {
        "identity": "SwiftJXLCoreTests.ScalarOracleTests/independentBothDirections(bits:)",
        "suite": "ScalarOracleTests",
        "declaration": "independentBothDirections(bits:)",
        "file": "Tests/SwiftJXLCoreTests/ScalarOracleTests.swift",
        "condition": "#if os(macOS) || os(Linux)",
        "reason": "Spawns external libjxl djxl/cjxl reference executables via Foundation.Process, which is unavailable on iOS.",
        "macOSCases": 5,
    },
]

EXCLUDED_IDENTITIES: set[str] = {d["identity"] for d in EXPECTED_MACOS_ONLY_DECLARATIONS}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_source_hashes(repo_root: pathlib.Path) -> dict[str, str]:
    manifest: dict[str, str] = {}
    for sub in ("Sources", "Tests"):
        base = repo_root / sub
        for path in sorted(p for p in base.rglob("*") if p.is_file() and p.name != ".DS_Store"):
            rel = path.relative_to(repo_root).as_posix()
            manifest[rel] = sha256_file(path)
    return manifest


def load_expected_identities(baseline_report_path: pathlib.Path) -> set[str]:
    data = json.loads(baseline_report_path.read_text())
    inventory = set(data["testInventory"])
    if len(inventory) != 365:
        raise RuntimeError(f"Expected 365 baseline macOS test identities in {baseline_report_path}, found {len(inventory)}")
    overlap = inventory & EXCLUDED_IDENTITIES
    if len(overlap) != 6:
        raise RuntimeError(f"Expected all 6 macOS/Linux-only exclusions in baseline inventory, found {len(overlap)}")
    expected = inventory - EXCLUDED_IDENTITIES
    if len(expected) != 359:
        raise RuntimeError(f"Expected 359 iOS test identities after exclusions, found {len(expected)}")
    return expected


def parse_version(ver: str) -> tuple[int, ...]:
    return tuple(int(x) for x in ver.split("."))


def node_identity(node: dict[str, Any]) -> str:
    url = node.get("nodeIdentifierURL", "")
    parts = urllib.parse.unquote(urllib.parse.urlsplit(url).path).strip("/").split("/")[1:]
    if not parts:
        return ""
    return parts[0] + "." + "/".join(parts[1:])


def iter_execution_leaves(node: dict[str, Any]):
    children = node.get("children", [])
    if children:
        for child in children:
            yield from iter_execution_leaves(child)
    else:
        yield node


def parse_console_log(text: str) -> dict[str, Any]:
    clean = re.sub(r"[\u200b\r]", "", text)
    decl_started = 0
    decl_passed = 0
    decl_failed = 0
    param_cases_started = 0
    cases_passed_total = 0
    bundle_runs: list[dict[str, Any]] = []
    arm_decl_cases: int | None = None
    reciprocal_vec_passed = False
    reciprocal_vec_seconds: float | None = None

    for line in clean.splitlines():
        s = line.strip()
        if re.match(r"^◇ Test .+ started\.$", s) and not s.startswith("◇ Test run started.") and not s.startswith("◇ Test case passing "):
            decl_started += 1
        m_param = re.match(r"^◇ Test case passing .+ to (.+) started\.$", s)
        if m_param:
            param_cases_started += 1
        m_pass_multi = re.match(r"^✔ Test (.+) with (\d+) test cases? passed after ([0-9.]+) seconds\.$", s)
        if m_pass_multi:
            decl_passed += 1
            c_count = int(m_pass_multi.group(2))
            cases_passed_total += c_count
            if m_pass_multi.group(1) == "retainedHistoricalIntegerOracle(_:)":
                arm_decl_cases = c_count
            continue
        m_pass_single = re.match(r"^✔ Test (.+) passed after ([0-9.]+) seconds\.$", s)
        if m_pass_single and not s.startswith("✔ Test run with "):
            decl_passed += 1
            cases_passed_total += 1
            if m_pass_single.group(1) == "optionalFullRangeHardwareReciprocalVectors()":
                reciprocal_vec_passed = True
                reciprocal_vec_seconds = float(m_pass_single.group(2))
            continue
        if re.match(r"^✘ Test .+ failed after ", s) and not s.startswith("✘ Test run with "):
            decl_failed += 1
        m_run = re.match(r"^✔ Test run with (\d+) tests? in (\d+) suites? passed after ([0-9.]+) seconds\.$", s)
        if m_run:
            bundle_runs.append({
                "tests": int(m_run.group(1)),
                "suites": int(m_run.group(2)),
                "seconds": float(m_run.group(3)),
            })

    return {
        "declarationsStarted": decl_started,
        "declarationsPassed": decl_passed,
        "declarationsFailed": decl_failed,
        "parameterisedCasesStarted": param_cases_started,
        "totalCasesPassed": cases_passed_total,
        "bundleRuns": bundle_runs,
        "bundleDeclarationsTotal": sum(b["tests"] for b in bundle_runs),
        "bundleSuitesTotal": sum(b["suites"] for b in bundle_runs),
        "armIntegerOracleCases": arm_decl_cases,
        "optionalFullRangeHardwareReciprocalVectorsPassed": reciprocal_vec_passed,
        "optionalFullRangeHardwareReciprocalVectorsSeconds": reciprocal_vec_seconds,
    }


def parse_build_bindings_from_log(repo_root: pathlib.Path, log_text: str) -> dict[str, Any]:
    prefix = str(repo_root.resolve()) + "/"
    compiled_files: set[str] = set()
    copied_resources: set[str] = set()
    module_names: set[str] = set()
    linked_bundles: set[str] = set()

    for line in log_text.splitlines():
        if "builtin-Swift-Compilation" in line:
            m_mod = re.search(r"-module-name\s+([^\s]+)", line)
            if m_mod:
                module_names.add(m_mod.group(1))
        if line.startswith("SwiftCompile normal arm64 ") or line.startswith("CompileSwift normal arm64 "):
            for m in re.finditer(re.escape(prefix) + r"((?:Sources|Tests)/[^\s]+\.swift)", line):
                compiled_files.add(m.group(1))
        if line.startswith("CpResource ") or line.startswith("Copy "):
            for m in re.finditer(re.escape(prefix) + r"(Tests/[^\s]+)", line):
                copied_resources.add(m.group(1))
        if "-Xlinker -bundle" in line:
            m_out = re.search(r"\s-o\s+([^\s]+\.xctest/[^\s]+)", line)
            if m_out:
                linked_bundles.add(pathlib.Path(m_out.group(1)).name)

    return {
        "compiledSwiftFileCount": len(compiled_files),
        "compiledSwiftFiles": sorted(compiled_files),
        "copiedResourceDirCount": len(copied_resources),
        "copiedResourceDirs": sorted(copied_resources),
        "compiledModules": sorted(module_names),
        "linkedXCTestBinaries": sorted(linked_bundles),
    }


def record_derived_data_artifacts(
    repo_root: pathlib.Path,
    derived_data: pathlib.Path,
    cfg_dir: pathlib.Path,
) -> dict[str, Any] | None:
    if not derived_data.exists():
        return None
    products_root = derived_data / "Build" / "Products"
    intermediates_root = derived_data / "Build" / "Intermediates.noindex"

    binaries: dict[str, dict[str, Any]] = {}
    swiftmodules: dict[str, dict[str, Any]] = {}
    resource_bundles: dict[str, dict[str, Any]] = {}
    swift_file_lists: dict[str, dict[str, Any]] = {}

    if products_root.exists():
        for p in sorted(products_root.rglob("*")):
            if p.is_file():
                rel = p.relative_to(derived_data).as_posix()
                if p.parent.suffix == ".xctest" and p.name == p.parent.stem:
                    binaries[rel] = {"sha256": sha256_file(p), "sizeBytes": p.stat().st_size}
                elif p.suffix == ".swiftmodule":
                    swiftmodules[rel] = {"sha256": sha256_file(p), "sizeBytes": p.stat().st_size}
        for b in sorted(products_root.rglob("*.bundle")):
            if b.is_dir():
                rel = b.relative_to(derived_data).as_posix()
                files = sorted(f for f in b.rglob("*") if f.is_file())
                h = hashlib.sha256()
                for f in files:
                    h.update(f.relative_to(b).as_posix().encode("utf-8"))
                    h.update(sha256_file(f).encode("ascii"))
                resource_bundles[rel] = {
                    "fileCount": len(files),
                    "aggregateSHA256": h.hexdigest(),
                }

    prefix = str(repo_root.resolve()) + "/"
    if intermediates_root.exists():
        for fl in sorted(intermediates_root.rglob("*.SwiftFileList")):
            if fl.is_file():
                rel = fl.relative_to(derived_data).as_posix()
                raw = fl.read_text(errors="replace")
                entries = [
                    line.strip().strip('"').replace(prefix, "")
                    for line in raw.splitlines()
                    if line.strip()
                ]
                swift_file_lists[rel] = {
                    "sha256": sha256_file(fl),
                    "entryCount": len(entries),
                    "entries": entries,
                }

    payload = {
        "xctestBinaries": binaries,
        "swiftmodules": swiftmodules,
        "resourceBundles": resource_bundles,
        "swiftFileLists": swift_file_lists,
    }
    (cfg_dir / "build-artifacts.json").write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def parse_xcresult_tree(tests_obj: dict[str, Any]) -> dict[str, Any]:
    bundles: dict[str, dict[str, Any]] = {}
    declarations: list[dict[str, Any]] = []
    all_leaf_cases: list[dict[str, Any]] = []
    total_cases = 0
    passed_cases = 0
    failed_cases = 0
    skipped_cases = 0

    def walk(node: dict[str, Any], current_bundle: str | None = None, current_suite: str | None = None) -> None:
        nonlocal total_cases, passed_cases, failed_cases, skipped_cases
        ntype = node.get("nodeType")
        name = node.get("name", "")
        if ntype == "Unit test bundle":
            current_bundle = name
            bundles.setdefault(name, {"declarations": 0, "cases": 0, "passedCases": 0, "failedCases": 0, "skippedCases": 0, "suites": set()})
        elif ntype == "Test Suite":
            current_suite = name
            if current_bundle and current_bundle in bundles:
                bundles[current_bundle]["suites"].add(name)
        elif ntype == "Test Case":
            ident = node_identity(node)
            children = node.get("children", [])
            arg_nodes = [c for c in children if c.get("nodeType") == "Arguments"]
            if arg_nodes:
                leaves = [leaf for arg in arg_nodes for leaf in iter_execution_leaves(arg)]
            else:
                leaves = [node]

            c_count = len(leaves)
            c_passed = sum(1 for lf in leaves if lf.get("result") == "Passed")
            c_failed = sum(1 for lf in leaves if lf.get("result") == "Failed")
            c_skipped = sum(1 for lf in leaves if lf.get("result") == "Skipped")

            leaf_records = [
                {
                    "name": lf.get("name"),
                    "nodeType": lf.get("nodeType"),
                    "nodeIdentifierURL": lf.get("nodeIdentifierURL"),
                    "result": lf.get("result"),
                    "durationInSeconds": lf.get("durationInSeconds"),
                }
                for lf in leaves
            ]
            all_leaf_cases.extend(leaf_records)

            total_cases += c_count
            passed_cases += c_passed
            failed_cases += c_failed
            skipped_cases += c_skipped
            if current_bundle and current_bundle in bundles:
                bundles[current_bundle]["declarations"] += 1
                bundles[current_bundle]["cases"] += c_count
                bundles[current_bundle]["passedCases"] += c_passed
                bundles[current_bundle]["failedCases"] += c_failed
                bundles[current_bundle]["skippedCases"] += c_skipped
            declarations.append({
                "identity": ident,
                "bundle": current_bundle,
                "suite": current_suite,
                "name": name,
                "nodeIdentifier": node.get("nodeIdentifier"),
                "nodeIdentifierURL": node.get("nodeIdentifierURL"),
                "result": node.get("result"),
                "durationInSeconds": node.get("durationInSeconds"),
                "caseCount": c_count,
                "passedCases": c_passed,
                "failedCases": c_failed,
                "skippedCases": c_skipped,
                "leaves": leaf_records,
            })
            return

        for child in node.get("children", []):
            walk(child, current_bundle, current_suite)

    for root_node in tests_obj.get("testNodes", []):
        walk(root_node)

    serialisable_bundles = {
        k: {
            "declarations": v["declarations"],
            "suites": len(v["suites"]),
            "cases": v["cases"],
            "passedCases": v["passedCases"],
            "failedCases": v["failedCases"],
            "skippedCases": v["skippedCases"],
        }
        for k, v in bundles.items()
    }
    return {
        "bundles": serialisable_bundles,
        "declarationsCount": len(declarations),
        "totalCases": total_cases,
        "passedCases": passed_cases,
        "failedCases": failed_cases,
        "skippedCases": skipped_cases,
        "declarations": declarations,
        "leafCases": all_leaf_cases,
    }


def evaluate_run_acceptance(
    run_record: dict[str, Any],
    expected_identities: set[str],
    expected_runtime_version: str,
    expected_runtime_build: str,
    require_sentinels: bool,
    require_built_artifacts: bool,
    log_text: str,
    gz_bytes_match: bool,
) -> dict[str, Any]:
    tree = run_record["xcresultTree"]
    summary = run_record["summary"]
    console = run_record["consoleMetrics"]
    decls = tree["declarations"]
    leaves = tree["leafCases"]

    ids = [d["identity"] for d in decls]
    id_set = set(ids)
    leaf_urls = [lf.get("nodeIdentifierURL") for lf in leaves]
    leaf_results = Counter(lf.get("result") for lf in leaves)

    missing_ids = sorted(expected_identities - id_set)
    unexpected_ids = sorted(id_set - expected_identities)
    excluded_present = sorted(EXCLUDED_IDENTITIES & id_set)

    dev = run_record.get("device") or {}
    cfg_name = run_record.get("configuration", "")
    plain_log = log_text.replace("\\=", "=")

    if cfg_name == "asan":
        sanitizer_ok = ("-sanitize=address" in plain_log) and ("libclang_rt.asan_iossim_dynamic.dylib" in plain_log)
    elif cfg_name == "tsan":
        sanitizer_ok = ("-sanitize=thread" in plain_log) and ("libclang_rt.tsan_iossim_dynamic.dylib" in plain_log)
    else:
        sanitizer_ok = True

    sentinel_obj = run_record.get("reciprocalVectorsSentinelProof")
    if require_sentinels or sentinel_obj is not None:
        sentinels_list = (sentinel_obj or {}).get("sentinels") or []
        sentinel_ok = (
            bool(sentinel_obj)
            and sentinel_obj.get("allVerified") is True
            and len(sentinels_list) == 3
            and all(s.get("verified") is True and s.get("expectedFailureObserved") is True for s in sentinels_list)
        )
    else:
        sentinel_ok = True

    build_bindings = run_record.get("buildBindings") or {}
    built_artifacts = run_record.get("builtArtifacts") or {}
    if require_built_artifacts:
        built_artifacts_ok = (
            len(built_artifacts.get("xctestBinaries") or {}) >= 2
            and len(built_artifacts.get("swiftmodules") or {}) >= 4
            and len(built_artifacts.get("resourceBundles") or {}) >= 1
            and len(built_artifacts.get("swiftFileLists") or {}) >= 4
        )
    else:
        built_artifacts_ok = True

    checks: dict[str, Any] = {
        "exitCodeZero": run_record.get("exitCode") == 0,
        "exactIdentitySet": id_set == expected_identities and len(missing_ids) == 0 and len(unexpected_ids) == 0,
        "noExcludedMacOSIdentitiesPresent": len(excluded_present) == 0,
        "noDuplicateDeclarations": len(id_set) == len(ids),
        "noDuplicateCases": len(set(leaf_urls)) == len(leaf_urls) and None not in leaf_urls,
        "expectedDeclarationCount": len(ids) == 359,
        "expectedCaseCount": len(leaves) == 1955,
        "allCasesPassed": dict(leaf_results) == {"Passed": 1955} and tree["failedCases"] == 0 and tree["skippedCases"] == 0,
        "allDeclarationsPassed": all(d.get("result") == 'Passed' for d in decls),
        "consoleDeclarationsAgree": console.get("declarationsPassed") == 359 and console.get("declarationsFailed") == 0,
        "consoleCasesAgree": console.get("totalCasesPassed") == 1955,
        "summaryPassed": summary.get("totalDeclarations") == 359 and run_record.get("result") == "Passed",
        "summaryCountsAgree": (
            summary.get("totalDeclarations") == 359
            and summary.get("passedDeclarations") == 359
            and summary.get("passedCasesInDeviceSummary") == 1955
        ),
        "summaryNoFailuresOrSkips": (
            summary.get("failedDeclarations") == 0
            and summary.get("skippedDeclarations") == 0
            and summary.get("expectedFailures") == 0
            and summary.get("failedCasesInDeviceSummary") == 0
            and summary.get("skippedCasesInDeviceSummary") == 0
        ),
        "macOS365Minus6ExcludedEquals359": len(ids) + len(EXPECTED_MACOS_ONLY_DECLARATIONS) == 365,
        "macOS2048Minus93ExcludedEquals1955": len(leaves) + sum(d["macOSCases"] for d in EXPECTED_MACOS_ONLY_DECLARATIONS) == 2048,
        "correctRuntime": (
            dev.get("platform") == "iOS Simulator"
            and dev.get("architecture") == "arm64"
            and dev.get("osVersion") == expected_runtime_version
            and dev.get("osBuildNumber") == expected_runtime_build
        ),
        "sanitizerInstrumented": sanitizer_ok,
        "armInteger123CasesExecuted": console.get("armIntegerOracleCases") == 123,
        "reciprocalVectorsTestPassed": console.get("optionalFullRangeHardwareReciprocalVectorsPassed") is True,
        "reciprocalSentinelProofVerified": sentinel_ok,
        "compiledAll200SwiftFiles": build_bindings.get("compiledSwiftFileCount") == 200,
        "logArchiveIdentical": gz_bytes_match,
    }
    if require_built_artifacts:
        checks["builtArtifactsCapturedBeforeCleanup"] = built_artifacts_ok

    failed_checks = [k for k, v in checks.items() if not v]
    return {
        "passed": len(failed_checks) == 0,
        "requireBuiltArtifacts": require_built_artifacts,
        "contemporaneousBuiltArtifactsStatus": (
            "captured" if built_artifacts else "not_captured_in_historical_run"
        ),
        "checks": checks,
        "failedChecks": failed_checks,
        "missingTestIdentities": missing_ids,
        "unexpectedTestIdentities": unexpected_ids,
    }


def evaluate_report_acceptance(
    report: dict[str, Any],
    is_reaudit: bool = False,
    reaudited_evaluation: bool = False,
) -> dict[str, Any]:
    runs = report.get("runs") or []
    run_checks = {
        r["configuration"]: r.get("acceptance", {}).get("passed", False)
        for r in runs
    }
    vec = report.get("armReciprocalVectors") or {}
    checks: dict[str, Any] = {
        "hasExecutedRuns": len(runs) > 0,
        "allRunsAccepted": len(runs) > 0 and all(run_checks.values()),
        "sourceManifestCount1195": report.get("sourceManifestCount") == 1195,
        "noSourceDrift": report.get("sourceDriftDetected") is False,
        "packageSwiftUnchanged": (
            bool(report.get("packageSwiftSHA256"))
            and report.get("packageSwiftSHA256") == report.get("packageSwiftSHA256After")
        ),
        "armReciprocalVectorsCount45826": vec.get("vectorCount") == 45826 and bool(vec.get("sha256")),
        "disposableSimulatorCleanedUp": (
            report.get("disposableSimulatorAbsentAfterCleanup") is True
            and (report.get("cleanup") or {}).get("deleteExit") == 0
        ),
    }
    if not is_reaudit:
        checks["contemporaneousPreAndPostManifestsRecorded"] = (
            bool(report.get("sourceManifestBeforeSHA256"))
            and bool(report.get("sourceManifestAfterSHA256"))
            and bool(report.get("sourceSHA256Before"))
            and bool(report.get("sourceSHA256After"))
            and report.get("sourceSHA256Before") == report.get("sourceSHA256After")
        )
        checks["runnerHashRecordedAndUnchanged"] = (
            bool(report.get("runnerSHA256"))
            and bool(report.get("runnerSHA256After"))
            and report.get("runnerSHA256") == report.get("runnerSHA256After")
        )
        checks["armReciprocalVectorsUnchanged"] = (
            bool(vec.get("sha256Before"))
            and bool(vec.get("sha256After"))
            and vec.get("sha256Before") == vec.get("sha256After")
        )
        checks["builtArtifactsRecordedForAllRuns"] = all(
            bool(r.get("builtArtifacts"))
            and len((r.get("builtArtifacts") or {}).get("xctestBinaries") or {}) >= 2
            for r in runs
        )

    failed_checks = [k for k, v in checks.items() if not v]
    if is_reaudit:
        eval_mode = "historical_reaudit"
    elif reaudited_evaluation:
        eval_mode = "reaudited_with_contemporaneous_bindings"
    else:
        eval_mode = "contemporaneous_live_run"

    return {
        "passed": len(failed_checks) == 0,
        "evaluationMode": eval_mode,
        "reaudited": bool(is_reaudit or reaudited_evaluation),
        "runnerNonDriftStatus": (
            "unknown_not_captured_at_execution"
            if is_reaudit and not report.get("runnerSHA256")
            else ("verified_unchanged" if checks.get("runnerHashRecordedAndUnchanged") else "failed_or_missing")
        ),
        "checks": checks,
        "runAcceptance": run_checks,
        "failedChecks": failed_checks,
    }


def run_reciprocal_sentinels(
    repo_root: pathlib.Path,
    work_dir: pathlib.Path,
    derived_data: pathlib.Path,
    sim_uuid: str,
    xcode_config: str,
    extra_args: list[str],
) -> dict[str, Any]:
    sentinel_dir = work_dir / "reciprocal-sentinels"
    sentinel_dir.mkdir(parents=True, exist_ok=True)

    short_json = sentinel_dir / "short-vectors.json"
    short_json.write_text("[[2, 1056931840]]\n")

    corrupt_vectors = [[2, 0]] + [[2, 1056931840]] * 39999
    corrupt_json = sentinel_dir / "corrupt-vectors.json"
    corrupt_json.write_text(json.dumps(corrupt_vectors))

    cases = [
        {
            "name": "missing_file_path",
            "envPath": "/nonexistent-arm-reciprocal-vectors.json",
            "expectedSubstrings": ["NSCocoaErrorDomain", "nonexistent-arm-reciprocal-vectors.json"],
            "proves": "TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS is delivered into ProcessInfo.processInfo.environment inside the iOS simulator runner and does not hit the missing-env early return.",
        },
        {
            "name": "short_vector_count_below_40000",
            "envPath": str(short_json),
            "expectedSubstrings": ["vectors.count >= 40_000", "VarDCTARMIntegerTests.swift:234"],
            "proves": "The simulator runner reads and JSON-decodes the file at SWIFTJXL_ARM_RECIPROCAL_VECTORS and enforces #expect(vectors.count >= 40_000).",
        },
        {
            "name": "corrupted_vector_bitpattern",
            "envPath": str(corrupt_json),
            "expectedSubstrings": ["VarDCTReferenceNumerics.reciprocalEstimate(value).bitPattern == bits", "VarDCTARMIntegerTests.swift:238"],
            "proves": "The simulator runner iterates the decoded vector pairs and evaluates VarDCTReferenceNumerics.reciprocalEstimate(value).bitPattern == bits.",
        },
    ]

    results: list[dict[str, Any]] = []
    all_verified = True
    for c in cases:
        rb = sentinel_dir / f"{c['name']}.xcresult"
        shutil.rmtree(rb, ignore_errors=True)
        env = os.environ.copy()
        env["TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = c["envPath"]
        cmd = [
            "xcodebuild",
            "test-without-building",
            "-scheme",
            "SwiftJXL-Package",
            "-configuration",
            xcode_config,
            *extra_args,
            "-destination",
            f"platform=iOS Simulator,id={sim_uuid}",
            "-derivedDataPath",
            str(derived_data),
            "-resultBundlePath",
            str(rb),
            "-only-testing:SwiftJXLCoreTests/VarDCTARMIntegerTests/optionalFullRangeHardwareReciprocalVectors()",
            "-parallel-testing-enabled",
            "NO",
        ]
        started = utc_now()
        t0 = dt.datetime.now(dt.timezone.utc)
        proc = subprocess.run(cmd, cwd=repo_root, env=env, text=True, capture_output=True)
        elapsed = (dt.datetime.now(dt.timezone.utc) - t0).total_seconds()
        combined = proc.stdout + "\n" + proc.stderr
        log_path = sentinel_dir / f"{c['name']}.log"
        log_path.write_text(combined)
        matched = [s for s in c["expectedSubstrings"] if s in combined]
        verified = (proc.returncode != 0) and (len(matched) == len(c["expectedSubstrings"]))
        if not verified:
            all_verified = False
        shutil.rmtree(rb, ignore_errors=True)
        results.append({
            "name": c["name"],
            "injectedPath": c["envPath"],
            "startedAtUTC": started,
            "seconds": elapsed,
            "exitCode": proc.returncode,
            "expectedFailureObserved": proc.returncode != 0,
            "expectedSubstrings": c["expectedSubstrings"],
            "matchedSubstrings": matched,
            "verified": verified,
            "proves": c["proves"],
            "logSHA256": sha256_file(log_path),
        })

    return {
        "allVerified": all_verified,
        "sentinels": results,
    }


def run_validator_self_test(
    report: dict[str, Any],
    expected_identities: set[str],
    log_text: str,
    is_reaudit: bool = False,
) -> dict[str, Any]:
    """Verify that the fail-closed validator accepts valid evidence and rejects mutated anomalies."""
    base_run = copy.deepcopy(report["runs"][0])
    rt_ver = report["selectedRuntime"]["version"]
    rt_build = report["selectedRuntime"]["build"]

    scenarios: list[dict[str, Any]] = []

    # 1. Unmodified valid run + report
    valid_run_acc = evaluate_run_acceptance(
        base_run, expected_identities, rt_ver, rt_build, True, not is_reaudit, log_text, True
    )
    valid_rep = copy.deepcopy(report)
    valid_rep["runs"][0]["acceptance"] = valid_run_acc
    valid_rep_acc = evaluate_report_acceptance(valid_rep, is_reaudit=is_reaudit)
    scenarios.append({
        "scenario": "baseline_valid_record",
        "expectedPassed": True,
        "actualPassed": valid_run_acc["passed"] and valid_rep_acc["passed"],
        "failedChecks": valid_run_acc["failedChecks"] + valid_rep_acc["failedChecks"],
    })

    # 2. Missing one test identity
    mut_missing = copy.deepcopy(base_run)
    mut_missing["xcresultTree"]["declarations"] = mut_missing["xcresultTree"]["declarations"][:-1]
    acc_missing = evaluate_run_acceptance(
        mut_missing, expected_identities, rt_ver, rt_build, True, False, log_text, True
    )
    scenarios.append({
        "scenario": "missing_test_identity",
        "expectedPassed": False,
        "actualPassed": acc_missing["passed"],
        "failedChecks": acc_missing["failedChecks"],
    })

    # 3. Single leaf test case failure
    mut_fail = copy.deepcopy(base_run)
    mut_fail["xcresultTree"]["leafCases"][0]["result"] = "Failed"
    acc_fail = evaluate_run_acceptance(
        mut_fail, expected_identities, rt_ver, rt_build, True, False, log_text, True
    )
    scenarios.append({
        "scenario": "single_case_failure",
        "expectedPassed": False,
        "actualPassed": acc_fail["passed"],
        "failedChecks": acc_fail["failedChecks"],
    })

    # 4. Sentinel verification failure
    mut_sent = copy.deepcopy(base_run)
    mut_sent["reciprocalVectorsSentinelProof"]["allVerified"] = False
    acc_sent = evaluate_run_acceptance(
        mut_sent, expected_identities, rt_ver, rt_build, True, False, log_text, True
    )
    scenarios.append({
        "scenario": "sentinel_proof_failure",
        "expectedPassed": False,
        "actualPassed": acc_sent["passed"],
        "failedChecks": acc_sent["failedChecks"],
    })

    # 5. Runtime version mismatch
    mut_rt = copy.deepcopy(base_run)
    mut_rt["device"]["osVersion"] = "25.0" if rt_ver == "26.0" else "26.0"
    acc_rt = evaluate_run_acceptance(
        mut_rt, expected_identities, rt_ver, rt_build, True, False, log_text, True
    )
    scenarios.append({
        "scenario": "device_runtime_mismatch",
        "expectedPassed": False,
        "actualPassed": acc_rt["passed"],
        "failedChecks": acc_rt["failedChecks"],
    })

    # 6. Sanitizer flag missing on ASan run
    mut_san = copy.deepcopy(base_run)
    mut_san["configuration"] = "asan"
    acc_san = evaluate_run_acceptance(
        mut_san, expected_identities, rt_ver, rt_build, True, False, log_text, True
    )
    scenarios.append({
        "scenario": "missing_asan_instrumentation",
        "expectedPassed": False,
        "actualPassed": acc_san["passed"],
        "failedChecks": acc_san["failedChecks"],
    })

    # 7. Source drift detected at report level
    mut_drift = copy.deepcopy(valid_rep)
    mut_drift["sourceDriftDetected"] = True
    acc_drift = evaluate_report_acceptance(mut_drift, is_reaudit=is_reaudit)
    scenarios.append({
        "scenario": "source_drift_detected",
        "expectedPassed": False,
        "actualPassed": acc_drift["passed"],
        "failedChecks": acc_drift["failedChecks"],
    })

    # 8. Live run missing contemporaneous runner hash or built artifacts
    mut_live = copy.deepcopy(valid_rep)
    mut_live["runnerSHA256"] = None
    mut_live["runs"][0]["builtArtifacts"] = None
    acc_live = evaluate_report_acceptance(mut_live, is_reaudit=False)
    scenarios.append({
        "scenario": "live_run_missing_runner_hash_and_built_artifacts",
        "expectedPassed": False,
        "actualPassed": acc_live["passed"],
        "failedChecks": acc_live["failedChecks"],
    })

    all_passed = all(
        s["expectedPassed"] == s["actualPassed"] and (s["expectedPassed"] or len(s["failedChecks"]) > 0)
        for s in scenarios
    )
    return {
        "auditedAtUTC": utc_now(),
        "allScenariosBehavedAsExpected": all_passed,
        "scenarios": scenarios,
    }


def audit_existing_directory(
    out_dir: pathlib.Path,
    repo_root: pathlib.Path,
    baseline_report_path: pathlib.Path,
    vec_path: pathlib.Path,
    run_self_test: bool,
) -> int:
    report_path = out_dir / "report.json"
    orig_backup_path = out_dir / "report.original.json"
    if not orig_backup_path.exists():
        shutil.copy2(report_path, orig_backup_path)

    existing = json.loads(orig_backup_path.read_text())
    orig_status = existing.get("status")
    orig_acceptance = copy.deepcopy(existing.get("acceptance"))
    orig_validator_self_test = copy.deepcopy(existing.get("validatorSelfTest"))

    st_path = out_dir / "validator-self-test.json"
    st_orig_backup_path = out_dir / "validator-self-test.original.json"
    if orig_validator_self_test is not None and st_path.exists() and not st_orig_backup_path.exists():
        shutil.copy2(st_path, st_orig_backup_path)

    expected_identities = load_expected_identities(baseline_report_path)

    auditor_path = pathlib.Path(__file__).resolve()
    auditor_sha = sha256_file(auditor_path)

    # Do NOT fabricate contemporaneous pre/post manifest files if they were not created during execution
    vec_sha = sha256_file(vec_path)
    vec_data = json.loads(vec_path.read_text())
    if len(vec_data) != 45826:
        raise RuntimeError(f"Expected 45,826 vectors in {vec_path}, found {len(vec_data)}")

    # Preserve original runnerSHA256 fields as None if not captured during execution
    had_contemporaneous_runner_sha = bool(existing.get("runnerSHA256")) and bool(existing.get("runnerSHA256After"))
    if not had_contemporaneous_runner_sha:
        existing["runnerSHA256"] = None
        existing["runnerSHA256After"] = None

    existing["baselineMacOSReport"] = {
        "path": str(baseline_report_path.relative_to(repo_root).as_posix()),
        "sha256": sha256_file(baseline_report_path),
        "totalMacOSDeclarations": 365,
        "excludedMacOSDeclarations": 6,
        "expectedIOSDeclarations": 359,
    }

    rt_ver = existing["selectedRuntime"]["version"]
    rt_build = existing["selectedRuntime"]["build"]

    last_log_text = ""
    any_missing_built_artifacts = False
    for run_record in existing.get("runs", []):
        cfg_name = run_record["configuration"]
        cfg_dir = out_dir / cfg_name
        log_path = cfg_dir / "xcodebuild.log"
        gz_path = cfg_dir / "xcodebuild.log.gz"
        summary_path = cfg_dir / "summary.json"
        tests_path = cfg_dir / "tests.json"
        sentinels_path = cfg_dir / "reciprocal-sentinels.json"
        built_artifacts_path = cfg_dir / "build-artifacts.json"

        log_text = log_path.read_text(errors="replace")
        last_log_text = log_text
        gz_match = gzip.decompress(gz_path.read_bytes()) == log_path.read_bytes()
        summary_obj = json.loads(summary_path.read_text())
        tests_obj = json.loads(tests_path.read_text())
        console_metrics = parse_console_log(log_text)
        tree_metrics = parse_xcresult_tree(tests_obj)
        build_bindings = parse_build_bindings_from_log(repo_root, log_text)
        (cfg_dir / "build-bindings.json").write_text(json.dumps(build_bindings, indent=2) + "\n")

        if sentinels_path.exists():
            run_record["reciprocalVectorsSentinelProof"] = json.loads(sentinels_path.read_text())
        if built_artifacts_path.exists():
            run_record["builtArtifacts"] = json.loads(built_artifacts_path.read_text())
        else:
            run_record["builtArtifacts"] = None
            any_missing_built_artifacts = True

        dev_cfg = (summary_obj.get("devicesAndConfigurations") or [{}])[0]
        run_record["summary"] = {
            "totalDeclarations": summary_obj.get("totalTestCount"),
            "passedDeclarations": summary_obj.get("passedTests"),
            "failedDeclarations": summary_obj.get("failedTests"),
            "skippedDeclarations": summary_obj.get("skippedTests"),
            "expectedFailures": summary_obj.get("expectedFailures"),
            "passedCasesInDeviceSummary": dev_cfg.get("passedTests"),
            "failedCasesInDeviceSummary": dev_cfg.get("failedTests"),
            "skippedCasesInDeviceSummary": dev_cfg.get("skippedTests"),
            "statistics": summary_obj.get("statistics", []),
        }
        run_record["xcresultTree"] = tree_metrics
        run_record["consoleMetrics"] = console_metrics
        run_record["buildBindings"] = build_bindings
        run_record["artifacts"]["buildBindingsJsonPath"] = str(cfg_dir / "build-bindings.json")
        run_record["artifacts"]["buildBindingsJsonSHA256"] = sha256_file(cfg_dir / "build-bindings.json")

        acceptance = evaluate_run_acceptance(
            run_record=run_record,
            expected_identities=expected_identities,
            expected_runtime_version=rt_ver,
            expected_runtime_build=rt_build,
            require_sentinels=sentinels_path.exists(),
            require_built_artifacts=built_artifacts_path.exists(),
            log_text=log_text,
            gz_bytes_match=gz_match,
        )
        run_record["reconciliation"] = {
            "declarationsMatchSummaryAndTreeAndConsole": (
                acceptance["checks"]["expectedDeclarationCount"]
                and acceptance["checks"]["consoleDeclarationsAgree"]
                and acceptance["checks"]["summaryCountsAgree"]
            ),
            "casesMatchSummaryAndTreeAndConsole": (
                acceptance["checks"]["expectedCaseCount"]
                and acceptance["checks"]["consoleCasesAgree"]
                and acceptance["checks"]["summaryCountsAgree"]
            ),
            "macOS365Minus6ExcludedEquals359": acceptance["checks"]["macOS365Minus6ExcludedEquals359"],
            "macOS2048Minus93ExcludedEquals1955": acceptance["checks"]["macOS2048Minus93ExcludedEquals1955"],
            "zeroFailuresAndSkips": (
                acceptance["checks"]["allCasesPassed"]
                and acceptance["checks"]["allDeclarationsPassed"]
                and acceptance["checks"]["summaryNoFailuresOrSkips"]
            ),
        }
        run_record["acceptance"] = acceptance

    has_pre_manifest = (out_dir / "source-manifest-before.json").exists()
    has_full_contemporaneous_bindings = (
        had_contemporaneous_runner_sha and (not any_missing_built_artifacts) and has_pre_manifest
    )
    rep_acc = evaluate_report_acceptance(
        existing,
        is_reaudit=not has_full_contemporaneous_bindings,
        reaudited_evaluation=True,
    )
    if orig_status is not None:
        existing["originalStatus"] = orig_status
    if orig_acceptance is not None:
        existing["originalAcceptance"] = orig_acceptance
    existing["acceptance"] = rep_acc
    limitations: list[str] = []
    if not had_contemporaneous_runner_sha:
        limitations.append(
            "Original execution runner script SHA-256 was not captured in report.original.json at execution time (independent audit recorded runnerSHA256AtReview=ed2d4ecbc004797ba3cb1dfde8db145cee5e91259346567217dd37685963ef9b); historical runner non-drift is therefore marked unknown_not_captured_at_execution."
        )
    if any_missing_built_artifacts:
        limitations.append(
            "DerivedData built product hashes (.xctest Mach-O binaries, .swiftmodule files, and .SwiftFileList files) were not hashed before DerivedData cleanup during the initial Release run; compiled source file bindings (200 .swift files and 8 resource directories) are extracted from the retained xcodebuild.log."
        )
    existing["reaudit"] = {
        "auditedAtUTC": utc_now(),
        "auditorPath": str(auditor_path.relative_to(repo_root).as_posix()),
        "auditorSHA256": auditor_sha,
        "originalReportBackupPath": str(orig_backup_path),
        "originalReportBackupSHA256": sha256_file(orig_backup_path),
        "originalValidatorSelfTestBackupPath": str(st_orig_backup_path) if st_orig_backup_path.exists() else None,
        "originalValidatorSelfTestBackupSHA256": sha256_file(st_orig_backup_path) if st_orig_backup_path.exists() else None,
        "contemporaneousRunnerHashCaptured": had_contemporaneous_runner_sha,
        "contemporaneousDerivedDataArtifactsCaptured": not any_missing_built_artifacts,
        "contemporaneousPreRunManifestFileCaptured": has_pre_manifest,
        "runnerNonDriftStatus": (
            "verified_unchanged" if had_contemporaneous_runner_sha else "unknown_not_captured_at_execution"
        ),
        "sourceManifestProvenance": (
            "Contemporaneous pre-run and post-run source manifests, execution runner script hashes, reciprocal vector hashes, and DerivedData built artifact hashes were captured during execution."
            if has_full_contemporaneous_bindings
            else (
                "The original execution runner computed in-memory sourceSHA256 before and after execution "
                "(recording sourceDriftDetected=false across all 1,195 files) and wrote source-manifest.json at "
                "completion, but did not write a separate pre-run manifest file or record its own script hash or "
                "DerivedData binary hashes prior to removing DerivedData."
            )
        ),
        "traceabilityLimitations": limitations,
    }
    existing["status"] = "passed" if rep_acc["passed"] else "failed"

    if orig_validator_self_test is not None:
        existing["originalValidatorSelfTest"] = orig_validator_self_test

    if run_self_test and existing.get("runs"):
        st = run_validator_self_test(
            existing, expected_identities, last_log_text, is_reaudit=not has_full_contemporaneous_bindings
        )
        st_path.write_text(json.dumps(st, indent=2) + "\n")
        existing["validatorSelfTest"] = {
            "path": str(st_path),
            "sha256": sha256_file(st_path),
            "originalBackupPath": str(st_orig_backup_path) if st_orig_backup_path.exists() else None,
            "originalBackupSHA256": sha256_file(st_orig_backup_path) if st_orig_backup_path.exists() else None,
            "allScenariosBehavedAsExpected": st["allScenariosBehavedAsExpected"],
            "scenarioCount": len(st["scenarios"]),
        }
        if not st["allScenariosBehavedAsExpected"]:
            existing["status"] = "failed"

    report_path.write_text(json.dumps(existing, indent=2) + "\n")
    return 0 if existing["status"] == "passed" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2],
    )
    parser.add_argument(
        "--baseline-report",
        type=pathlib.Path,
        help="Path to baseline macOS release report containing the 365 testInventory identities.",
    )
    parser.add_argument(
        "--runtime-version",
        help="Require this exact iOS Simulator runtime version (e.g., 26.0 or 26.5).",
    )
    parser.add_argument(
        "--minimum-runtime",
        action="store_true",
        help="Require the contract deployment floor iOS 26.0 simulator runtime and record unexecuted if absent.",
    )
    parser.add_argument(
        "--configuration",
        action="append",
        choices=list(CONFIG_SPECS.keys()),
        help="Configurations to run (default: release, debug).",
    )
    parser.add_argument(
        "--device-type",
        default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        help="CoreSimulator device type identifier.",
    )
    parser.add_argument(
        "--reciprocal-vectors",
        type=pathlib.Path,
        help="Path to the 45,826-entry ARM reciprocal vectors JSON file (or set SWIFTJXL_ARM_RECIPROCAL_VECTORS).",
    )
    parser.add_argument(
        "--verify-reciprocal-sentinels",
        action="store_true",
        help="Run negative sentinel checks proving SWIFTJXL_ARM_RECIPROCAL_VECTORS delivery and evaluation inside the simulator.",
    )
    parser.add_argument(
        "--audit-existing",
        action="store_true",
        help="Re-audit retained raw artifacts in output_dir without rerunning simulator tests.",
    )
    parser.add_argument(
        "--self-test-validator",
        action="store_true",
        help="Run validator self-test against valid and mutated failure records.",
    )
    args = parser.parse_args()

    out_dir = args.output_dir.resolve()
    if not args.audit_existing and out_dir.exists() and any(out_dir.iterdir()):
        raise RuntimeError(
            f"Refusing to reuse non-empty output directory for new execution: {out_dir}. "
            "Pass --audit-existing to re-audit existing artifacts or specify a fresh directory."
        )
    out_dir.mkdir(parents=True, exist_ok=True)
    repo_root = args.repo_root.resolve()
    baseline_report_path = (
        args.baseline_report.resolve()
        if args.baseline_report
        else (repo_root / "Documentation/Engineering/Migration/Evidence/Milestone4Remaining/release-6-report.json").resolve()
    )

    vec_arg = args.reciprocal_vectors or (
        pathlib.Path(os.environ["SWIFTJXL_ARM_RECIPROCAL_VECTORS"])
        if "SWIFTJXL_ARM_RECIPROCAL_VECTORS" in os.environ
        else None
    )
    if vec_arg is None or not vec_arg.exists():
        raise RuntimeError(
            "Explicit --reciprocal-vectors path (or SWIFTJXL_ARM_RECIPROCAL_VECTORS environment variable) "
            "pointing to the 45,826-entry ARM reciprocal vectors JSON file is required."
        )
    vec_path = vec_arg.resolve()

    if args.audit_existing:
        return audit_existing_directory(
            out_dir=out_dir,
            repo_root=repo_root,
            baseline_report_path=baseline_report_path,
            vec_path=vec_path,
            run_self_test=args.self_test_validator,
        )

    expected_identities = load_expected_identities(baseline_report_path)
    target_version = "26.0" if args.minimum_runtime else args.runtime_version
    configs = args.configuration or ["release", "debug"]

    started_at = utc_now()
    t_start = dt.datetime.now(dt.timezone.utc)
    runner_path = pathlib.Path(__file__).resolve()
    runner_sha_before = sha256_file(runner_path)

    sw_vers = subprocess.check_output(["sw_vers"], text=True).strip()
    xcode_ver = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
    swift_ver = subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip()
    runtimes_raw = subprocess.check_output(["xcrun", "simctl", "runtime", "list", "-j"], text=True)
    matches_raw = subprocess.check_output(["xcrun", "simctl", "runtime", "match", "list", "-j"], text=True)
    devices_before_raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)

    (out_dir / "runtimes.json").write_text(runtimes_raw)
    (out_dir / "runtime-matches.json").write_text(matches_raw)
    (out_dir / "devices-before.json").write_text(devices_before_raw)

    runtimes_obj = json.loads(runtimes_raw)
    runtimes_list = list(runtimes_obj.values()) if isinstance(runtimes_obj, dict) else runtimes_obj

    ios_runtimes = [
        r for r in runtimes_list
        if (r.get("platform") == "iOS" or r.get("platformIdentifier") == "com.apple.platform.iphonesimulator")
    ]
    installed_ios_versions = sorted(
        [str(r.get("version")) for r in ios_runtimes if r.get("isAvailable", True) and r.get("state") == "Ready"],
        key=parse_version,
    )

    source_before = collect_source_hashes(repo_root)
    package_sha_before = sha256_file(repo_root / "Package.swift")
    head_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo_root, text=True).strip()

    pre_manifest_path = out_dir / "source-manifest-before.json"
    pre_manifest_path.write_text(
        json.dumps(
            {
                "capturedAtUTC": utc_now(),
                "gitHead": head_sha,
                "packageSwiftSHA256": package_sha_before,
                "runnerSHA256": runner_sha_before,
                "fileCount": len(source_before),
                "sourceSHA256": source_before,
            },
            indent=2,
        )
        + "\n"
    )
    pre_manifest_sha = sha256_file(pre_manifest_path)

    vec_sha_before = sha256_file(vec_path)
    vec_data = json.loads(vec_path.read_text())
    vec_count = len(vec_data)
    if vec_count != 45826:
        raise RuntimeError(f"Expected 45,826 ARM reciprocal vectors at {vec_path}, found {vec_count}")

    report: dict[str, Any] = {
        "schemaVersion": 2,
        "startedAtUTC": started_at,
        "gitHead": head_sha,
        "runnerPath": str(runner_path.relative_to(repo_root).as_posix()),
        "runnerSHA256": runner_sha_before,
        "packageSwiftSHA256": package_sha_before,
        "sourceManifestCount": len(source_before),
        "sourceManifestBeforePath": str(pre_manifest_path),
        "sourceManifestBeforeSHA256": pre_manifest_sha,
        "baselineMacOSReport": {
            "path": str(baseline_report_path.relative_to(repo_root).as_posix()),
            "sha256": sha256_file(baseline_report_path),
            "totalMacOSDeclarations": 365,
            "excludedMacOSDeclarations": 6,
            "expectedIOSDeclarations": 359,
        },
        "host": {
            "swVers": sw_vers,
            "xcodebuildVersion": xcode_ver,
            "swiftVersion": swift_ver,
        },
        "requestedRuntimeVersion": target_version,
        "minimumRuntimeCheck": bool(args.minimum_runtime),
        "installedIOSSimulatorRuntimes": [
            {
                "version": r.get("version"),
                "build": r.get("build"),
                "identifier": r.get("runtimeIdentifier") or r.get("identifier"),
                "state": r.get("state"),
                "sizeBytes": r.get("sizeBytes"),
            }
            for r in ios_runtimes
        ],
        "minimumFloorRuntime26_0Installed": "26.0" in installed_ios_versions,
        "armReciprocalVectors": {
            "path": str(vec_path),
            "sha256": vec_sha_before,
            "sha256Before": vec_sha_before,
            "vectorCount": vec_count,
        },
        "platformConditionalExclusions": {
            "condition": "#if os(macOS) || os(Linux)",
            "excludedDeclarationsCount": len(EXPECTED_MACOS_ONLY_DECLARATIONS),
            "excludedMacOSCasesCount": sum(d["macOSCases"] for d in EXPECTED_MACOS_ONLY_DECLARATIONS),
            "declarations": EXPECTED_MACOS_ONLY_DECLARATIONS,
        },
        "runs": [],
    }

    eligible = [
        r for r in ios_runtimes
        if r.get("state") == "Ready"
        and parse_version(str(r.get("version", "0.0"))) >= (26, 0)
        and (target_version is None or str(r.get("version")) == target_version)
    ]

    if not eligible:
        report["status"] = "unexecuted"
        report["reason"] = (
            f"Required iOS Simulator runtime {target_version or '>=26.0'} is not installed on this workstation "
            f"(xcrun simctl runtime list reports installed Ready iOS runtimes: {', '.join(installed_ios_versions) or 'none'})."
        )
        report["finishedAtUTC"] = utc_now()
        report["seconds"] = (dt.datetime.now(dt.timezone.utc) - t_start).total_seconds()
        (out_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        return 2

    selected_runtime = min(eligible, key=lambda r: parse_version(str(r.get("version"))))
    runtime_id = selected_runtime.get("runtimeIdentifier") or selected_runtime.get("identifier")
    runtime_ver = str(selected_runtime.get("version"))
    runtime_build = str(selected_runtime.get("build"))

    report["selectedRuntime"] = {
        "version": runtime_ver,
        "build": runtime_build,
        "identifier": runtime_id,
        "satisfiesMinimumFloor26_0": runtime_ver == "26.0",
    }

    sim_name = f"SwiftJXL-iOS-Suite-{uuid.uuid4().hex[:8]}"
    sim_uuid: str | None = None
    last_log_text = ""
    try:
        created = subprocess.check_output(
            ["xcrun", "simctl", "create", sim_name, args.device_type, runtime_id],
            text=True,
        ).strip()
        sim_uuid = str(uuid.UUID(created)).upper()
        report["disposableSimulator"] = {
            "name": sim_name,
            "uuid": sim_uuid,
            "deviceType": args.device_type,
            "runtimeIdentifier": runtime_id,
        }
        subprocess.run(["xcrun", "simctl", "boot", sim_uuid], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", sim_uuid, "-b"], check=True)

        sentinels_done = False
        for cfg_name in configs:
            spec = CONFIG_SPECS[cfg_name]
            cfg_dir = out_dir / cfg_name
            cfg_dir.mkdir(parents=True, exist_ok=True)
            derived_data = cfg_dir / "DerivedData"
            xcresult_path = cfg_dir / f"ios-{cfg_name}.xcresult"
            shutil.rmtree(xcresult_path, ignore_errors=True)

            env = os.environ.copy()
            env["TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(vec_path)

            cmd = [
                "xcodebuild",
                "test",
                "-scheme",
                "SwiftJXL-Package",
                "-configuration",
                spec["xcodeConfiguration"],
                *spec["extraArgs"],
                "-destination",
                f"platform=iOS Simulator,id={sim_uuid}",
                "-derivedDataPath",
                str(derived_data),
                "-resultBundlePath",
                str(xcresult_path),
                "-only-testing:SwiftJXLTests",
                "-only-testing:SwiftJXLCoreTests",
                "-parallel-testing-enabled",
                "NO",
            ]
            run_started = utc_now()
            t0 = dt.datetime.now(dt.timezone.utc)
            proc = subprocess.run(cmd, cwd=repo_root, env=env, text=True, capture_output=True)
            run_seconds = (dt.datetime.now(dt.timezone.utc) - t0).total_seconds()
            run_finished = utc_now()

            combined_log = proc.stdout + "\n" + proc.stderr
            last_log_text = combined_log
            log_path = cfg_dir / "xcodebuild.log"
            log_path.write_text(combined_log)
            gz_log_path = cfg_dir / "xcodebuild.log.gz"
            with gzip.open(gz_log_path, "wb", compresslevel=9) as gz:
                gz.write(combined_log.encode("utf-8"))
            gz_match = gzip.decompress(gz_log_path.read_bytes()) == log_path.read_bytes()

            summary_raw = subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(xcresult_path)],
                text=True,
            )
            tests_raw = subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult_path)],
                text=True,
            )
            summary_path = cfg_dir / "summary.json"
            tests_path = cfg_dir / "tests.json"
            summary_path.write_text(summary_raw)
            tests_path.write_text(tests_raw)

            summary_obj = json.loads(summary_raw)
            tests_obj = json.loads(tests_raw)
            console_metrics = parse_console_log(combined_log)
            tree_metrics = parse_xcresult_tree(tests_obj)
            build_bindings = parse_build_bindings_from_log(repo_root, combined_log)
            (cfg_dir / "build-bindings.json").write_text(json.dumps(build_bindings, indent=2) + "\n")
            built_artifacts = record_derived_data_artifacts(repo_root, derived_data, cfg_dir)

            sentinel_report = None
            if args.verify_reciprocal_sentinels and not sentinels_done and proc.returncode == 0:
                sentinel_report = run_reciprocal_sentinels(
                    repo_root=repo_root,
                    work_dir=cfg_dir,
                    derived_data=derived_data,
                    sim_uuid=sim_uuid,
                    xcode_config=spec["xcodeConfiguration"],
                    extra_args=spec["extraArgs"],
                )
                (cfg_dir / "reciprocal-sentinels.json").write_text(json.dumps(sentinel_report, indent=2) + "\n")
                sentinels_done = True

            shutil.rmtree(derived_data, ignore_errors=True)

            dev_cfg = (summary_obj.get("devicesAndConfigurations") or [{}])[0]
            run_record: dict[str, Any] = {
                "configuration": cfg_name,
                "xcodeConfiguration": spec["xcodeConfiguration"],
                "extraArgs": spec["extraArgs"],
                "sanitizers": spec["sanitizers"],
                "command": cmd,
                "injectedEnvironment": {
                    "TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS": str(vec_path),
                },
                "startedAtUTC": run_started,
                "finishedAtUTC": run_finished,
                "seconds": run_seconds,
                "exitCode": proc.returncode,
                "result": summary_obj.get("result"),
                "device": dev_cfg.get("device"),
                "summary": {
                    "totalDeclarations": summary_obj.get("totalTestCount"),
                    "passedDeclarations": summary_obj.get("passedTests"),
                    "failedDeclarations": summary_obj.get("failedTests"),
                    "skippedDeclarations": summary_obj.get("skippedTests"),
                    "expectedFailures": summary_obj.get("expectedFailures"),
                    "passedCasesInDeviceSummary": dev_cfg.get("passedTests"),
                    "failedCasesInDeviceSummary": dev_cfg.get("failedTests"),
                    "skippedCasesInDeviceSummary": dev_cfg.get("skippedTests"),
                    "statistics": summary_obj.get("statistics", []),
                },
                "xcresultTree": tree_metrics,
                "consoleMetrics": console_metrics,
                "buildBindings": build_bindings,
                "builtArtifacts": built_artifacts,
                "reciprocalVectorsSentinelProof": sentinel_report,
                "artifacts": {
                    "logPath": str(log_path),
                    "logSHA256": sha256_file(log_path),
                    "gzipLogPath": str(gz_log_path),
                    "gzipLogSHA256": sha256_file(gz_log_path),
                    "summaryJsonPath": str(summary_path),
                    "summaryJsonSHA256": sha256_file(summary_path),
                    "testsJsonPath": str(tests_path),
                    "testsJsonSHA256": sha256_file(tests_path),
                    "buildBindingsJsonPath": str(cfg_dir / "build-bindings.json"),
                    "buildBindingsJsonSHA256": sha256_file(cfg_dir / "build-bindings.json"),
                },
            }
            if (cfg_dir / "build-artifacts.json").exists():
                run_record["artifacts"]["buildArtifactsJsonPath"] = str(cfg_dir / "build-artifacts.json")
                run_record["artifacts"]["buildArtifactsJsonSHA256"] = sha256_file(cfg_dir / "build-artifacts.json")

            acceptance = evaluate_run_acceptance(
                run_record=run_record,
                expected_identities=expected_identities,
                expected_runtime_version=runtime_ver,
                expected_runtime_build=runtime_build,
                require_sentinels=bool(args.verify_reciprocal_sentinels and sentinel_report is not None),
                require_built_artifacts=True,
                log_text=combined_log,
                gz_bytes_match=gz_match,
            )
            run_record["reconciliation"] = {
                "declarationsMatchSummaryAndTreeAndConsole": (
                    acceptance["checks"]["expectedDeclarationCount"]
                    and acceptance["checks"]["consoleDeclarationsAgree"]
                    and acceptance["checks"]["summaryCountsAgree"]
                ),
                "casesMatchSummaryAndTreeAndConsole": (
                    acceptance["checks"]["expectedCaseCount"]
                    and acceptance["checks"]["consoleCasesAgree"]
                    and acceptance["checks"]["summaryCountsAgree"]
                ),
                "macOS365Minus6ExcludedEquals359": acceptance["checks"]["macOS365Minus6ExcludedEquals359"],
                "macOS2048Minus93ExcludedEquals1955": acceptance["checks"]["macOS2048Minus93ExcludedEquals1955"],
                "zeroFailuresAndSkips": (
                    acceptance["checks"]["allCasesPassed"]
                    and acceptance["checks"]["allDeclarationsPassed"]
                    and acceptance["checks"]["summaryNoFailuresOrSkips"]
                ),
            }
            run_record["acceptance"] = acceptance
            report["runs"].append(run_record)
            (out_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(
                f"[{utc_now()}] Configuration {cfg_name} finished in {run_seconds:.2f}s: "
                f"accepted={acceptance['passed']} declarations={tree_metrics['declarationsCount']} cases={tree_metrics['passedCases']}",
                flush=True,
            )
            if not acceptance["passed"]:
                raise RuntimeError(f"Configuration {cfg_name} failed acceptance checks: {acceptance['failedChecks']}")

    except Exception as exc:
        report["failure"] = str(exc)
        print(f"ERROR: {exc}", file=sys.stderr)
    finally:
        if sim_uuid:
            sh_res = subprocess.run(["xcrun", "simctl", "shutdown", sim_uuid], capture_output=True, text=True)
            del_res = subprocess.run(["xcrun", "simctl", "delete", sim_uuid], capture_output=True, text=True)
            report["cleanup"] = {
                "uuid": sim_uuid,
                "shutdownExit": sh_res.returncode,
                "deleteExit": del_res.returncode,
            }
        devices_after_raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)
        (out_dir / "devices-after.json").write_text(devices_after_raw)
        report["disposableSimulatorAbsentAfterCleanup"] = (
            sim_uuid not in devices_after_raw if sim_uuid else True
        )

    source_after = collect_source_hashes(repo_root)
    package_sha_after = sha256_file(repo_root / "Package.swift")
    runner_sha_after = sha256_file(runner_path)
    vec_sha_after = sha256_file(vec_path)
    report["armReciprocalVectors"]["sha256After"] = vec_sha_after
    report["armReciprocalVectors"]["unchangedDuringRun"] = vec_sha_before == vec_sha_after
    report["packageSwiftSHA256After"] = package_sha_after
    report["runnerSHA256After"] = runner_sha_after
    report["sourceDriftDetected"] = (
        (source_before != source_after)
        or (package_sha_before != package_sha_after)
        or (runner_sha_before != runner_sha_after)
        or (vec_sha_before != vec_sha_after)
    )
    report["sourceSHA256Before"] = source_before
    report["sourceSHA256After"] = source_after
    report["sourceSHA256"] = source_after

    post_manifest_path = out_dir / "source-manifest-after.json"
    post_manifest_path.write_text(
        json.dumps(
            {
                "capturedAtUTC": utc_now(),
                "gitHead": head_sha,
                "packageSwiftSHA256": package_sha_after,
                "runnerSHA256": runner_sha_after,
                "fileCount": len(source_after),
                "sourceSHA256": source_after,
            },
            indent=2,
        )
        + "\n"
    )
    report["sourceManifestAfterPath"] = str(post_manifest_path)
    report["sourceManifestAfterSHA256"] = sha256_file(post_manifest_path)

    (out_dir / "source-manifest.json").write_text(
        json.dumps(
            {
                "gitHead": head_sha,
                "packageSwiftSHA256": package_sha_after,
                "runnerSHA256": runner_sha_after,
                "fileCount": len(source_after),
                "sourceSHA256": source_after,
            },
            indent=2,
        )
        + "\n"
    )

    rep_acc = evaluate_report_acceptance(report, is_reaudit=False)
    report["acceptance"] = rep_acc
    report["status"] = "passed" if (rep_acc["passed"] and "failure" not in report) else "failed"

    if args.self_test_validator and report.get("runs"):
        st = run_validator_self_test(report, expected_identities, last_log_text, is_reaudit=False)
        st_path = out_dir / "validator-self-test.json"
        st_path.write_text(json.dumps(st, indent=2) + "\n")
        report["validatorSelfTest"] = {
            "path": str(st_path),
            "sha256": sha256_file(st_path),
            "allScenariosBehavedAsExpected": st["allScenariosBehavedAsExpected"],
            "scenarioCount": len(st["scenarios"]),
        }
        if not st["allScenariosBehavedAsExpected"]:
            report["status"] = "failed"

    report["finishedAtUTC"] = utc_now()
    report["seconds"] = (dt.datetime.now(dt.timezone.utc) - t_start).total_seconds()
    (out_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
