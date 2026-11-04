#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Require native Linux sanitizer runtime detection and the entire test suite.

No suppressed findings, missing oracles, skipped tests or failed commands count
as a pass. Release optimisation keeps instrumented large-image work within its
unchanged operation deadlines. Native SwiftPM is selected explicitly.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ORACLE_REVISION = "a7a9c787341cf703dede03c2009fa460cae5e5df"
REQUIRED_TESTS = ["imageRetainsAdapterAndAllocationUntilLastReader", "concurrentReadersPreserveEveryLogicalSample",
                  "sharedSourceSurvivesCallerReleaseAndOneCancelledEncode", "concurrentEncodersShareOneImmutableSource",
                  "cancellationInsideWorkerIsObservedAndAllWorkersJoin", "independentBothDirections"]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def negative_probe_detected(exit_code, log, expected_diagnostics):
    # Swift access instrumentation reports this deliberate race either as a
    # Swift access race or as a raw data race. Both are real TSan findings;
    # crashes, exclusivity traps and unavailable runtimes are not substitutes.
    return exit_code == 66 and any(diagnostic in log for diagnostic in expected_diagnostics)


def test_evidence(xml, discovered, log):
    cases = ET.parse(xml).findall(".//testcase")
    names = [case.get("classname", "") + "/" + case.get("name", "") for case in cases]
    record = {"discoveredDeclarations": len(discovered), "executedDeclarations": len(cases),
              "failedDeclarations": sum(case.find("failure") is not None or case.find("error") is not None for case in cases),
              "skippedDeclarations": sum(case.find("skipped") is not None for case in cases)}
    require(len(cases) == len(discovered) and len(cases) > 0, "Zero tests or discovery/execution mismatch")
    require(len(set(names)) == len(names), "Duplicate xUnit declarations")
    require(not record["failedDeclarations"] and not record["skippedDeclarations"], "Failing/skipped tests cannot satisfy this gate")
    for name in REQUIRED_TESTS:
        require(any(name in item for item in names), f"Required lifetime/race/oracle test missing: {name}")
    counts = []
    for line in log.splitlines():
        if re.search(r"\bTest (?!run\b|case\b).+ passed after", line):
            match = re.search(r"with (\d+) test cases passed", line)
            counts.append(int(match.group(1)) if match else 1)
    record["passedArgumentCasesFromLog"] = sum(counts)
    require(len(counts) == len(cases), "Log/xUnit declaration counts disagree")
    require(not re.search(r"(?:ERROR: (?:AddressSanitizer|LeakSanitizer)|WARNING: ThreadSanitizer|FATAL: ThreadSanitizer)", log),
            "Sanitizer diagnostic in suite log")
    record["requiredLifetimeRaceAndOracleTests"] = REQUIRED_TESTS
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizer", choices=["address", "thread"], required=True)
    parser.add_argument("--swift-line", choices=["6.2", "6.4"], required=True)
    parser.add_argument("--architecture", choices=["x86_64", "aarch64"], required=True)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--oracle-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    repo, output = Path(__file__).resolve().parents[1], args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "running", "sanitizer": args.sanitizer, "configuration": "release", "buildEngine": "native",
              "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "runnerSHA256": sha(Path(__file__)), "commands": [], "scope": "Full native Linux test suite with mandatory pinned oracles",
              "environment": {"platform": platform.platform(), "architecture": platform.machine(),
                              "python": platform.python_version(), "containerImage": os.getenv("QUALIFICATION_CONTAINER"),
                              "githubRunID": os.getenv("GITHUB_RUN_ID"), "githubRunAttempt": os.getenv("GITHUB_RUN_ATTEMPT"),
                              "runnerArch": os.getenv("RUNNER_ARCH"), "imageVersion": os.getenv("ImageVersion")}}
    env = os.environ.copy()
    env.update(SWIFTJXL_ORACLE_BIN=str(args.tools.resolve()), SWIFTJXL_ORACLE_OUTPUT=str(output / "oracle-fixtures"),
               ASAN_OPTIONS="halt_on_error=1:exitcode=66:detect_leaks=1", TSAN_OPTIONS="halt_on_error=1:exitcode=66")
    report["sanitizerOptions"] = {key: env[key] for key in ["ASAN_OPTIONS", "TSAN_OPTIONS"]}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, expected_failure=None):
        print(label, flush=True)
        entry = {"label": label, "argv": list(map(str, command)), "cwd": str(repo), "log": label + ".log"}
        report["commands"].append(entry)
        start = time.monotonic()
        text = ""
        try:
            result = subprocess.run(entry["argv"], cwd=repo, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=args.timeout)
            text, entry["exitCode"] = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            text = error.stdout or ""
            if isinstance(text, bytes):
                text = text.decode(errors="replace")
            entry.update(exitCode=None, timedOut=True)
        except OSError as error:
            text = str(error)
            entry.update(exitCode=None, launchError=str(error))
        entry["seconds"] = round(time.monotonic() - start, 3)
        (output / entry["log"]).write_text(text)
        save()
        if expected_failure:
            entry["expectedDiagnostics"] = expected_failure
            require(negative_probe_detected(entry.get("exitCode"), text, expected_failure),
                    f"{label}: sanitizer did not detect the intentional invalid probe")
        else:
            require(entry.get("exitCode") == 0, f"{label} failed; see {entry['log']}")
        return text

    tracked = []

    def fingerprint():
        return {name: sha(repo / name) for name in tracked}

    try:
        require(platform.system() == "Linux" and platform.machine() == args.architecture, "Expected native Linux architecture")
        report["environment"]["osRelease"] = Path("/etc/os-release").read_text()
        require('VERSION_ID="24.04"' in report["environment"]["osRelease"], "Expected Ubuntu 24.04")
        report["environment"]["swift"] = run("swift-version", ["swift", "--version"]).strip()
        require(re.search(r"Swift version " + re.escape(args.swift_line) + r"(?:\.|\s)", report["environment"]["swift"]), "Compiler line mismatch")
        report["environment"]["swiftTargetInfo"] = json.loads(run("swift-target-info", ["swift", "-print-target-info"]))
        report["sourceRevision"] = run("source-revision", ["git", "-c", f"safe.directory={repo}", "rev-parse", "HEAD"]).strip()
        report["workingTree"] = run("source-status", ["git", "-c", f"safe.directory={repo}", "status", "--short"]).strip()
        require(not report["workingTree"], "Sanitizer qualification requires a clean checkout")
        tracked = run("source-files", ["git", "-c", f"safe.directory={repo}", "ls-files", "Package.swift", "Sources", "Tests"]).splitlines()
        report["sourceSHA256"] = fingerprint()
        run("runtime-packages", ["dpkg-query", "-W", "libc6", "libstdc++6", "libjpeg-turbo8", "libpng16-16t64", "libbrotli1"])
        report["environment"]["mmapRandomisationBits"] = Path("/proc/sys/vm/mmap_rnd_bits").read_text().strip()
        oracle = json.loads(args.oracle_manifest.read_text())
        require(oracle["revision"] == ORACLE_REVISION and oracle["architecture"] == args.architecture, "Oracle pin/architecture mismatch")
        report["oracleManifest"] = oracle
        report["oracleManifestSHA256"] = sha(args.oracle_manifest)
        for name in ["cjxl", "djxl"]:
            binary = args.tools.resolve() / name
            require(sha(binary) == oracle["binaries"][name]["sha256"], "Oracle binary SHA-256 mismatch")
            require("v0.12.0" in run(name + "-version", [binary, "--version"]), "Unexpected oracle version")
            run(name + "-linkage", ["ldd", binary])
        # This safe Swift probe must load and execute the actual sanitizer runtime.
        positive = output / "sanitizer-positive.swift"
        positive.write_text('let owner = UnsafeMutablePointer<Int>.allocate(capacity: 1)\nowner.initialize(to: 42)\n'
                            'print("sanitizer-runtime-ok", owner.pointee)\nowner.deinitialize(count: 1)\nowner.deallocate()\n')
        negative = output / "sanitizer-negative.swift"
        if args.sanitizer == "address":
            negative.write_text('// Deliberate test-only use-after-free; never linked into SwiftJXL.\n'
                                'let owner = UnsafeMutablePointer<Int>.allocate(capacity: 1)\nowner.initialize(to: 42)\n'
                                'owner.deinitialize(count: 1)\nowner.deallocate()\nprint(owner.pointee)\n')
            expected = ["ERROR: AddressSanitizer: heap-use-after-free"]
        else:
            negative.write_text('// Deliberate test-only race; never linked into SwiftJXL.\nimport Glibc\n'
                                'nonisolated(unsafe) var shared = 0\n'
                                'func writer(_: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {\n'
                                '  for _ in 0..<10000 { shared += 1 }; return nil\n}\n'
                                'var first = pthread_t(), second = pthread_t()\n'
                                'pthread_create(&first, nil, writer, nil)\npthread_create(&second, nil, writer, nil)\n'
                                'pthread_join(first, nil)\npthread_join(second, nil)\nprint(shared)\n')
            expected = ["WARNING: ThreadSanitizer: data race", "WARNING: ThreadSanitizer: Swift access race"]
        for name, source in [("positive", positive), ("negative", negative)]:
            binary = output / ("sanitizer-" + name)
            run("probe-" + name + "-compile", ["swiftc", "-swift-version", "6", "-g", "-Onone", "-sanitize=" + args.sanitizer, source, "-o", binary])
            if name == "positive":
                require("sanitizer-runtime-ok 42" in run("probe-positive-run", [binary]), "Positive probe did not finish")
            else:
                run("probe-negative-run", [binary], expected_failure=expected)
        report["runtimeProbe"] = "passed-positive-and-intentional-finding"
        manifest = (repo / "Package.swift").read_text()
        modules = set(re.findall(r'\.testTarget\s*\(\s*name:\s*"([^"]+)"', manifest))
        xctest = any(re.search(r"\bimport\s+XCTest\b|:\s*XCTestCase\b", (repo / name).read_text())
                     for name in tracked if name.startswith("Tests/") and name.endswith(".swift"))
        command = ["swift", "test", "--build-system", "native", "--scratch-path", str(output / "build"), "--jobs", "2",
                   "-c", "release", "--sanitize", args.sanitizer, "--enable-swift-testing",
                   "--enable-xctest" if xctest else "--disable-xctest", "--no-parallel"]
        discovery = run("test-discovery", command + ["list"])
        names = [line.strip() for line in discovery.splitlines() if line.split(".", 1)[0] in modules]
        require(names, "No tests discovered")
        (output / "discovered-tests.json").write_text(json.dumps(names, indent=2) + "\n")
        xml = output / "tests.xml"
        try:
            log = run("full-tests", command + ["--skip-build", "--xunit-output", xml])
        finally:
            if xml.exists():
                report["xunitSHA256"] = sha(xml)
                cases = ET.parse(xml).findall(".//testcase")
                report["xunitOutcome"] = {"executed": len(cases),
                    "failed": sum(case.find("failure") is not None or case.find("error") is not None for case in cases),
                    "skipped": sum(case.find("skipped") is not None for case in cases)}
        report["tests"] = test_evidence(xml, names, log)
        report["oracleFixtureSHA256"] = {str(path.relative_to(output)): sha(path)
                                        for path in sorted((output / "oracle-fixtures").rglob("*")) if path.is_file()}
        require(report["oracleFixtureSHA256"], "No retained oracle fixtures")
        require(fingerprint() == report["sourceSHA256"], "Source or fixture changed during validation")
        report["sourceUnchanged"] = True
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(error, file=sys.stderr)
    finally:
        report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        report["exitCode"] = 0 if report["status"] == "passed" else 1
        save()
    return report["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
