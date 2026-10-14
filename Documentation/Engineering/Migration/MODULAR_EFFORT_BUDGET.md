# Higher-effort Modular admission and cancellation — 14 October 2026

This follow-up starts from PR27 `ffeeef7e9f8807a6ad575ba416842df984bf8283`, contract 0.10.0 and predecessor `57e81cb9e2411d1efac435b429a306a031744c1e`. It continues the internal effort-4–9 qualification. Public API/CLI encoding remains at effort 3, with its existing limits, ownership and worker policy.

## Allocation inventory

The caller must first admit the effort-3 encoder envelope, including original algorithm planes, RCT candidates, baseline residuals, entropy work and final output. Higher-effort components now debit the same operation-local workspace and aggregate-memory ledger before their allocations. Charges are cumulative and never released; concurrent candidates and retained winners therefore cannot reuse an allowance prematurely. The existing worker-map slot and single-section property reservations remain additive.

Let `N` be a component's sample count, `G` its group count, `C` its channel count, `K` its context count (at most 32), `M` the exact learning population (at most 256,000), `L` its leaf limit (16 or 32), and `B` the operation's admitted writer byte limit. All reservation products and sums use checked arithmetic.

| Component | Additional cumulative allowance | Covered allocations |
| --- | --- | --- |
| Activity or grouped tree collection | `128*N + 96*(min(width,512)+2)*G*C + 1024*G*C` | Rectangle copies; predictor rows; per-rectangle/pooled activity pairs or six-property/token arrays; append growth; percentile and sorting buffers; grouped flattened learning input |
| Activity threshold learner | `64*N + 128 KiB` | Stable sorting buffers, token buckets, log table, depth-at-most-three histograms and small range/threshold arrays |
| Each routing candidate | `32*N + 256*G` | Context/token tuples and group arrays, including capacity overlap; every attempted fixed or learned threshold set is charged |
| Each costing candidate | `12*N + 2 MiB*K + 1024*G` | Symbol/cluster buffers, histograms, retained Huffman/ANS alternatives, bounded table construction, tree/header writers and group inventory |
| Selected candidate emission | `64*N + 1 MiB*(6+K*G) + 6*B*(G+1)` | ANS pending/refill arrays, per-group inversion tables, global/group writers and Data conversions; all groups are charged regardless of worker count |
| Separate capped sample arrays | `64*M` | Six Int32 properties and one Int bucket per sample with capacity/transient overlap; omitted for an aliased single-section population already below the cap |
| Greedy learner | `(80+32*(L-1))*M + 4 MiB` | Log, packed/radix, root-index and output-context arrays; both full-capacity child-index arrays at every possible split; all bounded nodes/histograms/tree output |

The greedy bound allows a maximally unbalanced sequence of splits, rather than assuming every level halves the sample set. The tree collector's 128-byte sample allowance includes dynamically growing property arrays. Costing and emission charge separate tables even when some immutable values can share storage. These are deliberately conservative reservation bounds, not allocator measurements or a claim that every admitted size fits an operating system's process limit.

This closes the previously uncharged higher-effort component inventory for the current bounded encoder paths. It can reject work that the old internal path accepted without accounting for these components. It can also reject work whose actual peak allocation would fit: reducing that conservatism requires a separately validated lifetime/reuse design. Success at an exact reservation boundary is a ledger test, not evidence of peak RSS or absence of all runtime allocations.

## Cancellation and lifetime

Activity collection, flattening, routing, threshold histogram/sweep loops and greedy log/histogram/packing/partition/context loops check at intervals of at most 1,024 samples. The radix learner checks its histogram, scatter and copy passes. Activity sorting uses stable runs of at most 1,024 values followed by merges checking every 1,024 output moves. Small context, tree, histogram and threshold loops have fixed bounds. Existing entropy checks and pre-publication checks remain in force.

The sort retains stable ties and the prior strict-less candidate selection. Policy failures propagate through optional candidates under PR26's rules. Partial internal arrays are discarded; workers still join before return. Unsafe buffer access remains synchronous and confined to the sort/radix closure; no pointer is stored or transferred to workers.

The bound describes algorithm work between checkpoints. Allocation, copy-on-write, allocator/runtime copies and scheduler delays are not interruptible real-time units. No universal wall-clock cancellation guarantee or device-memory guarantee follows from these local tests.

## Qualification status

Debug and release each pass 40 declarations / 249 argument cases. Address Sanitizer and Thread Sanitizer each pass the four affected higher-effort suites: 18 declarations / 123 cases. All final configurations use the same 181 source/test hashes, with zero failures, skips or sanitizer diagnostics. The final learner fixture has uneven equal-property runs crossing 1,024-sample blocks. Tests cover exact and one-byte-under cumulative admission, aggregate memory rejection, checked overflow, stable sorting at run boundaries, and cancellation/resource failures injected throughout both learners.

The 54 small candidate streams match PR27 bytes and decode every sample exactly through independent `djxl`. Seven larger/control cases are independently decoded on both sides (14 decodes), also with identical bytes. Every timed output matches its independently decoded hash. Forty-two separate old/new budget comparisons cover seven shapes, efforts 7/9 and one/two/eight workers: ample-budget outputs match, while every candidate rejects the old incomplete allowance with `resourceLimit` and every baseline accepts it. The candidate reservations range from about 22 MiB to 1,100 MiB under explicit larger trial limits; these are ledger charges, not measured allocation.

See [qualification index](Evidence/ModularEffortBudget/qualification.json), [raw evidence](Evidence/ModularEffortBudget/raw-evidence.zip), [regression tests](../../../Tests/SwiftJXLCoreTests/ModularEffortBudgetTests.swift) and [synthetic fixture provenance](../../../Tests/SwiftJXLCoreTests/Fixtures/Modular/Effort/provenance.json).

## Controlled performance and open trade-off

The release probe compares exact PR27 with this implementation on local macOS arm64 / Swift 6.4, using five warm-ups and ten timed encodes per block. Each comparison interleaves two blocks per implementation (20 samples per side); the repeat reverses the order. Thermal state is nominal in every recorded block. No agent-owned build, test, oracle or policy work overlaps timing. The internal probe is serial and has no operation-budget context; budget enforcement is qualified separately. Raw samples, median/p95/spread, throughput, size, process RSS and hashes are retained; peak algorithm workspace, allocation/copy counts and concurrent steady state are not measured.

| Case (effort) | Median latency change, first / repeat | Process peak RSS MiB, baseline → candidate, first / repeat |
| --- | --- | --- |
| default-control (3) | +0.75% / -2.91% | 9.56 → 9.53 / 9.56 → 9.53 |
| activity-gray (7) | +3.86% / +4.26% | 12.94 → 13.66 / 12.94 → 13.64 |
| activity-rgba (7) | +2.76% / +2.54% | 14.17 → 14.09 / 14.16 → 15.11 |
| small-control (8) | +7.23% / +6.74% | 13.72 → 13.98 / 13.91 → 14.11 |
| single-gray-cap (8) | +6.69% / +6.61% | 57.80 → 58.16 / 53.70 → 58.19 |
| single-rgba-cap (9) | +5.95% / +5.56% | 102.94 → 107.98 / 102.94 → 104.86 |
| group-gray-cap (9) | +6.89% / +6.92% | 87.98 → 89.19 / 87.98 → 89.72 |

The first bounded-sort implementation reproduced approximately 8–11% tree-case overhead. The retained investigation moved checkpoint calls outside tight merge, radix, histogram, packing and entropy-sweep element loops while retaining at-most-1,024-element blocks. This reduced the cost, but all four final tree-learning cases still exceed the 5% median-latency investigation threshold in both comparisons. The effort-7 activity-grey case also shows a repeated process peak RSS increase of about 5.5%; the stable merge uses an admitted full-length scratch array, although process RSS does not isolate allocator-level causation. Other larger RSS excursions do not repeat in both orders. Effort 3 has no repeatable latency or RSS regression. Encoded sizes and bytes are unchanged throughout.

**The PERF-03 trade-off remains open for review.** Bounded cancellation and complete component admission are the intended safety benefit; the measured internal higher-effort cost is explicit. This draft does not waive the performance gate, accept a new release baseline or establish stable-release readiness. The superseded sources, prior successful tests and all diagnostic/interleaved measurements remain in the archive.


## Remaining gates

Public higher-effort controls remain unavailable. Wider profile/precision/corpus coverage, concurrent steady-state allocator telemetry, minimum-OS/device checks and broader predecessor performance remain open. Hosted Swift 6.2 and both Linux architectures must qualify this follow-up separately. JPEG, VarDCT, animation and other feature/platform gates still prevent declaring Milestone 4 complete. JXLSwift remains the supported production route.
