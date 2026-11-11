#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
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
import re
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
    parser.add_argument("--jpeg-oracle", type=Path, default=shutil.which("djpeg"))
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
    jpeg_oracle = None

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, timeout=180, command_env=None):
        record = {"label": label, "command": list(map(str, command))}
        report["commands"].append(record)
        save()
        result = subprocess.run(record["command"], cwd=repo, env=env if command_env is None else command_env,
                                capture_output=True, text=True, timeout=timeout)
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
            "gray.jpg": "JPEG/gray.jpg",
        }
        for destination, source in mapping.items():
            shutil.copyfile(fixture_root / source, fixtures / destination)
        shutil.copytree(fixture_root / "JPEGExtended", fixtures / "JPEGExtended")
        # JBRD/*.raw contains reconstruction metadata, not decoded pixels.
        # Generate the independent pixel reference on the host; the simulator
        # only receives the resulting bytes and never invokes an external codec.
        require(args.jpeg_oracle is not None, "A host djpeg pixel oracle is required")
        jpeg_oracle = Path(args.jpeg_oracle).resolve(strict=True)
        oracle_hash = sha(jpeg_oracle)
        oracle_env = {key: value for key, value in env.items() if not key.startswith("DYLD_")}
        dependencies = {}
        pending = [jpeg_oracle]
        inspected = set()
        while pending:
            binary = pending.pop()
            if binary in inspected:
                continue
            require(len(inspected) < 16, "Unexpected JPEG oracle dependency graph")
            inspected.add(binary)
            label = "jpeg-oracle-library-" + str(len(inspected))
            loads = run(label + "-loads", ["otool", "-L", binary])
            commands = run(label + "-commands", ["otool", "-l", binary])
            rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", commands)
            install_names = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.+?) \(offset \d+\)", commands)
            def expand(value):
                return Path(value.replace("@loader_path", str(binary.parent)).replace("@executable_path", str(jpeg_oracle.parent)))
            for line in loads.splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if dependency in install_names:
                    continue  # Dylib identity, not a dependency load command.
                if dependency.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                candidates = [expand(base) / dependency[len("@rpath/"):] for base in rpaths] if dependency.startswith("@rpath/") else [expand(dependency)]
                resolved = {path.resolve() for path in candidates if path.is_absolute() and path.is_file()}
                require(len(resolved) == 1, "Unresolved/ambiguous JPEG oracle dependency: " + dependency)
                library = resolved.pop()
                if library != jpeg_oracle:
                    dependencies[str(library)] = sha(library)
                    pending.append(library)
        run("jpeg-oracle-version", [jpeg_oracle, "-version"], command_env=oracle_env)
        pgm = output / "gray-reference.pgm"
        replay = output / "gray-reference-replay.pgm"
        for label, destination in (("jpeg-reference", pgm), ("jpeg-reference-replay", replay)):
            run(label, [jpeg_oracle, "-dct", "int", "-grayscale", "-outfile", destination, fixtures / "gray.jpg"], command_env=oracle_env)
        require(pgm.read_bytes() == replay.read_bytes(), "JPEG reference replay differs")
        data = pgm.read_bytes()
        header = re.match(rb"P5\n([0-9]+) ([0-9]+)\n255\n", data)
        require(header is not None, "Unexpected djpeg greyscale reference header")
        width, height = map(int, header.groups())
        pixels = data[header.end():]
        require(0 < width <= 256 and 0 < height <= 256 and len(pixels) == width * height,
                "JPEG reference dimensions/payload disagree")
        (fixtures / "gray.raw").write_bytes(pixels)
        report["jpegReference"] = {
            "oracle": str(jpeg_oracle), "oracleSHA256": oracle_hash,
            "nonSystemDependencySHA256": dependencies,
            "removedDynamicLoaderEnvironmentKeys": sorted(set(env) - set(oracle_env)),
            "version": (output / "jpeg-oracle-version.log").read_text().strip(),
            "sourceSHA256": sha(fixtures / "gray.jpg"), "pgmSHA256": sha(pgm),
            "rawSHA256": sha(fixtures / "gray.raw"), "width": width, "height": height,
            "bytes": len(pixels), "replayedByteForByte": True,
            "scope": "Independent host libjpeg-turbo integer-IDCT greyscale pixels; no device runtime codec dependency",
        }
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
        if "jpegReference" in report:
            report["jpegOracleUnchanged"] = jpeg_oracle is not None and jpeg_oracle.is_file() and sha(jpeg_oracle) == report["jpegReference"]["oracleSHA256"] and all(
                Path(path).is_file() and sha(Path(path)) == value for path, value in report["jpegReference"]["nonSystemDependencySHA256"].items())
            if not report["jpegOracleUnchanged"]:
                report.update(status="failed", failure="JPEG reference oracle drift")
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
