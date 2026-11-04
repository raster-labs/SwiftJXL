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
                  "cancellationInsideWorkerIsObservedAndAllWorkersJoin", "independentBothDirections",
                  "optionalFullRangeHardwareReciprocalVectors",
                  "lockedValueSerialisesWritersAndConcurrentReaders", "lockedValueUnlocksAfterTypedThrow",
                  "lockedValueRetainsAndReleasesNoncopyableOwner", "oraclePassesLiteralArgumentsAndPreservesNonzeroExit",
                  "oracleTimeoutKillsAndReapsOwnedChild", "oracleRejectsMissingExecutableAndEmbeddedNUL"]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def preserve_output(directory, entry, raw):
    # Concurrent test/sanitizer writes can interleave UTF-8 sequences. Retain
    # the exact bytes and command exit before decoding only for text checks.
    (directory / entry["log"]).write_bytes(raw)
    entry.update(logSHA256=hashlib.sha256(raw).hexdigest(), logBytes=len(raw))
    try:
        text = raw.decode("utf-8")
        entry["validUTF8"] = True
    except UnicodeDecodeError as error:
        text = raw.decode("utf-8", errors="replace")
        entry.update(validUTF8=False, decodeError={"start": error.start, "end": error.end, "reason": error.reason})
    return text


def preserve_streams(directory, entry, stdout, stderr):
    streams = {}
    for name, raw in [("stdout", stdout), ("stderr", stderr)]:
        record = {"log": entry["label"] + "." + name + ".log"}
        preserve_output(directory, record, raw)
        streams[name] = record
    entry["streams"] = streams
    entry["combinedLogOrdering"] = "stdout then stderr; original streams retained separately; no cross-stream chronology inferred"
    return preserve_output(directory, entry, stdout + (b"\n" if stdout and stderr else b"") + stderr)


def xml_identity(case):
    classname, name = case.get("classname", ""), case.get("name", "")
    require(classname and name, "Missing xUnit test identity")
    # Discovery spells free functions module.function and methods module.Suite/function.
    return classname + ("/" if "." in classname else ".") + name


def negative_probe_detected(exit_code, log, expected_diagnostics):
    # Swift access instrumentation reports this deliberate race either as a
    # Swift access race or as a raw data race. Both are real TSan findings;
    # crashes, exclusivity traps and unavailable runtimes are not substitutes.
    return exit_code == 66 and any(diagnostic in log for diagnostic in expected_diagnostics)


def profile_evidence(directory):
    expected = {(bits, channels, associated, transfer, intent)
                for bits in range(8, 17) for channels in range(1, 5)
                for associated in ([0, 1] if channels % 2 == 0 else [0])
                for transfer in [1, 13] for intent in range(4)}
    paths = sorted(directory.glob("public-matrix-*/oracle.json"))
    observed = []
    for path in paths:
        document = json.loads(path.read_text())
        require(document.get("width") == 5 and document.get("height") == 3, "Independent profile dimensions mismatch")
        observed.append(tuple(document.get(key) for key in
                              ["bits", "channels", "premultiplied", "transferFunction", "renderingIntent"]))
    require(len(observed) == len(expected) and set(observed) == expected,
            "Missing, duplicated or unexpected independent profile outputs")
    return {"passed": True, "expected": len(expected), "observed": len(observed),
            "sha256": {str(path.relative_to(directory)): sha(path) for path in paths}}


def test_evidence(xml, discovered, log, progress_log=None):
    cases = ET.parse(xml).findall(".//testcase")
    names = [xml_identity(case) for case in cases]
    record = {"discoveredDeclarations": len(discovered), "executedDeclarations": len(cases),
              "failedDeclarations": sum(case.find("failure") is not None or case.find("error") is not None for case in cases),
              "skippedDeclarations": sum(case.find("skipped") is not None for case in cases)}
    require(len(cases) == len(discovered) and len(cases) > 0, "Zero tests or discovery/execution mismatch")
    require(len(set(names)) == len(names), "Duplicate xUnit declarations")
    require(len(set(discovered)) == len(discovered) and set(names) == set(discovered),
            "Discovery/execution test identities disagree")
    require(not record["failedDeclarations"] and not record["skippedDeclarations"], "Failing/skipped tests cannot satisfy this gate")
    for name in REQUIRED_TESTS:
        require(any(name in item for item in names), f"Required lifetime/race/oracle test missing: {name}")
    counts = []
    for line in (log if progress_log is None else progress_log).splitlines():
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
    parser.add_argument("--reciprocal-vectors", type=Path, required=True)
    parser.add_argument("--reciprocal-manifest", type=Path, required=True)
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
               SWIFTJXL_PROFILE_ORACLE=str(args.tools.resolve() / "swiftjxl-modular-profile-oracle"),
               SWIFTJXL_ARM_RECIPROCAL_VECTORS=str(args.reciprocal_vectors.resolve()),
               ASAN_OPTIONS="halt_on_error=1:exitcode=66:detect_leaks=1", TSAN_OPTIONS="halt_on_error=1:exitcode=66")
    report["sanitizerOptions"] = {key: env[key] for key in ["ASAN_OPTIONS", "TSAN_OPTIONS"]}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, expected_failure=None, expected_test_failure=None):
        print(label, flush=True)
        entry = {"label": label, "argv": list(map(str, command)), "cwd": str(repo), "log": label + ".log"}
        report["commands"].append(entry)
        start = time.monotonic()
        stdout, stderr = b"", b""
        try:
            result = subprocess.run(entry["argv"], cwd=repo, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=args.timeout)
            stdout, stderr, entry["exitCode"] = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr = error.stdout or b"", error.stderr or b""
            entry.update(exitCode=None, timedOut=True)
        except OSError as error:
            stderr = str(error).encode("utf-8")
            entry.update(exitCode=None, launchError=str(error))
        entry["seconds"] = round(time.monotonic() - start, 3)
        text = preserve_streams(output, entry, stdout, stderr)
        save()
        if expected_failure:
            entry["expectedDiagnostics"] = expected_failure
            require(negative_probe_detected(entry.get("exitCode"), text, expected_failure),
                    f"{label}: sanitizer did not detect the intentional invalid probe")
        elif expected_test_failure:
            entry["expectedTestFailure"] = expected_test_failure
            require(entry.get("exitCode") == 1 and expected_test_failure in text,
                    f"{label}: vector sentinel did not fail at its intended assertion")
            require(not re.search(r"(?:ERROR: (?:AddressSanitizer|LeakSanitizer)|WARNING: ThreadSanitizer|FATAL: ThreadSanitizer)", text),
                    f"{label}: sanitizer finding cannot satisfy a vector sentinel")
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
        tracked = run("source-files", ["git", "-c", f"safe.directory={repo}", "ls-files", "Package.swift", "VERSION", "Sources", "Tests",
            "Scripts/TestSupport/modular-profile-oracle.c", "Scripts/TestSupport/modular-info-oracle.cmake",
            "Scripts/Qualification/VarDCTARM/reciprocal-vectors.c"]).splitlines()
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
        profile = args.tools.resolve() / "swiftjxl-modular-profile-oracle"
        require(sha(profile) == oracle["binaries"][profile.name]["sha256"], "Profile oracle binary SHA-256 mismatch")
        require(sha(repo / "Scripts/TestSupport/modular-profile-oracle.c") == oracle["binaries"][profile.name]["sourceSHA256"],
                "Profile oracle source SHA-256 mismatch")
        run("profile-oracle-linkage", ["ldd", profile])
        vectors = json.loads(args.reciprocal_vectors.read_text())
        vector_manifest = json.loads(args.reciprocal_manifest.read_text())
        require(vector_manifest["architecture"] == "aarch64" and vector_manifest["count"] == len(vectors) == 45826,
                "Independent full-range ARM vector inventory mismatch")
        require(vector_manifest["vectorsSHA256"] == sha(args.reciprocal_vectors)
                and vector_manifest["sourceSHA256"] == sha(repo / "Scripts/Qualification/VarDCTARM/reciprocal-vectors.c"),
                "Independent ARM vector source/data SHA-256 mismatch")
        report["hardwareReciprocalVectors"] = {"manifest": vector_manifest, "manifestSHA256": sha(args.reciprocal_manifest), "sentinels": []}
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
        run("test-discovery", command + ["list"])
        discovery = (output / "test-discovery.stdout.log").read_bytes().decode("utf-8", errors="replace")
        names = [line.strip() for line in discovery.splitlines() if line.split(".", 1)[0] in modules]
        require(names, "No tests discovered")
        (output / "discovered-tests.json").write_text(json.dumps(names, indent=2) + "\n")
        xml = output / "tests.xml"
        try:
            log = run("full-tests", command + ["--skip-build", "--xunit-output", xml])
        finally:
            if xml.exists():
                report["xunitSHA256"] = sha(xml)
                try:
                    cases = ET.parse(xml).findall(".//testcase")
                    report["xunitOutcome"] = {"executed": len(cases),
                        "failed": sum(case.find("failure") is not None or case.find("error") is not None for case in cases),
                        "skipped": sum(case.find("skipped") is not None for case in cases)}
                except ET.ParseError as error:
                    # A halt-on-error sanitizer can terminate before XML closes.
                    # Retain that artifact without replacing the failing command.
                    report["xunitOutcome"] = {"complete": False, "parseError": str(error)}
        progress = (output / "full-tests.stdout.log").read_bytes().decode("utf-8", errors="replace")
        report["tests"] = test_evidence(xml, names, log, progress)
        report["independentProfileCoverage"] = profile_evidence(output / "oracle-fixtures")
        for label, contents, expected_text in [
            ("missing", None, "absent-vectors.json"),
            ("short", [[2, 1056931840]], "vectors.count"),
            ("corrupt", [[2, 0]] + [[2, 1056931840]] * 39999, "reciprocalEstimate(value).bitPattern")
        ]:
            path = output / ("absent-vectors.json" if contents is None else label + "-vectors.json")
            if contents is not None:
                path.write_text(json.dumps(contents) + "\n")
            env["SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(path)
            sentinel_xml = output / ("vector-" + label + ".xml")
            try:
                run("vector-" + label, command + ["--skip-build", "--filter", "VarDCTARMIntegerTests/optionalFullRangeHardwareReciprocalVectors",
                    "--xunit-output", sentinel_xml], expected_test_failure=expected_text)
            finally:
                env["SWIFTJXL_ARM_RECIPROCAL_VECTORS"] = str(args.reciprocal_vectors.resolve())
            cases = ET.parse(sentinel_xml).findall(".//testcase")
            require(len(cases) == 1 and cases[0].find("failure") is not None and cases[0].find("skipped") is None,
                    "Vector sentinel did not execute exactly one failing declaration")
            report["hardwareReciprocalVectors"]["sentinels"].append({"name": label, "verified": True, "xunitSHA256": sha(sentinel_xml)})
        report["oracleFixtureSHA256"] = {str(path.relative_to(output)): sha(path)
                                        for path in sorted((output / "oracle-fixtures").rglob("*")) if path.is_file()}
        require(report["oracleFixtureSHA256"], "No retained oracle fixtures")
        require(fingerprint() == report["sourceSHA256"], "Source or fixture changed during validation")
        require(sha(args.oracle_manifest) == report["oracleManifestSHA256"]
                and sha(args.reciprocal_manifest) == report["hardwareReciprocalVectors"]["manifestSHA256"]
                and sha(args.reciprocal_vectors) == vector_manifest["vectorsSHA256"]
                and all(sha(args.tools.resolve() / name) == row["sha256"] for name, row in oracle["binaries"].items()),
                "Independent oracle inputs changed during validation")
        report["oracleInputsUnchanged"] = True
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
