#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Supplement full Watch simulator suites with owning API limits/cancellation.

Build current-source library products in a fresh directory after their full
suite passes, then compile the existing runtime probe. This is simulator
evidence, not physical Watch evidence.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def current_sources(repo):
    paths = [repo / "Package.swift"] + [path for root in ("Sources", "Tests") for path in (repo / root).rglob("*") if path.is_file() and path.name != ".DS_Store"]
    return {str(path.relative_to(repo)): sha(path) for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite-report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    require(1 <= args.jobs <= 4, "Invalid build jobs")
    output = args.output.resolve()
    products = output / "DerivedData/Build/Products/Release-watchsimulator"
    output.mkdir(parents=True, exist_ok=False)
    suite = json.loads(args.suite_report.read_text())
    require(suite.get("status") == "passed" and suite.get("platform") == "watchos", "Full Watch suite must pass first")
    require(suite.get("sourcesUnchanged") is True and suite.get("driversUnchanged") is True, "Watch suite source/driver drift")
    source_hashes = suite["sourceHashesAfter"]
    require(current_sources(repo) == source_hashes, "Current source inventory differs from full Watch suite")
    fixture_root = repo / "Tests/SwiftJXLCoreTests/Fixtures"
    probe = repo / "Scripts/TestSupport/apple-runtime-probe.swift"
    inputs = {str(probe.relative_to(repo)): sha(probe), str(Path(__file__).resolve().relative_to(repo)): sha(Path(__file__).resolve())}
    report = {"schemaVersion": 1, "status": "running", "sourceRevision": suite["sourceRevision"],
              "suiteReportSHA256": sha(args.suite_report), "sourceHashes": source_hashes,
              "driverHashes": inputs, "runtime": suite["runtime"], "commands": [],
              "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "Supplemental Watch simulator profile, owner, limits and cancellation checks; no physical Watch claim"}
    env = os.environ.copy()

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, timeout=180):
        record = {"label": label, "command": list(map(str, command))}
        report["commands"].append(record)
        save()
        result = subprocess.run(record["command"], cwd=repo, env=env, capture_output=True, text=True, timeout=timeout)
        log = output / (label + ".log")
        log.write_text(result.stdout + result.stderr)
        record.update(exitCode=result.returncode, log=log.name, logSHA256=sha(log))
        save()
        require(result.returncode == 0, label + " failed: " + str(log))
        return result.stdout

    device = None
    try:
        fixtures = output / "fixtures"
        fixtures.mkdir()
        mapping = {
            "precision-12-1.jxl": "VarDCT/EncoderPrecision/precision-12-1.jxl",
            "precision-12-1.scalar": "VarDCT/EncoderPrecision/precision-12-1.scalar",
            "libjxl-lossless-rgba16.jxl": "VarDCT/Animation/libjxl-lossless-rgba16.jxl",
            "gray.jpg": "JPEG/gray.jpg", "gray.raw": "JBRD/gray.raw",
        }
        for destination, source in mapping.items():
            shutil.copyfile(fixture_root / source, fixtures / destination)
        shutil.copytree(fixture_root / "JPEGExtended", fixtures / "JPEGExtended")
        report["fixtureHashes"] = {str(path.relative_to(fixtures)): sha(path) for path in sorted(fixtures.rglob("*")) if path.is_file() and path.name != ".DS_Store"}
        sdk = run("sdk-path", ["xcrun", "--sdk", "watchsimulator", "--show-sdk-path"]).strip()
        env["SDKROOT"] = sdk
        env["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
        report["compiler"] = run("compiler", ["xcrun", "swiftc", "--version"]).strip()
        run("build", ["xcodebuild", "build", "-scheme", "SwiftJXL", "-configuration", "Release", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "-sdk", "watchsimulator",
                      "-destination", "generic/platform=watchOS Simulator", "-derivedDataPath", output / "DerivedData",
                      "-jobs", str(args.jobs)], timeout=1200)
        objects = [products / (module + ".o") for module in ("SwiftJXL", "SwiftJXLCore")]
        report["objects"] = {str(path): sha(path) for path in objects}
        report["modules"] = {str(path): sha(path) for path in sorted(products.rglob("*.swiftmodule")) if path.is_file()}
        require(len(report["modules"]) >= 2, "Missing compiled library modules")
        binary = output / "watch-profile-probe"
        run("compile", ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                        "-target", "arm64-apple-watchos26.0-simulator", "-sdk", sdk, "-I", products, probe, *objects, "-o", binary])
        report["binarySHA256"] = sha(binary)
        device = run("create", ["xcrun", "simctl", "create", "SwiftJXL-M5-WatchProfile-" + uuid.uuid4().hex[:8],
                               "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", suite["runtime"]["identifier"]]).strip()
        report["deviceUUID"] = device
        run("boot", ["xcrun", "simctl", "boot", device])
        run("boot-status", ["xcrun", "simctl", "bootstatus", device, "-b"], timeout=300)
        payload = json.loads(run("probe", ["xcrun", "simctl", "spawn", device, binary, fixtures]))
        required = {"low-memory rejection", "cancellation", "cancellation after destination writes", "failed destination invalidation", "Watch profile and exact round trip"}
        require(payload.get("status") == "passed" and required <= set(payload.get("checks", [])), "Watch profile probe checks incomplete")
        require(payload.get("memoryCeilingBytes") == 32 * 1024 * 1024 and payload.get("jpegExtendedCases", 0) > 0, "Watch profile bound/fixture coverage missing")
        report.update(status="passed", result=payload)
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(str(error), file=sys.stderr)
    finally:
        unchanged = current_sources(repo) == source_hashes and all(sha(repo / path) == value for path, value in inputs.items())
        report["sourcesAndDriversUnchanged"] = unchanged
        if not unchanged:
            report.update(status="failed", failure="Source/driver drift")
        if device:
            report["cleanup"] = []
            for action in ("shutdown", "delete"):
                result = subprocess.run(["xcrun", "simctl", action, device], capture_output=True, text=True, timeout=120)
                report["cleanup"].append({"action": action, "exitCode": result.returncode, "stderr": result.stderr})
                if result.returncode:
                    report.update(status="failed", failure="Disposable simulator cleanup failed")
        report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save()
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
