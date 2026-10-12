# Modular owning-memory qualification — 12 October 2026

The ordinary optimised probe linked the unchanged `bfd12bc8b9eb19ded15a60175b305b9a7332abe2` SwiftJXL/SwiftJXLCore objects. All five cases passed with no skips. Exact build commands/object hashes, run commands and source hashes are in [validation.json](validation.json), [build.json](build.json) and [runs.json](runs.json). The probe source is [owning-memory-probe.swift](owning-memory-probe.swift). It uses public operations and package-only allocation-site instrumentation; it is not production code.

| Geometry/profile | Final sample bytes | Caller extra final allocations | Encoder working-plane payload sum | Decoder working-plane payload sum | Decode cumulative workspace reservation |
| --- | ---: | ---: | ---: | ---: | ---: |
| 512×512 grey16 | 524288 | 0 | 1048576 | 0 | 6918344 |
| 513×259 RGB16 | 797202 | 0 | 6377616 | 3188808 | 13291360 |
| 513×259 RGBA16 | 1062936 | 0 | 7972020 | 4251744 | 16783708 |
| 2048×2048 grey12 | 8388608 | 0 | 50331648 | 0 | 76355684 |
| 1024×1025 RGBA16 | 8396800 | 0 | 62976000 | 33587200 | 114715010 |

Each allocating decode recorded exactly one final allocation of the sample-byte size above; each source encode and caller decode recorded zero additional final allocations. Caller UUID identity, every sample, zeroed destination padding, identical encoding after changing only source-padding sentinels, and identical re-encoding from the padded destination passed. Source rows have 16 padding bytes, allocating output is packed, and caller output is padded.

Four simultaneous operations sharing one immutable source passed for each of the three smaller cases (12 operations total). Each operation encoded identical bytes and decoded into a distinct caller destination with exact samples and identity. Each of the five cases also exercised denied workspace admission before plane allocation, destination reuse after that preflight failure, cancellation at the beginning of an exclusive provider write, invalidation after cancellation, and rejection of a second write after sealing. These are functional ownership checks; no scheduler-overlap duration or performance claim is inferred.

The source review follows `CodecAPI` → `ModularStorageEncoder` / `ModularFrameDecoder` → `OwnedImageStorage`. Encoding borrows the supplied owner and widens directly into required signed Int32 algorithm planes. Decoding without transforms writes through borrowed channels; transform paths retain admitted signed algorithm planes until inverse transforms complete, then write final samples to caller storage. There is no extra packed decoded-image handoff. Swift array ownership moves into sealed storage without an explicit pixel clone. Array COW may occur in algorithm work; the admission ledger conservatively covers it.

The working-plane columns are cumulative payloads at instrumented allocation sites, **not peak live workspace, all allocator calls, or byte-copy totals**. The whole encoder admission also covers predictor candidates, entropy arrays, output growth and other scratch beyond these columns. Public peak-workspace measurements remain unknown. The signed transform workspace is necessary algorithm storage; it is not reported as a final-image handoff copy.

All caller-decode live heap observations increased by 48 bytes after completion while retaining the result. Allocating-decode deltas are in the raw reports. These macOS allocator snapshots complement direct ownership/source evidence; they do not prove total peak memory, universal absence of allocation, or a performance improvement. Other host work was active. No comparative RSS or latency claim is made.

The probe explicitly requests a 1 GiB workspace ceiling and 1.5 GiB aggregate operation ceiling, while preserving production defaults. The 2048² grey12 and 1024×1025 RGBA16 encoders need that larger cumulative admission envelope. The large cases are run sequentially. The configured limits are reservations, not observed physical allocation sizes.

Remaining separate gates include controlled predecessor/successor performance and peak-memory comparison, broader platform/release qualification, and the other codec migration stages. Existing independent-oracle and sanitizer results remain scoped to their recorded revisions; this ordinary-build probe does not replace them.

## Load-bearing stride and byte-order checks

Two deliberate implementation mutants changed `ModularSampleStorage.swift` in a separate detached worktree at the recorded runtime revision. The row-stride mutant substituted packed-row addressing in both borrowed output and encoder input; the byte-order mutant forced big-endian handling in both paths. Neither mutation touched the working feature branches. Each run executed the same two declarations / 68 parameter cases: 48 padded core destination cases and 20 public owning colour cases. The stride mutant failed with **70 recorded issues** (48 core and 22 public); the byte-order mutant failed with **42 issues** (22 core and 20 public). Restoring the original implementation passed all 68 cases with zero issues. These are assertion/error issue counts, not a claim that 70 distinct cases exist.

The first cold build timed out before executing tests. Its unrelated native-transcoder test compilation was stopped; the private test target was then restricted to the required test source while preserving fixtures. The manifest was unchanged, and all exclusions are recorded. The second mutant and restored run used Boolean locals for three unchanged equality comparisons to avoid rendering full arrays in diagnostics. The first mutant used the original assertions. Exact patches, original/diagnostic test-source hashes, commands, exit codes and source-restoration hashes are in [implementation-mutants.json](implementation-mutants.json). Compact logs retain every issue header and test summary; large array-dump lines are abbreviated. Full raw-log hashes and workspace locations remain recorded, including the 93 MiB first failure log stored compressed outside Git.
