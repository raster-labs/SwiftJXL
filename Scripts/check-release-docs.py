#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check the published migration example and active release-document links."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


def check(repo):
    files = ["README.md", "MIGRATION.md", "CLI.md", "SECURITY.md", "NOTICE",
             "THIRD_PARTY_NOTICES.md", "Scripts/README.md",
             "Documentation/Engineering/Release/README.md"]
    migration = (repo / "MIGRATION.md").read_text()
    section = migration.split("## Compilable preparation example", 1)[1]
    example = re.search(r"```swift\n(.*?)\n```", section, re.S)
    source = repo / "Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift"
    if example is None or example.group(1) + "\n" != source.read_text():
        raise ValueError("MIGRATION.md example differs from the compiled public consumer")
    if "https://github.com/raster-labs/SwiftJXL.git" not in migration:
        raise ValueError("Migration guide must name the current successor repository URL")
    checked_links = 0
    for name in files:
        path = repo / name
        for target in re.findall(r"\]\(([^\s)]+)\)", path.read_text()):
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            destination = (path.parent / unquote(parsed.path)).resolve()
            if not destination.is_relative_to(repo.resolve()) or not destination.exists():
                raise ValueError(f"Broken or non-portable local link in {name}: {target}")
            checked_links += 1
    files.append(str(source.relative_to(repo)))
    return {"status": "passed", "checks": {"compiledExampleMatchesMarkdown": True,
            "canonicalSuccessorURL": True, "localLinks": checked_links},
            "filesSHA256": {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in files},
            "limitations": ["Links are checked for local targets, not external reachability or section anchors",
                            "Compilation is established by separate URL-consumer reports"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Evidence already exists; choose a new output path")
    try:
        report = check(args.repository.resolve())
    except (OSError, ValueError, IndexError) as error:
        report = {"status": "failed", "failure": str(error)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
