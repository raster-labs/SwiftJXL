#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independently reconcile retained simulator logs, source lists and receipts."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("simulator_suite", Path(__file__).with_name("qualify-apple-simulator-suite.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


def audit(receipt, configurations, vectors, select_passed=False):
    report = json.loads(receipt.read_text())
    directory = receipt.parent
    repo = Path(__file__).resolve().parents[2]
    selected = [run for run in report["runs"] if run["configuration"] in configurations] if select_passed else report["runs"]
    excluded = [run for run in report["runs"] if run not in selected]
    selection_compatible = report.get("status") == "passed" or (
        select_passed and report.get("status") == "failed" and
        report.get("failure", "").startswith("Failed runtime acceptance:") and
        any(run.get("acceptance", {}).get("passed") is False for run in excluded))
    checks = {"binaryProofSchema": report.get("schemaVersion") == 2,
              "terminalReceiptCompatibleWithScope": selection_compatible,
              "sourcesUnchanged": report.get("sourcesUnchanged") is True,
              "driversUnchanged": report.get("driversUnchanged") is True,
              "disposableDeviceRemoved": report.get("cleanup", {}).get("deviceAbsent") is True,
              "exactConfigurations": [r["configuration"] for r in selected] == configurations and len(configurations) == len(set(configurations)),
              "selectedConfigurationsAcceptedAtExecution": bool(selected) and all(run.get("acceptance", {}).get("passed") is True for run in selected),
              "sourcesMatchCurrent": report["sourceHashesBefore"] == report["sourceHashesAfter"] == suite.source_hashes(repo),
              "driversMatchCurrent": all(suite.sha(repo / path) == digest for path, digest in report["driverHashes"].items()),
              "driverSnapshotsMatch": all(suite.sha(directory / "driver-snapshots" / Path(path).name) == digest for path, digest in report["driverHashes"].items()),
              "hardwareVectorHashMatches": suite.sha(vectors) == report["reciprocalVectors"]["sha256"],
              "hardwareVectorCountMatches": len(json.loads(vectors.read_text())) == 45826 == report["reciprocalVectors"]["count"]}
    expected, cases, inventory_hash = suite.expected_inventory(repo)
    checks["inventoryBaselineMatches"] = inventory_hash == report["inventoryBaselineSHA256"]
    logs = {}
    for command in report["commands"]:
        label = command["label"]
        path = directory / command["log"]
        logs[label] = path.read_text()
        checks["logHash:" + label] = suite.sha(path) == command["logSHA256"]
        expected_exit = 65 if "-sentinel-" in label and not label.endswith("-summary") else 0
        checks["commandExit:" + label] = command.get("exitCode") == expected_exit and not command.get("timedOut")
    checks["baseRevisionAndTestDiffBound"] = not logs["source-diff"].strip() or (
        report.get("testWorkingDiffSHA256") == suite.sha(directory / "source-diff.log") and "runtime-diff" in logs and not logs["runtime-diff"].strip())
    checks["compilerHostRevisionIdentityBound"] = all(report.get(key) == logs[label].strip() for key, label in (
        ("toolchain", "swift-version"), ("xcode", "xcode-version"), ("host", "host"),
        ("sdkVersion", "sdk-version"), ("sourceRevision", "source-revision")))
    checks["swift64QualificationCompiler"] = re.search(r"Apple Swift version 6\.4\.", logs["swift-version"]) is not None
    checks["runtimeInventoryMatches"] = report["runtime"] in json.loads(logs["runtimes"])["runtimes"] and report["runtime"].get("isAvailable") is True
    revision = report["sourceRevision"]
    checks["versionFileMatchesRecordedRevision"] = bool(re.fullmatch(r"[0-9a-f]{40}", revision)) and subprocess.check_output(
        ["git", "show", revision + ":VERSION"], cwd=repo) == (repo / "VERSION").read_bytes()
    # The package scheme also compiles its CLI target; only library test
    # bundles execute, but all package source files must be accounted for.
    required_sources = {str(path.relative_to(repo)) for root in ("Sources", "Tests/SwiftJXLTests", "Tests/SwiftJXLCoreTests") for path in (repo / root).rglob("*.swift")}
    diagnostic_pattern = r"(?:ERROR|WARNING|SUMMARY):\s*(?:AddressSanitizer|ThreadSanitizer)|AddressSanitizer:DEADLYSIGNAL|ThreadSanitizer: (?:data race|reported)"
    for run in selected:
        name = run["configuration"]
        summary = json.loads(logs[name + "-summary"])
        metrics = suite.PARSER.parse_xcresult_tree(json.loads(logs[name + "-tree"]))
        console = suite.PARSER.parse_console_log(logs[name + "-tests"])
        enumeration = directory / name / "enumeration.json"
        discovered = suite.enumerate_identities(json.loads(enumeration.read_text()))
        checks[name + ":enumerationMatches"] = discovered == expected and suite.sha(enumeration) == run["enumerationSHA256"]
        checks[name + ":rawResultsMatchReceipt"] = summary == run["summary"] and metrics == run["tree"] and console == run["console"]
        instrumentation_acceptance = None
        if name in ("asan", "tsan"):
            proof = run.get("instrumentationProof")
            instrumentation_acceptance = suite.assess_instrumentation(name, proof or {}, logs, report["commands"], run["artifacts"])
            checks[name + ":instrumentationProofMatches"] = proof is not None and instrumentation_acceptance == proof.get("acceptance")
        acceptance = suite.assess(summary, metrics, console, discovered, cases, suite.PLATFORMS[report["platform"]][1],
                                  report["runtime"], name, logs[name + "-enumeration"] + logs[name + "-tests"], instrumentation_acceptance)
        checks[name + ":reconciledResultsPass"] = acceptance["passed"]
        checks[name + ":taskDeviceUsed"] = acceptance["device"].get("deviceId") == report["simulatorUUID"]
        checks[name + ":noSanitizerDiagnostics"] = re.search(diagnostic_pattern, logs[name + "-tests"]) is None
        artifacts = run["artifacts"]
        checks[name + ":artifactManifestMatches"] = artifacts == json.loads((directory / name / "build-artifacts.json").read_text())
        checks[name + ":moduleResourceEvidencePresent"] = len(artifacts["xctestBinaries"]) >= 2 and len(artifacts["swiftmodules"]) >= 4 and bool(artifacts["resourceBundles"])
        compiled = {path for entry in artifacts["swiftFileLists"].values() for path in entry["entries"] if path.startswith(("Sources/", "Tests/"))}
        checks[name + ":everyApplicableSourceCompiled"] = compiled == required_sources
        sentinels = run.get("reciprocalSentinels", [])
        checks[name + ":threeLoadBearingSentinels"] = len(sentinels) == 3 and {s["name"] for s in sentinels} == {"missing", "short", "corrupt"} and all(s.get("verified") is True for s in sentinels)
        for sentinel in sentinels:
            label = name + "-sentinel-" + sentinel["name"]
            summary = json.loads(logs[label + "-summary"])
            checks[name + ":sentinel:" + sentinel["name"]] = summary == sentinel["summary"] and summary.get("failedTests") == 1 and summary.get("totalTestCount") == 1 and all(text in logs[label] for text in sentinel["expectedText"])
    return {"status": "passed" if all(checks.values()) else "failed", "checks": checks,
            "failedChecks": [key for key, value in checks.items() if not value],
            "receiptSHA256": suite.sha(receipt), "auditorSHA256": suite.sha(Path(__file__).resolve()),
            "receiptStatus": report["status"], "selectedConfigurations": configurations,
            "excludedConfigurations": [{"configuration": run["configuration"], "acceptance": run.get("acceptance")} for run in excluded],
            "scope": "Only the explicitly selected configurations are qualified; excluded configurations remain unqualified by this audit. Vector delivery negative sentinels are required for every selected configuration."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--configuration", action="append", required=True)
    parser.add_argument("--vectors", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--select-passed-configurations", action="store_true", help="Audit requested passed configurations of a terminal receipt; excluded configurations are not certified")
    args = parser.parse_args()
    try:
        result = audit(args.receipt, args.configuration, args.vectors, args.select_passed_configurations)
    except Exception as error:
        result = {"status": "failed", "error": str(error)}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "checks"}))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
