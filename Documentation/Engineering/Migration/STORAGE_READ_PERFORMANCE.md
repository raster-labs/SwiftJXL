# Public sample-read investigation

13 October 2026; contract distribution 0.10.0. Base: merged PR22, `3069f05500c49d704cd1de2a64b8fe906564adb3`. Original pre-span baseline: `423b8ae404ca5029a6a5fa1abe736d57dc8f0a96`. The pinned codec predecessor remains `57e81cb9e2411d1efac435b429a306a031744c1e`; this storage experiment does not compare codec throughput with that predecessor.

## Change and bounds proof

`Image.sampleUInt16` now assembles its two sample bytes directly inside the retained storage borrow. It keeps the unsigned-greyscale profile check, rejects coordinates before arithmetic, and checks the provider's actual borrowed capacity on every call. The immutable, constructor-validated descriptor proves that each admitted coordinate's two-byte extent lies within `requiredByteCount`; the capacity guard inside the borrow therefore covers both loads. The additional private load helper repeated an extent check already established by those checks and is removed. Byte access remains independent of the physical base address's alignment and uses no OS-27-only API.

The provider remains responsible for retaining sealed storage throughout the synchronous borrow. No pointer escapes, owner changes, new allocations, pixel copies, precision conversion, resource-limit changes or public declarations are introduced. The writer and codec paths are unchanged. Existing shortened-provider and extreme-coordinate regressions exercise rejection; the strided-row regression now also reads every sample through the public accessor, including both byte orders, pixel gaps, prefixes, width one and the last sample ending exactly at allocation capacity.

## Fixed comparisons and retained failures

The archived original and PR22 benchmark binaries are reused with verified hashes, retained source files and the same Swift 6.4 `-O`/whole-module settings as the candidate. All use the unchanged historical public greyscale probe, renamed to SwiftJXL. The exact core objects reused by candidate builds are checked against current source hashes. Independent untimed preflights check every public sample against its analytical value as well as the underlying two bytes, all padding bytes and retained allocation identity: 4,457,920 samples and 20,968 padding bytes per library.

The first candidate captured two scalar values instead of the descriptor. Its sandboxed timing attempt produced sample data but the resource wrapper exited 1 because `sysctl kern.clockrate` was denied. Two subsequent resource-enabled comparisons did not support retaining that change: the 512×511 read result changed by −1.05% / +1.47% against PR22 and tiny-image reads were over 8% slower than the original. This candidate is discarded; its source, hashes, failed wrapper output and measurements remain under [StorageReads](Evidence/StorageReads).

Direct reads then improved 512×511 medians by 2.68% / 3.47% against PR22 in the original five-warmup/twenty-sample protocol. However, the 64×63 original-baseline median changed from 85.396 to 45.771 microseconds between fresh runs; its candidate-versus-original result changed from +1.20% to +8.24%. These observations are retained. They do not support a stable tiny-image comparison, and thermal state alone did not explain them.

One further fixed pair added ten interleaved 2048×2047 trials per library before the existing five warmups and twenty measurements per size. This separates a sustained warm workload from the start-of-process timing variation; it does not establish its scheduler/frequency cause or erase the earlier result. The second run uses fresh processes and reversed timed order. No builds, tests, sanitizers or profiling ran during the accepted measurement windows. All reported thermal states were nominal, with AC power recorded. Host scheduling/frequency is observed rather than laboratory-controlled.

| Image | Read vs PR22, first / repeat | Read vs original, first / repeat |
| --- | ---: | ---: |
| 64×63 | −5.45% / −2.06% | −1.64% / +4.62% |
| 512×511 | −3.17% / −3.20% | +1.86% / +1.65% |
| 2048×2047 | −1.92% / −2.00% | +3.15% / +2.92% |

Raw samples, median, p95, minimum/maximum, commands and executable/source hashes are retained in every comparison. Process high-water RSS for the final candidate is 18,432,000 / 18,399,232 bytes versus PR22's 18,382,848 / 18,415,616 bytes (less than 0.3% difference). RSS is not peak algorithm workspace or direct allocator telemetry. Source review finds no added allocation or copy; no new measured codec-memory claim follows.

These standalone comparisons retain the archived macOS 27 target so they can link the existing core module. Production deployment floors remain 26.0. Minimum-OS, physical-device and native Intel runtime coverage remain unverified.

## Disposition

The retained direct-read change has a modest repeated benefit against PR22 and reduces the investigated 512×511 original-baseline gap below the existing 5% threshold in both original-protocol comparisons and both sustained-warm comparisons. This resolves that scoped warm-read finding on this host. The start-of-process tiny-image variation remains explicitly unresolved; no cold-latency claim or threshold waiver is made. Original failures in [STORAGE_PERFORMANCE.md](STORAGE_PERFORMANCE.md) remain historical evidence.

Affected debug/release and separate sanitizer outcomes, exact commands, case counts and final source hashes are in [validation.json](Evidence/StorageReads/validation.json). Unchanged broader qualification is reused from PR22, without relabelling it as a full run of this candidate. Hosted checks on the submitted revision, broader codec performance, original ARM reference differences, feature reconciliation and unavailable runtime gates remain separate. Milestone 4 is in progress; Milestone 5 is pending. No release or production cutover follows from this result.
