#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rehearse exact-version SwiftPM consumption without publishing a tag.

Only committed Git objects enter a new, shallow private remote. The prerelease
tag exists in that remote alone. This is a local URL/semantic-version packaging
check, not evidence of a published release or HTTPS availability.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate_lockfile(document, revision, version, url):
    pins = document.get("pins", [])
    require(len(pins) == 1, "The consumer must resolve exactly one package")
    pin = pins[0]
    require(pin.get("identity") == "swiftjxl", "Unexpected package identity")
    is_local_git = urlparse(url).scheme == "file"
    kind = "localSourceControl" if is_local_git else "remoteSourceControl"
    location = unquote(urlparse(url).path) if is_local_git else url
    require(pin.get("kind") == kind, "Unexpected dependency kind; a filesystem package is not versioned Git consumption")
    require(pin.get("location") == location, "Resolved URL differs from the selected Git remote")
    require(pin.get("state", {}).get("revision") == revision, "Resolved revision mismatch")
    require(pin.get("state", {}).get("version") == version, "Resolved semantic version mismatch")
    require(not pin.get("state", {}).get("branch"), "A moving branch is not a pinned dependency")


def validate_manifest(document):
    require(document.get("name") == "SwiftJXL", "Unexpected package name")
    require(document.get("dependencies") == [], "External or sibling package dependency")
    require(document.get("toolsVersion", {}).get("_version") == "6.2.0", "Swift tools floor drift")
    require(document.get("swiftLanguageVersions") == ["6"], "Swift language mode drift")
    platforms = {row["platformName"]: row["version"] for row in document.get("platforms", [])}
    require(platforms == dict.fromkeys(["macos", "ios", "tvos", "visionos", "watchos"], "26.0"),
            "Apple deployment floors differ from contract 0.10.0")
    products = {row["name"]: row for row in document.get("products", [])}
    require(set(products) == {"SwiftJXL", "swiftjxl-cli"}, "Unexpected exported products")
    require(products["SwiftJXL"]["targets"] == ["SwiftJXL"] and
            "library" in products["SwiftJXL"]["type"], "Public library product changed")
    require(products["swiftjxl-cli"]["targets"] == ["SwiftJXLCLI"] and
            "executable" in products["swiftjxl-cli"]["type"], "CLI product changed")
    targets = {row["name"]: row for row in document.get("targets", [])}
    production = {name for name, row in targets.items() if row["type"] != "test"}
    require(production == {"SwiftJXL", "SwiftJXLCore", "SwiftJXLCLI"},
            "Unexpected production target or binary/plugin dependency")
    for name, expected in [("SwiftJXL", ["SwiftJXLCore"]), ("SwiftJXLCore", []),
                           ("SwiftJXLCLI", ["SwiftJXL"])]:
        dependencies = targets[name].get("dependencies", [])
        require(dependencies == [{"byName": [item, None]} for item in expected],
                f"Unexpected target dependency for {name}")
    require("unsafeFlags" not in json.dumps(document), "Unsafe manifest flags prevent ordinary consumption")


def validate_graph(document, url, version):
    dependencies = document.get("dependencies", [])
    require(len(dependencies) == 1, "Consumer graph must contain exactly one direct dependency")
    package = dependencies[0]
    location = unquote(urlparse(url).path) if urlparse(url).scheme == "file" else url
    require(package.get("name") == "SwiftJXL" and package.get("url") in {url, location},
            "Consumer graph resolves an unexpected package")
    require(package.get("version") == (version or "unspecified"), "Consumer graph version mismatch")
    require(package.get("dependencies") == [], "Transitive dependency found")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--revision", default="HEAD", help="Committed source revision; working edits are excluded")
    parser.add_argument("--repository-url", help="Optional HTTPS revision consumer instead of a local SemVer rehearsal; commit must already be published")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory; existing paths are refused")
    parser.add_argument("--build-system", choices=["swiftbuild", "native"], default="swiftbuild",
                        help="Explicit engine selection; no fallback (default: swiftbuild)")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=1200, help="Maximum seconds per command")
    parser.add_argument("--disable-package-sandbox", action="store_true")
    parser.add_argument("--keep-work", action="store_true", help="Retain private remote and build work after success")
    args = parser.parse_args()
    require(1 <= args.jobs <= 32 and args.timeout > 0, "Invalid jobs or timeout")
    if args.repository_url:
        parsed = urlparse(args.repository_url)
        require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
                and not parsed.query and not parsed.fragment, "Use an HTTPS repository URL without credentials or query")
    repo, output = args.repository.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    work = output / "work"
    work.mkdir(mode=0o700)
    logs = output / "logs"
    logs.mkdir()
    env = os.environ.copy()
    # Ignore personal Git aliases, URL rewrites, shared SwiftPM mirrors and caches.
    # No system-wide configuration or developer-directory selection is changed.
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_TERMINAL_PROMPT": "0", "SWIFTPM_MODULECACHE_OVERRIDE": str(work / "module-cache"),
                "CLANG_MODULE_CACHE_PATH": str(work / "module-cache")})
    for key in list(env):
        if key.startswith("GIT_CONFIG_KEY_") or key.startswith("GIT_CONFIG_VALUE_") or key in {
            "GIT_CONFIG_COUNT", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_ALTERNATE_OBJECT_DIRECTORIES"
        }:
            env.pop(key, None)
    swift = ["xcrun", "swift"] if platform.system() == "Darwin" else ["swift"]
    report = {
        "schemaVersion": 1, "status": "running", "contractVersion": "0.10.0",
        "scope": ("HTTPS exact-revision consumer; no published semantic version claim" if args.repository_url else
                  "Local URL exact-SemVer rehearsal from committed source; no published release or HTTPS claim"),
        "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment": {"platform": platform.platform(), "machine": platform.machine(),
                        "python": platform.python_version(), "DEVELOPER_DIR": env.get("DEVELOPER_DIR"),
                        "buildSystem": args.build_system, "jobs": args.jobs},
        "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "commands": [], "checks": {},
        "limitations": ["No real repository tag is created or pushed", "No stable release approval",
                        "No platform, security, performance or complete codec qualification is inferred",
                        "Dependency checks cover the package graph, not every system library"],
    }

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(label, command, cwd=repo):
        print(label, flush=True)
        entry = {"label": label, "argv": list(map(str, command)), "cwd": str(cwd),
                 "log": f"logs/{label}.log"}
        report["commands"].append(entry)
        started = time.monotonic()
        stdout, stderr = "", ""
        try:
            result = subprocess.run(entry["argv"], cwd=cwd, env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, timeout=args.timeout)
            stdout, stderr, entry["exitCode"] = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            stderr = error.stderr or ""
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            entry.update(exitCode=None, timedOut=True)
        except OSError as error:
            stdout = str(error)
            entry.update(exitCode=None, launchError=str(error))
        entry["seconds"] = round(time.monotonic() - started, 3)
        (output / entry["log"]).write_text(stdout + ("\n[stderr]\n" + stderr if stderr else ""))
        save()
        require(entry.get("exitCode") == 0, f"{label} failed; see {entry['log']}")
        return stdout

    def swift_command(verb, package):
        command = swift + [verb, "--package-path", str(package), "--scratch-path", str(work / "build"),
                           "--cache-path", str(work / "cache"), "--config-path", str(work / "config"),
                           "--security-path", str(work / "security"), "--build-system", args.build_system,
                           "--jobs", str(args.jobs)]
        if args.disable_package_sandbox:
            command.append("--disable-sandbox")
        return command

    try:
        report["environment"]["swift"] = run("swift-version", swift + ["--version"]).strip()
        report["environment"]["git"] = run("git-version", ["git", "--version"]).strip()
        if platform.system() == "Darwin":
            report["environment"]["xcode"] = run("xcode-version", ["xcodebuild", "-version"]).strip()
            report["environment"]["sdk"] = run("sdk-version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip()
            env["SDKROOT"] = run("sdk-path", ["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
            report["environment"]["sdkPath"] = env["SDKROOT"]
        revision = run("source-revision", ["git", "rev-parse", "--verify", args.revision + "^{commit}"]).strip()
        require(re.fullmatch(r"[0-9a-f]{40}", revision), "Expected a full Git commit SHA")
        report["sourceRevision"] = revision
        report["excludedWorkingChanges"] = run("working-tree-status", ["git", "status", "--short"]).splitlines()
        remote = work / "SwiftJXL.git"
        url = remote.as_uri()
        run("private-remote-init", ["git", "init", "--bare", remote])
        run("private-remote-fetch", ["git", "--git-dir", remote, "fetch", "--depth", "1", "--no-tags",
                                     repo.as_uri(), revision])
        run("private-remote-branch", ["git", "--git-dir", remote, "update-ref", "refs/heads/candidate", revision])
        run("private-remote-head", ["git", "--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/candidate"])
        snapshot = work / "source"
        run("source-checkout", ["git", "clone", "--depth", "1", "--no-tags", url, snapshot])
        require(not run("source-clean", ["git", "status", "--porcelain"], snapshot).strip(), "Snapshot is not clean")
        require(run("source-commit", ["git", "rev-parse", "HEAD"], snapshot).strip() == revision, "Source checkout mismatch")
        version = (snapshot / "VERSION").read_text().strip()
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version), "Invalid VERSION")
        report.update(version=version, privateRemoteURL=url)
        run("private-version-tag", ["git", "--git-dir", remote, "update-ref", f"refs/tags/{version}", revision])
        refs = run("private-remote-refs", ["git", "--git-dir", remote, "show-ref"])
        require(len(refs.strip().splitlines()) == 2, "Unexpected references in private remote")
        source_files = ["Package.swift", "VERSION", "NOTICE", "LICENSE", "Sources/SwiftJXLCLI/main.swift",
                        "ManPages/swiftjxl-cli.1", "Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift",
                        "Documentation/COMMON_CONTRACT_SHA256.txt"]
        contract_manifest = snapshot / "Documentation/COMMON_CONTRACT_SHA256.txt"
        contract_hashes = {}
        for line in contract_manifest.read_text().splitlines():
            digest, filename = line.split(maxsplit=1)
            filename = filename.lstrip("*")
            path = snapshot / "Documentation" / filename
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            require(actual == digest, f"Shared contract digest mismatch: {filename}")
            contract_hashes[filename] = actual
        require(len(contract_hashes) == 7, "Expected seven common contract documents")
        report["contractSHA256"] = contract_hashes
        report["sourceSHA256"] = {name: hashlib.sha256((snapshot / name).read_bytes()).hexdigest()
                                  for name in source_files}
        cli = (snapshot / "Sources/SwiftJXLCLI/main.swift").read_text()
        require(re.search(r'private let version = "' + re.escape(version) + r'"', cli), "CLI version mismatch")
        manual_header = (snapshot / "ManPages/swiftjxl-cli.1").read_text().splitlines()[0]
        require(manual_header.startswith(".TH ") and f'"{version}"' in manual_header, "Manual version mismatch")
        manifest = json.loads(run("package-manifest", swift_command("package", snapshot) + ["dump-package"]))
        validate_manifest(manifest)
        report["checks"]["packageManifestAndVersion"] = "passed"
        consumer_url = args.repository_url or url
        selected_version = None if args.repository_url else version
        requirement = (f"revision: {json.dumps(revision)}" if args.repository_url else
                       f"exact: {json.dumps(version)}")
        report["consumerURL"] = consumer_url
        report["consumerRequirement"] = {"revision": revision} if args.repository_url else {"exact": version}
        consumer = work / "consumer"
        (consumer / "Sources/Consumer").mkdir(parents=True)
        consumer_manifest = ('// swift-tools-version: 6.2\nimport PackageDescription\n'
            'let package = Package(name: "Consumer", platforms: [.macOS("26.0")],\n'
            f'  dependencies: [.package(url: {json.dumps(consumer_url)}, {requirement})],\n'
            '  targets: [.executableTarget(name: "Consumer", dependencies: [\n'
            '    .product(name: "SwiftJXL", package: "swiftjxl")])], swiftLanguageModes: [.v6])\n')
        (consumer / "Package.swift").write_text(consumer_manifest)
        (output / "Consumer.Package.swift").write_text(consumer_manifest)
        example = snapshot / "Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift"
        shutil.copy2(example, consumer / "Sources/Consumer/Consumer.swift")
        shutil.copy2(example, output / "Consumer.swift")
        run("resolve-pinned-dependency", swift_command("package", consumer) + ["resolve"])
        lockfile = consumer / "Package.resolved"
        validate_lockfile(json.loads(lockfile.read_text()), revision, selected_version, consumer_url)
        shutil.copy2(lockfile, output / "Package.resolved")
        graph = json.loads(run("consumer-graph", swift_command("package", consumer) + ["show-dependencies", "--format", "json"]))
        validate_graph(graph, consumer_url, selected_version)
        (output / "dependency-graph.json").write_text(json.dumps(graph, indent=2) + "\n")
        report["checks"]["pinnedResolutionAndGraph"] = "passed"
        for configuration in ["debug", "release"]:
            run(f"{configuration}-build", swift_command("build", consumer) + ["-c", configuration, "--product", "Consumer"])
            result = run(f"{configuration}-run", swift_command("run", consumer) + ["-c", configuration, "--skip-build", "Consumer"])
            require("Public consumer passed:" in result, f"{configuration}: consumer success sentinel missing")
            validate_lockfile(json.loads(lockfile.read_text()), revision, selected_version, consumer_url)
            report["checks"][f"{configuration}PublicConsumer"] = "passed"
        require(not run("source-unchanged", ["git", "status", "--porcelain"], snapshot).strip(), "Source snapshot changed")
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", failure=str(error))
        print(f"ERROR: {error}", file=sys.stderr)
    finally:
        report["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        report["workRetained"] = args.keep_work or report["status"] != "passed"
        save()
        if not report["workRetained"]:
            shutil.rmtree(work)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
