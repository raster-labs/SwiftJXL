# Modular greyscale memory qualification

Date: 14 October 2026. Contract: 0.10.0. Public encoding remains at effort 3.

This follow-up investigates the 512×511, 16-bit greyscale effort-8 process-memory regression recorded by PR29. The immediate baseline is PR29 `f8083c901fdb784111c7f296517c45d27a61db74`; PR27 `ffeeef7e9f8807a6ad575ba416842df984bf8283` remains the pre-admission reference. The pinned predecessor is `57e81cb9e2411d1efac435b429a306a031744c1e`. PR28 was reviewed and merged separately at `127752d1b9fed66d904762febc045ded22f96565` after all 12 exact-head hosted checks passed.

## Behaviour and ownership

Greedy tree nodes now hold ranges in one index array. Splitting a leaf partitions only its range in place, removing the per-child allocations and separate counting pass. The index array contains at most 256,000 integers; unrelated sibling ranges remain untouched. All storage is initialised and the mutable buffer borrow is synchronous and nonescaping. Partition work checks cancellation every 1,024 indices. An error unwinds private storage without modifying caller properties or tokens.

Private leaf encounter order can change. This does not change split selection: integer histogram counts are the same, and each property sweep sorts the same packed property/token values, so floating-point accumulation and tie decisions retain their previous order. Returned contexts still use original sample indices. A new test independently walks the decoder tree for uneven, permuted samples and 2, 8 and 32 leaves.

The conservative PR28 admission formula is retained, including its historical allowance for child storage. This deliberately overestimates the workspace charge and preserves existing caller limits. The public API, CLI effort, candidate selection and fidelity are unchanged. Allocation, runtime work and scheduling still have no real-time cancellation guarantee.

## Executed validation

| Configuration | Declarations | Argument cases | Failures / skips |
| --- | ---: | ---: | ---: |
| debug | 43 | 257 | 0 / 0 |
| release | 43 | 257 | 0 / 0 |
| asan | 21 | 131 | 0 / 0 |
| tsan | 21 | 131 | 0 / 0 |

The debug/release runs cover eight affected suites; ASan/TSan cover four higher-effort suites without sanitizer diagnostics. Final source/test hashes match every validation run and the frozen release probe. Fifty-four small effort-1–9 streams and fourteen larger/control baseline/candidate streams independently decode with pinned `djxl` 0.12.0 and exact expected samples. All tested bytes match PR29; timed streams also match PR27. Forty-two comparisons retain identical worker-budget reservations and output, with both versions rejecting one byte below the reservation. These budget checks are separate from allocator measurements.

## Controlled comparisons

Existing PR27/29 release libraries were reused after verifying all 98 core source hashes against their exact revisions. Each case has two blocks per implementation, five warm-ups and ten timed iterations per block. The initial order is PR27/PR29/candidate/candidate/PR29/PR27; the repeat reverses it. No local build, test or diagnostic workload overlaps these measurements. External system activity is not controlled. Raw medians, p95, spread, thermal states, binary hashes and commands are in the evidence.

Cells show initial / repeat changes; negative values are improvements.

| Case | Median vs PR29 | Median vs PR27 | Peak RSS vs PR29 | Peak RSS vs PR27 |
| --- | ---: | ---: | ---: | ---: |
| default-control | -1.04% / -0.09% | -0.85% / -0.55% | -1.48% / -1.48% | -2.28% / -2.28% |
| activity-gray | -1.06% / -0.53% | -11.77% / -11.12% | +1.75% / -30.94% | +5.19% / +3.26% |
| activity-rgba | +1.06% / -0.21% | -11.11% / -12.01% | -0.45% / -2.19% | -1.54% / -1.43% |
| small-control | -2.20% / -1.98% | +0.83% / +0.30% | -3.70% / -3.70% | -2.05% / -2.05% |
| single-gray-cap | -2.41% / -2.30% | +0.11% / +0.24% | -7.34% / -7.05% | -4.07% / -5.52% |
| single-rgba-cap | -1.72% / -0.93% | -1.70% / -1.62% | -0.23% / -5.73% | -8.02% / -8.04% |
| group-gray-cap | -2.67% / -2.52% | -1.97% / -2.08% | -6.06% / -12.77% | -12.70% / -18.04% |

No repeated final scoped threshold breach; broader qualification remains open. This is scoped serial synthetic evidence, not a general steady-state memory bound or release-baseline waiver. Earlier PR29 regressions remain recorded in the prior report.

## Allocation investigation

Initial endpoint probes found similar live payload after encoding but variable allocator reservations and process peaks. Instrumented PR27/29 stage boundaries associated a later PR29 RSS increase with greedy learning; that correlation did not prove a specific allocator cause. A two-buffer stable-partition experiment did not reliably improve on PR29 and was replaced by the single-owner implementation. Both experiments and the original observations are retained.

The final diagnostic uses 30 iterations after the first encode and five warm-ups. Its timing results are excluded from the controlled table. Values below are MiB, with two fresh processes per implementation.

| Implementation | Peak process RSS | Final allocator reservation | Final live zone payload |
| --- | ---: | ---: | ---: |
| pr27 | 62.80 / 55.67 | 56.00 / 44.00 | 1.41 / 1.41 |
| pr29 | 59.78 / 58.88 | 48.00 / 48.00 | 1.41 / 1.41 |
| candidate | 54.84 / 53.70 | 52.00 / 48.00 | 1.41 / 1.41 |

These are whole-process RSS and allocator totals sampled at encode boundaries. They do not measure peak live algorithm workspace, per-operation allocation counts or copy bytes. The diagnostic itself retains records, so endpoint growth is not attributed to an encoder leak. The allocator's high-water field returned zero and is treated as unavailable. No universal bound or concurrent steady-state claim is inferred.

## Evidence and remaining gates

The [qualification index](Evidence/ModularGreyMemory/qualification.json) and [raw archive](Evidence/ModularGreyMemory/raw-evidence.zip) preserve exact commands, source/test and contract hashes, original and final diagnostics, validation, independent decodes, admission checks and both controlled comparisons. The seven common contract files are unchanged. Review was performed by the current coding agent, not an independent GitHub reviewer.

Hosted Swift 6.2/Linux checks, broader profiles/precision/corpus, concurrent allocator/copy telemetry, public higher-effort qualification and minimum-OS/physical-device tests remain open. Broader Modular predecessor performance, JPEG, VarDCT ARM-reference differences, animation and feature reconciliation also remain open. Milestone 4 is incomplete; JXLSwift remains the supported production route.
