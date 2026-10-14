# Modular precision, group edges and concurrent ownership

Date: 14 October 2026. Contract 0.10.0. Based on merged PR30,
`6f1ede976a5e99a6d7c6529865f57cf6c9be7169`, whose tree matches validated
`c4a2b0c1ca16d0d0975b537e292608bdb5d8a3c5`. The predecessor remains
`57e81cb9e2411d1efac435b429a306a031744c1e`. Public effort stays 3.

## Scope and gaps

This change adds tests and engineering evidence only. No production source,
public signature, dependency, contract, resource limit or codestream algorithm
changes. The existing effort matrix covered greyscale/RGB8, greyscale/RGBA16
and thin horizontal/vertical groups. It lacked two-channel greyscale-alpha,
intermediate colour precision, exact group-edge transitions and concurrent
higher-effort budget isolation.

[ModularProfileTests](../../../Tests/SwiftJXLCoreTests/ModularProfileTests.swift)
adds 17 deterministic synthetic profiles at efforts 3, 7, 8 and 9:

- Greyscale-alpha at every precision from 8 through 16 bits.
- RGB at 9, 11, 13 and 15 bits; RGBA at 10, 11, 14 and 15 bits.
- Horizontal and vertical extents 511, 512 and 513; 1×513 and 513×1 tails;
  small textured images, ramps, zero/max samples and nonzero colour under
  zero straight alpha.

These are pairwise additions, not every geometry × precision × layout.
Every stream must be identical with one and eight workers. Allocating decode
checks every logical sample, precision and alpha. Direct decode uses reversed
physical planes, big-endian words, different row strides, pixel gaps and guard
bytes; the complete destination, including its padding, is checked. Allocation
site counters require no additional final pixel allocation on that direct path.

[ModularProfileLifetimeTests](../../../Tests/SwiftJXLCoreTests/ModularProfileLifetimeTests.swift)
adds six public effort-3 cases: horizontal/vertical grey-alpha and horizontal
RGBA, each with straight and premultiplied alpha. Four child operations share
one sealed, padded planar source after the caller releases its reference.
Two succeed, one cancels after the real encoding borrow and its joined workers,
and one fails admission before allocating planes. The successful streams and
re-encodes agree. Scoped borrow counters settle at zero and the read-owner
wrapper is destroyed exactly once after all children finish. All state is
protected by `Mutex`; no unchecked concurrency annotation or pointer owner is
introduced.

The pinned predecessor's `RobustnessTests.swift` was inventoried: its wider
geometry sweep uses effort 3 with 8/12/16-bit profiles. Prior predecessor
baseline results remain in the migration record. This test-only addition does
not rerun or claim a new predecessor performance comparison. Existing 1–7-bit
decoding, ICC, transfer and other fixture qualification is reused, not recounted
as newly executed coverage.

## Resource boundary found during qualification

The initial matrix used a 256 MiB workspace allowance. Four grouped effort-9
RGB/RGBA cases passed with one/two workers but correctly rejected at eight.
A separate probe reproduced all four at both allowances. At eight workers,
successful cumulative reservations were 275,180,176–291,524,032 bytes. They
include conservative candidate/table/writer charges, not simultaneous heap use.

The final correctness matrix uses the existing 512 MiB workspace and 1 GiB
aggregate ceilings. Four dedicated regressions retain the 256 MiB refusal and
verify that it cannot return a successful fallback. Production admission is
unchanged. Twelve concurrent tests additionally share immutable samples across
two successful exact-budget operations, one one-byte-short budget and one
cancelled budget. Failure must remain local and later reuse must succeed.

## Validation and measurements

Exact commands, hashes, results, retained initial failures and ordinary-build
observations are in [the qualification report](Evidence/ModularProfiles/qualification.json)
and [raw evidence](Evidence/ModularProfiles/raw-evidence.zip). Debug, release,
Address Sanitizer and Thread Sanitizer each passed 4 declarations / 90 argument
cases, with no failures, errors or skips and no sanitizer diagnostics. Each
configuration independently decoded 74 streams exactly (68 internal profiles
and six public alpha/lifetime sources). The release retry passed after the
sandbox blocked debug-symbol generation; the failed build executed no tests.
External
decoding is test-only and required by the qualification runner; ordinary offline
unit tests do not claim that oracle coverage.

The ordinary release probe reuses the PR30 core library after verifying all 98
source hashes and the recorded probe binary. Each of three workloads runs five
warm-up plus twenty observed batches, with four operation scopes and two workers
per operation. Each batch has two byte-identical successes, one resource refusal
and one cancellation before admission. Cases are 513×7 grey-alpha11 effort 9,
7×513 RGBA11 effort 9, and 513×127 grey-alpha13 effort 8.

| Workload | Cumulative admission per operation (bytes) | Sampled process heap maximum (bytes) | Process peak RSS (bytes) |
| --- | ---: | ---: | ---: |
| Grey-alpha11, 513×7, effort 9 | 221,526,624 | 3,399,312 | 15,056,896 |
| RGBA11, 7×513, effort 9 | 258,244,032 | 5,775,184 | 22,347,776 |
| Grey-alpha13, 513×127, effort 8 | 402,956,128 | 44,212,384 | 68,780,032 |

Each probe observed four active operation scopes and exactly 50 successes,
25 resource refusals and 25 cancellations across its 25 batches. All three
representative codestreams also decoded independently to exact samples. Live
heap rose by 640 bytes between the first and last of the twenty measured
post-batch endpoints in each process. The harness and runtime are included;
this bounded observation does not establish leak freedom or long-run stability.

Process peak RSS, live-heap endpoints and 2 ms sampled heap observations are
reported separately from cumulative budget reservations. Sampled heap can miss
short peaks and includes the harness/runtime. These observations do not measure
exact global allocation counts, total copies, or peak algorithm workspace.
Batch durations are retained for reproducibility, not a speedup claim. No hot
path changed, so a repeated baseline/candidate performance comparison is not
applicable.

## Remaining gates

Higher public effort is not enabled or fully qualified. Wider two-dimensional
groups, larger/DC boundaries, complete precision/layout/colour combinations,
real-world corpus, exact allocator/copy instrumentation and process-wide
admission across independent operations remain open. Scope counters are not a
proof of simultaneous execution at every instruction. Cancellation checkpoints
do not interrupt allocator/runtime work in real time.

Local Swift 6.4 arm64 validation is not hosted Swift 6.2/Linux or minimum-OS,
native Intel, Watch or physical-device evidence. Broader predecessor performance,
VarDCT/JPEG/animation, feature reconciliation and release gates remain separate.
Milestone 4 is incomplete and JXLSwift remains the production route.
