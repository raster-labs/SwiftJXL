# Exact Modular learner sample cap — 14 October 2026

The internal effort-8/9 learners used `max(1, N / 256000)` as a sampling stride. Floor division did not enforce the approximate stated maximum: 511,999 inputs produced 511,999 learning samples, and 16 million inputs produced 258,065. Both grouped and single-section paths now select exactly `min(N, 256000)` indices, uniformly defined by `floor(i*N/M)`, where `M` is that selected count. A quotient/remainder iterator avoids overflowing the product and allocates no index array. Inputs at or below the cap retain every sample.

Above-cap sample selection can learn a different valid tree and change compressed bytes. This is an internal qualification change; public API/CLI effort stays at 3. All source storage, worker and common contract rules remain unchanged. Sample selection has periodic checkpoints, but this does not establish a complete learning/sorting cancellation bound or higher-effort memory envelope.

## Executed qualification

Base `045e7883818c3ba96d24249dbed9cf3524c5db0f` (PR26 including its Swift 6.2 fixture repair), predecessor `57e81cb9e2411d1efac435b429a306a031744c1e`, contract 0.10.0. The release baseline reuses the previous exact core/probe after verifying all 98 core hashes against the base; the candidate is newly built.

- Debug, release, AddressSanitizer and ThreadSanitizer each pass 13 declarations / 89 argument cases, no failures, skips or sanitizer diagnostics. The same 180 source/test hashes match all four runs. Regressions cover cap transitions, exact rational indices, exhaustion, invalid counts and `Int.max` without overflow.
- All 54 existing effort/case streams independently decode exactly and preserve prior fixture bytes. Prior small baseline evidence is reused, not counted as newly executed.
- Four larger/control cases are independently decoded on both baseline and candidate: eight exact decodes. The three changed cases exercise single-section greyscale/RGBA and grouped greyscale above the cap. Every stream retained from timing matches the corresponding independently decoded hash.
- The old sampling formula is evaluated from pinned source as a diagnostic arithmetic audit. It is not presented as an allocator trace. The initial `Sequence.min` compiler ambiguity and its correction to `Swift.min` are retained.

## Controlled performance comparison

Local Swift 6.4, Swift 6 mode/complete concurrency, release `-O` whole-module optimisation, arm64 macOS 26.0 target on a macOS 27.0.1 host. Two opposite interleavings each retain twenty timed samples per implementation/case, with five warm-ups per block. All local build/test/oracle work completed before timing. Thermal state and spread are recorded; external system load is not measured. These are serial internal-core encodes without public operation budgets. RSS is process-wide, not measured algorithm workspace.

Negative changes are improvements. Raw summaries retain median, p95, range, sizes, RSS, hashes and exact commands.

| Case | Median time, initial / repeat | Encoded size | Peak RSS, initial / repeat |
| --- | --- | --- | --- |
| small-control | +0.36% / +0.21% | +0.00000% | -0.68% / -0.68% |
| single-gray-cap | -1.27% / -0.98% | -0.00030% | -2.27% / -2.27% |
| single-rgba-cap | -32.22% / -32.89% | +0.00190% | -3.05% / -5.77% |
| group-gray-cap | -29.81% / -29.73% | -0.00014% | -12.31% / -22.19% |

The two approximately 511,000-sample cases reduce learning input nearly by half and improve encode time by about 30–33% in both comparisons. Their compression-size changes stay below 0.002%. The near-cap greyscale case improves about 1%; the smaller unchanged control varies by less than 0.4%. These four cases do not establish broader performance or compression parity with the predecessor.

## Evidence and remaining work

[Qualification index](Evidence/ModularLearningCap/qualification.json), [raw evidence](Evidence/ModularLearningCap/raw-evidence.zip), [boundary tests](../../../Tests/SwiftJXLCoreTests/ModularLearningSampleTests.swift), and [existing fixture provenance](../../../Tests/SwiftJXLCoreTests/Fixtures/Modular/Effort/provenance.json). The archive includes reproducible generators/commands, independent-decode records, raw timing samples, build/source hashes and original compiler failures; generated binary/large pixel files are omitted and identified by hashes.

Complete higher-effort cumulative/simultaneous allocation admission, activity/learner sorting cancellation, wider corpus/profile/precision and concurrency qualification remain open. The sample cap alone does not admit all retained property/candidate arrays. Hosted Swift 6.2 and minimum-OS/device gates remain distinct. JPEG, VarDCT, animation, feature/platform and predecessor performance gates still prevent declaring Milestone 4 complete. PR26 is a dependency; no merge or production cutover is implied.
