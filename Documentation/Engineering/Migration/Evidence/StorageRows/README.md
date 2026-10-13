# Sample-row evidence

See [the qualification record](../../STORAGE_PERFORMANCE.md) for scope, results and the open read-performance investigation. The seven common contract documents are unchanged.

- `initial/` and `confirmation/`: original pre-span baseline versus merged PR21, with raw timings and whole-process resources.
- `row-check-initial/` and `row-check-confirmation/`: original, merged and candidate interleaved together. Each cell has five warm-ups and twenty measured observations; confirmation reverses order with fresh processes. No retries to select favourable timings.
- `baseline/`, `current/`, `candidate/`: exact compiler/link commands, source hashes and benchmark sources. The original sample-helper source hash matches the historical shared-source baseline. The candidate is the current source plus `row-check.patch`.
- `span-removal.patch`: the earlier OS 26 compatibility change. Original historical evidence is retained in `Engineering/Swift64/`; it is not relabelled passed.
- `preflight.json`: independent per-sample byte, padding and allocation-identity checks against the same three static library builds. The timing probe itself verifies an analytical checksum.
- `validation.json` and `validation/`: executed debug/release and sanitizer commands, complete logs, XML, test counts and source hashes. XML counts test declarations; parameterised cases are counted separately from their successful log records.

## Reproduction

The final `build.py`, `measure.py` and `validate.py` scripts are preserved. Run them from a writable scratch copy; do not build inside the archived evidence directory. Historical reports retain the original absolute paths and commands. `SWIFTJXL_REPO` overrides the source checkout in the build script; `SWIFTJXL_CORE_BUILD` names a directory containing the source-hash-verified `SwiftJXLCore.swiftmodule`, `libSwiftJXLCore.a` and `SwiftJXLCore-build.json` from the PR21 native-JPEG benchmark. Its recorded source hashes must match the selected checkout before reuse. Exact commands for recreating that static core are retained in the `coreReuse` build record; substitute the source/output paths for the local checkout.

Build `baseline`, `current` and `candidate` separately. The first two extract fixed Git revisions; `candidate` snapshots the current working source. Use the same Xcode/Swift 6.4 compiler and macOS 27 target for every standalone benchmark. Accepted runs used:

```sh
python3 build.py baseline
python3 build.py current
python3 build.py candidate
python3 measure.py initial
python3 measure.py confirmation
python3 measure.py row-check-initial baseline current candidate
python3 measure.py row-check-confirmation baseline current candidate
```

Output directories must be fresh. The initial two-comparator runner was extended for the final three-comparator runs; raw reports retain each executed method. `preflight.json` records exact build/run commands for the additional preflight. `validate.py` reuses local build caches identified in its recorded commands; adapt those scratch paths for another host and preserve all selected cases and limits.

`deployment-mismatch.log` preserves an unsuccessful attempt to link the macOS 27 experimental core into a macOS 26 benchmark. Accepted comparisons rebuilt both public modules for macOS 27. This does not alter the repository's OS 26 deployment floor or claim OS 26 runtime qualification.

Benchmark sources and fixtures are synthetic. The historical baseline files retain their original licence in Git; no historical source is relicensed. No third-party fixture, production data, codec dependency or external runtime fallback is added.
