#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run current-source full library test bundles on disposable Apple simulators.

Xcode enumerates each instrumented test build before execution. Every discovered
identity must execute, with zero failures/skips and agreement between the console,
xcresult summary and recursive result tree. Historical iOS evidence is unchanged.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
LEGACY_PATH = Path(__file__).with_name("qualify-ios-simulator.py")
SPEC = importlib.util.spec_from_file_location("ios_result_parser", LEGACY_PATH)
PARSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARSER)

PLATFORMS = {
    "ios": ("iOS", "iOS Simulator", "iphonesimulator", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"),
    "tvos": ("tvOS", "tvOS Simulator", "appletvsimulator", "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K"),
    "watchos": ("watchOS", "watchOS Simulator", "watchsimulator", "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm"),
    "visionos": ("xrOS", "visionOS Simulator", "xrsimulator", "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K"),
}
ADDED_IDENTITIES = {
    "SwiftJXLCoreTests.ModularGradientTests/ansSingleLeafGradientPreservesSignedWrappingOnTransformedPlanes()": 1,
    "SwiftJXLCoreTests.ModularGradientTests/ansSingleLeafGradientUnitTransformShortcutMatchesReference(_:)": 3,
    "SwiftJXLCoreTests.VarDCTTransformTests/workspaceApplyEnforces4096MultiplyAddCheckpointBound()": 1,
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def source_hashes(repo):
    result = PARSER.collect_source_hashes(repo)
    result["Package.swift"] = sha(repo / "Package.swift")
    return result


def expected_inventory(repo):
    baseline = repo / "Documentation/Engineering/Migration/Evidence/Milestone4Remaining/release-6-report.json"
    expected = PARSER.load_expected_identities(baseline)
    require(not expected.intersection(ADDED_IDENTITIES), "Historical baseline already contains additions")
    return expected | set(ADDED_IDENTITIES), 1955 + sum(ADDED_IDENTITIES.values()), sha(baseline)


def enumerate_identities(document):
    require(document.get("errors") == [], "Xcode enumeration reports errors")
    rows = document.get("values", [])
    require(bool(rows), "Empty Xcode enumeration")
    identities = []
    for row in rows:
        require(not row.get("disabledTests"), "Xcode enumeration disabled tests")
        for test in row.get("enabledTests", []):
            value = test["identifier"]
            identities.append(value.replace("/", ".", 1))
    require(bool(identities) and len(identities) == len(set(identities)), "Empty or duplicate test discovery")
    return set(identities)


def assess_instrumentation(configuration, proof, logs, commands, artifacts):
    """Require instrumented arm64 library objects linked into both test bundles.

    Compiler log lines may be absent in an incremental build. Mach-O imports,
    load commands and link inputs describe the actual retained build products.
    """
    entries = proof.get("entries", [])
    objects = {entry["name"]: entry for entry in entries if entry.get("kind") == "library"}
    bundles = {entry["name"]: entry for entry in entries if entry.get("kind") == "testBundle"}
    checks = {"fourDistinctProducts": len(entries) == 4 and len(objects) == len(bundles) == 2,
              "libraryIdentities": set(objects) == {"SwiftJXL", "SwiftJXLCore"},
              "bundleIdentities": set(bundles) == {"SwiftJXLTests", "SwiftJXLCoreTests"},
              "arm64Inspection": proof.get("architecture") == "arm64" and proof.get("configuration") == configuration}
    command_map = {command["label"]: command["command"] for command in commands}
    prefix = "___asan_report_" if configuration == "asan" else "___tsan_"
    for entry in entries:
        name, path = entry["name"], entry["absolutePath"]
        relative = Path(entry["relativePath"])
        checks[name + ":productPathBound"] = not relative.is_absolute() and ".." not in relative.parts and str(Path(proof["derivedData"]) / relative) == path
        checks[name + ":productUnchanged"] = bool(re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256Before", ""))) and entry.get("sha256Before") == entry.get("sha256After")
        label = entry["symbolLog"]
        checks[name + ":symbolCommandBound"] = command_map.get(label) == ["xcrun", "nm", "-arch", "arm64", "-u", path]
        symbols = {line.strip() for line in logs.get(label, "").splitlines()}
        for access in ("load", "store") if configuration == "asan" else ("read", "write"):
            checks[name + ":" + access + "Hooks"] = any(re.fullmatch(re.escape(prefix + access) + r"(?:[0-9]+|_n)", symbol) for symbol in symbols)
        if entry.get("kind") == "testBundle":
            load_label = entry["loadLog"]
            checks[name + ":loadCommandBound"] = command_map.get(load_label) == ["xcrun", "otool", "-arch", "arm64", "-L", path]
            checks[name + ":runtimeLinked"] = "@rpath/libclang_rt." + configuration + "_" in logs.get(load_label, "")
            link = entry["linkFileList"]
            checks[name + ":linkListUnchanged"] = bool(re.fullmatch(r"[0-9a-f]{64}", link.get("sha256Before", ""))) and link["sha256Before"] == link.get("sha256After")
            checks[name + ":linkContentsBound"] = hashlib.sha256(link["contents"].encode()).hexdigest() == link["sha256Before"] and shlex.split(link["contents"]) == link["entries"]
            checks[name + ":bothLibrariesLinked"] = {row["absolutePath"] for row in objects.values()} <= set(link["entries"])
            checks[name + ":executionBinaryBound"] = artifacts.get("xctestBinaries", {}).get(entry["relativePath"], {}).get("sha256") == entry["sha256Before"]
    return {"passed": all(checks.values()), "checks": checks, "failedChecks": [key for key, value in checks.items() if not value]}


def capture_instrumentation(derived, configuration, run):
    proof = {"configuration": configuration, "architecture": "arm64", "derivedData": str(derived), "entries": []}
    logs = {}
    product_roots = set()
    for name in ("SwiftJXLTests", "SwiftJXLCoreTests"):
        paths = list((derived / "Build/Products").rglob(name + ".xctest/" + name))
        require(len(paths) == 1, "Expected one test binary for instrumentation proof: " + name)
        path = paths[0]
        product_roots.add(path.parent.parent)
        links = [p for p in (derived / "Build/Intermediates.noindex").rglob(name + ".LinkFileList") if "/arm64/" in str(p)]
        require(len(links) == 1, "Expected one arm64 link input list: " + name)
        proof["entries"].append({"kind": "testBundle", "name": name, "absolutePath": str(path),
            "relativePath": str(path.relative_to(derived)), "sha256Before": sha(path),
            "linkFileList": {"path": str(links[0]), "sha256Before": sha(links[0]), "contents": links[0].read_text(), "entries": shlex.split(links[0].read_text())}})
    require(len(product_roots) == 1, "Test bundles have inconsistent product directories")
    products = next(iter(product_roots))
    for name in ("SwiftJXL", "SwiftJXLCore"):
        path = products / (name + ".o")
        proof["entries"].append({"kind": "library", "name": name, "absolutePath": str(path),
            "relativePath": str(path.relative_to(derived)), "sha256Before": sha(path)})
    for entry in proof["entries"]:
        label = configuration + "-" + entry["name"]
        entry["symbolLog"] = label + "-symbols"
        logs[entry["symbolLog"]] = run(entry["symbolLog"], ["xcrun", "nm", "-arch", "arm64", "-u", entry["absolutePath"]])
        if entry["kind"] == "testBundle":
            entry["loadLog"] = label + "-loads"
            logs[entry["loadLog"]] = run(entry["loadLog"], ["xcrun", "otool", "-arch", "arm64", "-L", entry["absolutePath"]])
    return proof, logs


def finish_instrumentation(proof):
    for entry in proof["entries"]:
        entry["sha256After"] = sha(Path(entry["absolutePath"]))
        if "linkFileList" in entry:
            link = entry["linkFileList"]
            link["sha256After"] = sha(Path(link["path"]))


def assess(summary, tree, console, discovered, expected_cases, platform_name, runtime, configuration, text, instrumentation=None):
    text = text.replace("\\=", "=")
    declarations = tree["declarations"]
    identities = [row["identity"] for row in declarations]
    leaves = tree["leafCases"]
    device_rows = summary.get("devicesAndConfigurations", [])
    require(len(device_rows) == 1, "Expected exactly one test destination")
    device_result = device_rows[0]
    device = device_result.get("device", {})
    expected_count = len(discovered)
    checks = {
        "discoveryExecutionIdentitiesAgree": set(identities) == discovered and len(identities) == expected_count,
        "expectedCasesExecuted": len(leaves) == expected_cases,
        "uniqueCases": len({row.get("nodeIdentifierURL") for row in leaves}) == len(leaves),
        "allDeclarationsPassed": all(row.get("result") == "Passed" for row in declarations),
        "allCasesPassed": all(row.get("result") == "Passed" for row in leaves),
        "summaryPassed": summary.get("result") == "Passed",
        "summaryDeclarationsAgree": summary.get("totalTestCount") == expected_count and summary.get("passedTests") == expected_count,
        "summaryCasesAgree": device_result.get("passedTests") == expected_cases,
        "summaryNoFailuresSkips": all(summary.get(key) == 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
            and all(device_result.get(key) == 0 for key in ("failedTests", "skippedTests")),
        "consoleCountsAgree": console.get("declarationsPassed") == expected_count
            and console.get("totalCasesPassed") == expected_cases and console.get("declarationsFailed") == 0,
        "correctRuntime": device.get("platform") == platform_name and device.get("architecture") == "arm64"
            and device.get("osVersion") == runtime["version"] and device.get("osBuildNumber") == runtime["buildversion"],
        "armIntegerOracleExecuted": console.get("armIntegerOracleCases") == 123,
        "hardwareVectorsExecuted": console.get("optionalFullRangeHardwareReciprocalVectorsPassed") is True,
        "noSanitizerDiagnostics": re.search(r"(?:ERROR|WARNING|SUMMARY):\s*(?:AddressSanitizer|ThreadSanitizer)|AddressSanitizer:DEADLYSIGNAL|ThreadSanitizer: (?:data race|reported)", text) is None,
    }
    if configuration in ("asan", "tsan"):
        checks["sanitizerInstrumented"] = bool(instrumentation) and instrumentation.get("passed") is True
    return {"passed": all(checks.values()), "checks": checks,
            "failedChecks": [name for name, value in checks.items() if not value], "device": device}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--runtime-version", default="26.0")
    parser.add_argument("--configuration", action="append", choices=PARSER.CONFIG_SPECS)
    parser.add_argument("--reciprocal-vectors", type=Path, required=True)
    parser.add_argument("--prepared-ios-debug", type=Path, help="Adopt this task's disposable iOS device and incremental Debug build")
    parser.add_argument("--reuse-build", action="append", default=[], metavar="CONFIGURATION=DERIVED_DATA", help="Re-enumerate/rebuild an earlier task build against current sources; always use a fresh disposable simulator")
    parser.add_argument("--record-test-diff", action="store_true", help="Retain an intentional test-only working diff alongside the base commit; all source hashes must remain unchanged throughout execution")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    reuse_builds = {}
    for value in args.reuse_build:
        configuration, path = value.split("=", 1)
        require(configuration in PARSER.CONFIG_SPECS and configuration not in reuse_builds, "Invalid or duplicate reusable build")
        reuse_builds[configuration] = Path(path).resolve()
        require(reuse_builds[configuration].is_dir(), "Reusable DerivedData directory absent")
    require(1 <= args.jobs <= 4 and args.timeout > 0, "Invalid build jobs or timeout")
    repo, output, vector_path = args.repo.resolve(), args.output.resolve(), args.reciprocal_vectors.resolve()
    output.mkdir(parents=True, exist_ok=False)
    vectors = json.loads(vector_path.read_text())
    require(len(vectors) == 45826, "Expected complete 45,826 hardware reciprocal vectors")
    expected, case_count, inventory_hash = expected_inventory(repo)
    sources_before = source_hashes(repo)
    driver_hashes = {str(p.relative_to(repo)): sha(p) for p in (Path(__file__).resolve(), LEGACY_PATH.resolve())}
    snapshots = output / "driver-snapshots"
    snapshots.mkdir()
    for relative in driver_hashes:
        (snapshots / Path(relative).name).write_bytes((repo / relative).read_bytes())
    env = os.environ.copy()
    env["TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(vector_path)
    report = {"schemaVersion": 2, "status": "running", "platform": args.platform,
              "startedUTC": now(), "sourceHashesBefore": sources_before, "driverHashes": driver_hashes,
              "commands": [], "runs": [], "expectedDeclarations": len(expected), "expectedCases": case_count,
              "inventoryBaselineSHA256": inventory_hash, "additionalIdentities": ADDED_IDENTITIES,
              "excludedDeclarations": PARSER.EXPECTED_MACOS_ONLY_DECLARATIONS,
              "reciprocalVectors": {"sha256": sha(vector_path), "count": len(vectors), "path": str(vector_path)},
              "reusedBuilds": {configuration: str(path) for configuration, path in reuse_builds.items()},
              "scope": "Full applicable simulator library bundles; no physical-device qualification"}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, timeout=None, allowed=(0,)):
        entry = {"label": label, "command": list(map(str, command)), "startedUTC": now()}
        report["commands"].append(entry)
        save()
        path = output / (label + ".log")
        started = time.monotonic()
        with path.open("w") as log:
            try:
                result = subprocess.run(entry["command"], cwd=repo, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=timeout or args.timeout)
                entry["exitCode"] = result.returncode
            except subprocess.TimeoutExpired:
                entry["exitCode"] = None
                entry["timedOut"] = True
        entry.update(seconds=time.monotonic() - started, log=path.name, logSHA256=sha(path))
        save()
        require(entry["exitCode"] in allowed, f"{label} failed: {entry['exitCode']}; {path}")
        return path.read_text()

    simulator = None
    try:
        report["sourceRevision"] = run("source-revision", ["git", "rev-parse", "HEAD"]).strip()
        source_diff = run("source-diff", ["git", "diff", report["sourceRevision"], "--", "Package.swift", "Sources", "Tests"])
        if source_diff.strip():
            require(args.record_test_diff, "Runtime or test modifications need a new reviewed inventory")
            require(not run("runtime-diff", ["git", "diff", report["sourceRevision"], "--", "Package.swift", "Sources"]).strip(), "Runtime modifications are not permitted by --record-test-diff")
            report["testWorkingDiffSHA256"] = sha(output / "source-diff.log")
            report["sourceState"] = "Base commit plus retained test-only working diff and complete source hash inventory"
        else:
            report["sourceState"] = "Unmodified runtime and test files at the recorded base commit"
        report["toolchain"] = run("swift-version", ["xcrun", "swift", "--version"]).strip()
        report["xcode"] = run("xcode-version", ["xcodebuild", "-version"]).strip()
        report["host"] = run("host", ["sw_vers"]).strip()
        runtime_platform, destination_platform, sdk, device_type = PLATFORMS[args.platform]
        env["SDKROOT"] = run("sdk-path", ["xcrun", "--sdk", sdk, "--show-sdk-path"]).strip()
        report["sdkVersion"] = run("sdk-version", ["xcrun", "--sdk", sdk, "--show-sdk-version"]).strip()
        inventory = json.loads(run("runtimes", ["xcrun", "simctl", "list", "runtimes", "--json"]))
        runtimes = [row for row in inventory["runtimes"] if row.get("isAvailable")
                    and row["platform"] == runtime_platform and row["version"] == args.runtime_version]
        require(len(runtimes) == 1, "Required simulator runtime unavailable or ambiguous")
        runtime = runtimes[0]
        report["runtime"] = runtime
        if args.prepared_ios_debug:
            require(args.platform == "ios", "Prepared iOS build cannot qualify another platform")
            prepared = json.loads((args.prepared_ios_debug / "simulator.json").read_text())
            require(prepared["name"].startswith("SwiftJXL-M5-iOS-") and prepared["runtime"] == runtime["identifier"],
                    "Only this task's prepared disposable simulator may be adopted")
            simulator = prepared["uuid"]
            report["preparedIOSDebug"] = str(args.prepared_ios_debug.resolve())
        else:
            simulator = run("create-simulator", ["xcrun", "simctl", "create", "SwiftJXL-M5-" + args.platform + "-" + uuid.uuid4().hex[:8],
                                                  device_type, runtime["identifier"]]).strip()
            run("boot-simulator", ["xcrun", "simctl", "boot", simulator], timeout=120)
            run("boot-status", ["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=300)
        report["simulatorUUID"] = simulator
        for configuration in args.configuration or ["release"]:
            print(args.platform + " " + configuration + ": enumerate/build", flush=True)
            cfg = PARSER.CONFIG_SPECS[configuration]
            directory = output / configuration
            directory.mkdir()
            derived = ((args.prepared_ios_debug.resolve() / "DerivedData") if args.prepared_ios_debug and configuration == "debug"
                       else reuse_builds.get(configuration, directory / "DerivedData"))
            base = ["xcodebuild", "-scheme", "SwiftJXL-Package", "-configuration", cfg["xcodeConfiguration"],
                    *cfg["extraArgs"], "-destination", f"platform={destination_platform},id={simulator}",
                    "-derivedDataPath", str(derived), "-jobs", str(args.jobs), "-parallel-testing-enabled", "NO",
                    "-only-testing:SwiftJXLTests", "-only-testing:SwiftJXLCoreTests"]
            enumeration_path = directory / "enumeration.json"
            build_log = run(configuration + "-enumeration", base + ["test", "-enumerate-tests", "-test-enumeration-format", "json",
                            "-test-enumeration-style", "flat", "-test-enumeration-output-path", str(enumeration_path)])
            discovered = enumerate_identities(json.loads(enumeration_path.read_text()))
            require(discovered == expected, "Discovered identities differ from audited baseline plus three current regressions: " +
                    json.dumps({"missing": sorted(expected-discovered), "unexpected": sorted(discovered-expected)}))
            instrumentation, instrumentation_logs = (capture_instrumentation(derived, configuration, run)
                                                     if configuration in ("asan", "tsan") else (None, {}))
            if instrumentation:
                report.setdefault("instrumentationProofs", {})[configuration] = instrumentation
                save()
            print(args.platform + " " + configuration + ": execute " + str(len(discovered)) + " declarations", flush=True)
            xcresult = directory / "tests.xcresult"
            test_log = run(configuration + "-tests", base + ["test-without-building", "-resultBundlePath", str(xcresult)])
            summary = json.loads(run(configuration + "-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(xcresult)]))
            test_tree = json.loads(run(configuration + "-tree", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)]))
            metrics = PARSER.parse_xcresult_tree(test_tree)
            console = PARSER.parse_console_log(test_log)
            artifacts = PARSER.record_derived_data_artifacts(repo, derived, directory)
            instrumentation_acceptance = None
            if instrumentation:
                finish_instrumentation(instrumentation)
                instrumentation_acceptance = assess_instrumentation(configuration, instrumentation, instrumentation_logs, report["commands"], artifacts)
                instrumentation["acceptance"] = instrumentation_acceptance
            acceptance = assess(summary, metrics, console, discovered, case_count, destination_platform, runtime, configuration, build_log + test_log, instrumentation_acceptance)
            acceptance["checks"]["testBinariesCaptured"] = len(artifacts["xctestBinaries"]) >= 2
            acceptance["checks"]["compiledSourcesBound"] = len(artifacts["swiftFileLists"]) >= 4
            acceptance["passed"] = all(acceptance["checks"].values())
            acceptance["failedChecks"] = [key for key, value in acceptance["checks"].items() if not value]
            record = {"configuration": configuration, "acceptance": acceptance, "summary": summary, "console": console,
                      "tree": metrics, "artifacts": artifacts, "enumerationSHA256": sha(enumeration_path), "instrumentationProof": instrumentation}
            report["runs"].append(record)
            save()
            require(acceptance["passed"], "Failed runtime acceptance: " + ", ".join(acceptance["failedChecks"]))
            print(args.platform + " " + configuration + ": passed " + str(case_count) + " cases", flush=True)
            # A passing optional vector declaration alone could be its missing-
            # environment early return. Deliberate failures prove file delivery,
            # the minimum count and the numerical assertion on this runtime.
            sentinel_base = [arg for arg in base if not arg.startswith("-only-testing:")]
            sentinel_base.append("-only-testing:SwiftJXLCoreTests/VarDCTARMIntegerTests/optionalFullRangeHardwareReciprocalVectors()")
            short = directory / "short-vectors.json"
            short.write_text("[[2,1056931840]]\n")
            corrupt = directory / "corrupt-vectors.json"
            corrupt.write_text(json.dumps([[2, 0]] + [[2, 1056931840]] * 39999))
            sentinels = [
                ("missing", directory / "absent-vectors.json", ["NSCocoaErrorDomain", "absent-vectors.json"]),
                ("short", short, ["vectors.count >= 40_000"]),
                ("corrupt", corrupt, ["VarDCTReferenceNumerics.reciprocalEstimate(value).bitPattern == bits"]),
            ]
            record["reciprocalSentinels"] = []
            for name, injected_path, expected_text in sentinels:
                env["TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(injected_path)
                result_path = directory / ("sentinel-" + name + ".xcresult")
                label = configuration + "-sentinel-" + name
                sentinel_log = run(label, sentinel_base + ["test-without-building", "-resultBundlePath", str(result_path)], allowed=(65,))
                sentinel_summary = json.loads(run(label + "-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_path)]))
                verified = all(value in sentinel_log for value in expected_text) and sentinel_summary.get("failedTests") == 1 and sentinel_summary.get("totalTestCount") == 1
                record["reciprocalSentinels"].append({"name": name, "verified": verified, "expectedText": expected_text, "summary": sentinel_summary})
                save()
                require(verified, "Reciprocal sentinel did not fail at the intended assertion: " + name)
            env["TEST_RUNNER_SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(vector_path)
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(str(error), file=sys.stderr)
    finally:
        report["sourceHashesAfter"] = source_hashes(repo)
        report["sourcesUnchanged"] = report["sourceHashesAfter"] == sources_before
        report["driversUnchanged"] = all(sha(repo / path) == value for path, value in driver_hashes.items())
        if not report["sourcesUnchanged"] or not report["driversUnchanged"]:
            report.update(status="failed", failure="Source or qualification driver changed during execution")
        if simulator:
            cleanup = {}
            for command in ("shutdown", "delete"):
                result = subprocess.run(["xcrun", "simctl", command, simulator], capture_output=True, text=True, timeout=120)
                cleanup[command] = {"exitCode": result.returncode, "stderr": result.stderr}
            devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
            cleanup["deviceAbsent"] = not any(row["udid"] == simulator for rows in devices["devices"].values() for row in rows)
            report["cleanup"] = cleanup
            if not cleanup["deviceAbsent"]:
                report.update(status="failed", failure="Disposable simulator cleanup failed")
        report["finishedUTC"] = now()
        save()
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
