# Hierarchical correctness-test deadline repair

Main `3069f05500c49d704cd1de2a64b8fe906564adb3`, contract 0.10.0. Native predecessor remains `57e81cb9e2411d1efac435b429a306a031744c1e`.

Both attempts of main run 38378421617 failed in `nestedQuantisationAndGroupBoundaries`: `.resourceLimit` after 30.075 and 30.035 seconds. Its correctness fixture combined four textured 64×64 hierarchical searches and a group boundary within one 30-second operation. The returned log excerpts show this single test issue; the diagnostic service truncated the logs, so they do not establish the absence of every possible sanitizer diagnostic. The aggregate macOS gate failed because its sanitizer dependency failed.

The unchanged fixture passed locally under Swift 6.4 TSan in 15.407 seconds with the same memory and deadline settings. Together with the hosted timings, this identifies a correctness-test workload/deadline collision; it does not establish a codec data race or reproduce the hosted Swift 6.2 failure locally.

## Coverage and correction

Replace the combined 264×65 fixture with independent responsibilities, all still using 30-second operation deadlines:

- A full 64×64 textured region verifies that nested leaves inherit the region's first-cell quantisation. It now explicitly proves that the first and later cells have different local quantisation and that the result actually contains nested leaves.
- 264×17 and 17×264 cases cross horizontal and vertical 256-pixel group boundaries and retain partial final cells. Verify transform containment, complete cell-to-transform mapping and coefficient capacity.
- Expired and pre-cancelled operations must reject before any workspace admission.

The exact original combined shape is preserved in `baseline.swift` and its executed local baseline, rather than remaining a recurring oversized unit fixture. The existing independent writer references for all eleven large transform strategies remain in the suite. Existing grouped writer and public tests continue to cover larger images and group boundaries in the complete hosted suite.

Production sources, the seven common documents, memory limits, operation deadlines, sanitizer configuration and complete hosted test/CLI commands are unchanged. No codec speed or memory improvement is claimed.

## Executed validation

Affected debug, release, ASan and TSan each passed 6 declarations / 19 argument cases, exit 0, no failures or skips and no sanitizer diagnostics in their complete local logs. TSan's nested-region test took 3.735 seconds; the two boundary cases together took 3.298 seconds. These are local correctness-run observations, not cross-platform timing guarantees. All 176 source/test hashes and seven common contract hashes were reverified.

`validation.json` records exact commands, source hashes and test timings. `hosted-failures.json` preserves both original failures and the log-truncation limitation. `fixed-tsan.log` preserves an initial new-test compile error (the resource error enum is not Equatable); `fixed-tsan-2.*` records the corrected explicit error-pattern assertion. No production error type was changed. `SHA256SUMS` covers retained scripts, logs and machine-readable records.

Agent source review found no actionable issue; independent human approval is not claimed. The submitted-head hosted Swift 6.2 result is required before merge. This repair remains outside main until separately authorised merge; broader Milestone 4 performance, feature and platform gates remain open.

## Swift 6.2 fixture compilation follow-up

Hosted run 38392869882 exposed a Swift 6.2 Linux type-checker limit in the nested `laterPatch` map expression. Replace both patch expressions with typed arrays and explicit row/column indices; the selected samples and quantisation assertions are unchanged. Retain the complete diagnostic in `hosted-swift62-compile.json`.

PR23 subsequently passed all 12 checks and was explicitly authorised and merged as main `68af0caae2509b72c91d81ae0cf0553c2817bef8`. This repair branch incorporates that main commit, retaining both history/change-log entries. It changes no production sources or hosted workflow relative to that base.

After the expression correction, focused debug and TSan each pass 6 declarations / 19 cases on local Swift 6.4, with no failures, skips or sanitizer diagnostics. `swift62-followup.json` records the commands and hashes; `swift62-compatible-*` filenames describe the intended correction, not a local Swift 6.2 execution. The original four-configuration records remain historical evidence for the first repair. Current-head hosted Swift 6.2 qualification remains required.
