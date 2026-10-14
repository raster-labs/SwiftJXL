# Modular learner performance qualification

Date: 14 October 2026. Contract: 0.10.0. Public encoding remains at effort 3.

This follow-up reduces the cost of PR28's bounded higher-effort work. Its base is PR28 `0ff82d1aa66cca66a5fed583aed742e360b5b438`; PR27 `ffeeef7e9f8807a6ad575ba416842df984bf8283` is the additional pre-admission reference. The pinned predecessor remains `57e81cb9e2411d1efac435b429a306a031744c1e`. These comparisons do not close the separate predecessor migration gates.

## Behaviour and ownership

Activity analysis now sorts once for both fixed percentiles and learned thresholds. A private sorted copy reuses its residual-token field for token buckets; the caller's original residuals remain unchanged. Only small threshold sets return, so analysis scratch ends before routing and costing. The original floor-based percentile rule, stable equal-property order, fixed-before-learned candidate order and strict first-wins size comparisons remain intact.

The bounded stable merge copies only the shorter run into independent scratch, at most half the input length. Forward merges favour left ties; backward merges favour right ties, preserving overall stability. All storage is initialised and both mutable buffer borrows are synchronous and nonescaping. Checkpoints bound the copies and merges to 1,024-element blocks; the standard library only sorts runs of at most 1,024 elements. Cancellation can leave the private working array partially sorted, but releases valid owned storage.

Greedy splitting counts each child before reserving index storage instead of reserving the complete parent twice. A second checkpointed pass retains the original sample order. Cumulative component reservations stay unchanged and conservative; this change does not relax admission or suppress cancellation/resource failures. Allocation, COW and runtime work still have no real-time cancellation guarantee.

## Executed qualification

| Configuration | Test declarations | Argument cases | Failures / skips |
| --- | ---: | ---: | ---: |
| debug | 42 | 254 | 0 / 0 |
| release | 42 | 254 | 0 / 0 |
| asan | 20 | 128 | 0 / 0 |
| tsan | 20 | 128 | 0 / 0 |

Debug/release cover eight affected suites; ASan/TSan cover four higher-effort suites, with no sanitizer diagnostics. All four runs and the release probe agree on final source hashes. The tests cover stable ties, uneven merge lengths, empty/singleton inputs, maximum residual tokens, learned boundaries crossing work blocks, policy-error propagation, exact budgets and aggregate memory limits.

Fifty-four small effort-1–9 streams and fourteen larger/control baseline/candidate streams independently decode through pinned `djxl` 0.12.0 with every expected sample exact. All tested bytes match PR28 and PR27. Forty-two budget comparisons cover efforts 7/9 and one, two and eight workers: both versions retain identical reservations and outputs with ample limits, and both reject one byte below the measured cumulative reservation. These are admission checks, not allocation telemetry.

## Controlled release comparisons

Both references reuse previously qualified release binaries after verifying all 98 core source hashes against their exact Git revisions. The candidate uses the same synthetic driver, compiler, optimisation flags and macOS 26 target. Each comparison has two blocks per implementation, five warm-ups and ten timed iterations per block. The first order is PR27/PR28/candidate/candidate/PR28/PR27; the repeat reverses it. No other local qualification job overlaps these timing runs. External system activity is not controlled. Timed stream hashes match the independent decodes.

Cells show initial / repeat changes; negative values are improvements.

| Case | Median vs PR28 | Median vs PR27 | Peak RSS vs PR28 | Peak RSS vs PR27 |
| --- | ---: | ---: | ---: | ---: |
| default-control | +2.61% / +1.01% | +1.18% / +1.01% | -1.14% / -0.33% | -1.94% / -0.82% |
| activity-gray | -14.26% / -14.52% | -10.19% / -11.36% | -1.83% / -1.95% | +2.51% / -4.14% |
| activity-rgba | -14.22% / -15.00% | -11.56% / -12.30% | -3.85% / -0.55% | -11.87% / -0.99% |
| small-control | -3.13% / -3.82% | +2.60% / +2.61% | -5.40% / +0.00% | -11.04% / +1.82% |
| single-gray-cap | -2.82% / -3.97% | +3.82% / +2.41% | -3.69% / +5.04% | +7.22% / +17.63% |
| single-rgba-cap | -6.33% / -6.13% | -0.77% / -0.56% | -5.45% / -9.80% | -3.67% / -6.35% |
| group-gray-cap | -6.22% / -6.17% | +0.48% / +0.32% | -15.64% / -11.03% | -6.81% / -7.72% |

The selected activity cases are 14.2–15.0% faster than PR28; selected large tree cases are 2.8–6.3% faster. All final latency comparisons stay below the repeated 5% regression threshold against PR27. However, the 512×511 single-grey peak RSS is 7.2% / 17.6% above PR27, and one comparison is 5.04% above PR28. The process-memory gate remains open; no release-baseline waiver is inferred from the latency improvement.

## Retained memory investigation

Earlier staged comparisons showed a repeated approximately 8.4% single-grey RSS increase against PR27, while other runs of that reference varied from roughly 54 to 58 MiB. Explicitly clearing the root-index temporary did not establish a benefit and was reverted. Exact child capacity reduced selected larger colour/grouped peaks; the extra counting pass is included in all final validation and comparisons.

The separate allocation-history diagnostic retains two processes per implementation at 0, 1, 10 and 100 timed iterations (with the driver's warm-ups where applicable). For the 512×511 greyscale case, candidate first-encode peaks were about 53 MiB, matching PR27 and below PR28's 55.3 MiB. At 100 timed iterations, candidate peaks were 57.6–60.3 MiB, versus PR27's 61.3–61.9 MiB and PR28's 63.9–68.7 MiB. Its timings are excluded from the controlled performance table. These observations demonstrate allocation-history sensitivity; they do not prove a particular allocator cause or a universal steady-state bound. Earlier outliers remain in the archive.

## Evidence and remaining gates

The [qualification index](Evidence/ModularEffortPerformance/qualification.json) records exact commands, source/test hashes, common-contract hashes, environment, raw medians/p95/spread, thermal states and remaining findings. The [raw archive](Evidence/ModularEffortPerformance/raw-evidence.zip) includes driver scripts, output logs, independent checks, successful final validation, earlier experiments and the initial sandbox macro-build failure. All seven common contract documents remain byte-identical. This is a review by the current coding agent, not an independent GitHub approval.

Hosted Swift 6.2/Linux checks, wider corpus and precision coverage, concurrent allocator/copy telemetry, public higher-effort admission, and minimum-OS/physical-device qualification remain open. Broader Modular predecessor, JPEG, VarDCT ARM-reference, animation and feature-reconciliation gates also remain open. Milestone 4 is incomplete; JXLSwift remains the supported production route.
