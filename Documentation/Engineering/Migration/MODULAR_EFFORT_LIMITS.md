# Modular candidate limits — 14 October 2026

## Observed failure and repair

The internal grouped encoder could ignore a workspace failure from an optional higher-effort activity candidate and return the effort-3 baseline. A pinned PR25 probe (`7ec288ce231091bd07c8f9aaacba487911deda02`) reproduces this with both two and eight workers: reserving exactly the baseline worker-result allowance, 1,280 bytes, permits the baseline but denies the next activity map. The old code silently returns byte-identical effort-3 output; the follow-up throws `ScalarModularError.resourceLimit` in both cases. This is a targeted worker-result reservation probe, not a complete encoder memory envelope or a failure of the public fixed-effort-3 profile.

Optional candidate costing, entropy construction and emission now propagate cancellation and resource failures. Ordinary format-unsuitable candidates remain optional. Pre/post checks also prevent an otherwise successful candidate, or an unrelated format error, from hiding a latched writer overflow, deadline or cancellation. Tokenisation, grouped Huffman costing and tree routing check every 1,024 samples. Pure `ModularTree.walk` format failures stay optional; they perform no allocation admission and routing supplies the policy checkpoints.

## Incremental shared-property reservation

Before `wpGreedyPerPixel` allocates, checked arithmetic validates dimensions, products and plane lengths, then reserves its additional workspace against the current operation budget. On 64-bit hosts, with `N = width*height*channels`:

| Mode | Additional cumulative reservation |
| --- | --- |
| Activity-only | `16*N + 96*(width+2)*channels + 256*(channels+3)` |
| Tree properties | `72*N + 96*(width+2)*channels + 256*(channels+3)` |

The sample term doubles the 8/36-byte visible array payload for capacity/transient overlap; predictor rows similarly reserve twice their 48-byte extended-column payload for each successive channel. Fixed allowances cover array/channel headers and rounding. It adds to existing reservations and does not make the effort-3 envelope sufficient for higher modes. Caller planes, grouped property collection, candidate buffers, sorting and learning still need full higher-effort admission. This reservation is not measured peak RSS or allocator telemetry.

## Executed qualification

Against PR25, contract 0.10.0 and predecessor pin `57e81cb9e2411d1efac435b429a306a031744c1e`:

- Debug, release, Address Sanitizer and Thread Sanitizer each pass 32 declarations / 202 argument cases on the same final 179 source/test hashes, without failures, skips or sanitizer diagnostics. New tests cover exact/cumulative property admission, invalid/overflowing geometry, cancelled/expired candidates, latched writer failures and the grouped fallback regression.
- All 54 new effort/case streams independently decode exactly with `djxl` 0.12.0 and match the previously independently verified PR25-compatible fixture bytes. The prior oracle baseline is explicitly reused, with source-equivalence proof; it is not counted as another newly executed oracle run.
- The paired policy probe reproduces the old bug and corrected behaviour against separately rebuilt PR25/follow-up libraries. Exact commands, hashes and results are in the archive.
- Initial closure-call syntax errors and sandbox macro-plugin build failures are retained separately from the corrected, passing runs.

See [qualification index](Evidence/ModularEffortLimits/qualification.json), [raw evidence](Evidence/ModularEffortLimits/raw-evidence.zip), [new regressions](../../../Tests/SwiftJXLCoreTests/ModularEffortLimitTests.swift) and [existing synthetic fixture provenance](../../../Tests/SwiftJXLCoreTests/Fixtures/Modular/Effort/provenance.json).

## Release timing and memory observations

Same Swift 6.4 optimisation, Swift 6 mode, complete concurrency checking, arm64 macOS 26.0 target and macOS 27.0.1 host as the prior qualification. Both baseline and candidate core libraries were rebuilt from their recorded sources. Two opposite interleavings use five warm-ups and ten timed iterations per block, twenty timed samples per implementation per case. No local build/test/profile runs overlap measurement. Thermal state is recorded; external system load is not measured. The probe is internal and serial, without a public operation budget context; the paired policy probe separately exercises two/eight workers.

Negative latency change is faster. Peak RSS is process-wide MiB, baseline → candidate. Raw records retain p95, spread, every timing and encoded size; all compared bytes are identical. The twelve larger benchmark-fixture oracle checks occur after timing and are retained separately. No speedup or complete algorithm-workspace claim follows from small differences.

| Case | Median change, initial / repeat | Peak RSS, initial / repeat |
| --- | --- | --- |
| default-control | +1.45% / +1.07% | 21.64 → 19.23 / 19.12 → 22.27 |
| gray-activity | +0.41% / -0.76% | 41.45 → 41.59 / 47.55 → 42.67 |
| rgb-activity | +0.60% / +0.99% | 114.61 → 114.67 / 114.59 → 120.97 |
| rgba-activity | +1.08% / +0.25% | 52.34 → 44.27 / 42.19 → 45.08 |
| tree-control | -0.17% / -0.43% | 13.64 → 13.81 / 13.69 → 14.03 |
| group-control | -0.15% / +0.16% | 11.44 → 11.03 / 11.06 → 11.09 |

All measured median latency changes are within 1.5%. RSS varies between interleavings: several second-run increases exceed 5%, but none repeats above that threshold in both runs; opposite-direction excursions are retained. This does not close peak-memory or steady-state qualification.

## Remaining qualification

Full higher-effort simultaneous/cumulative admission, sorting/learning cancellation and exact learner-sample bounds remain open. Public API and CLI effort remain fixed at 3; production limits, ownership, worker ceilings and all seven common contract files are unchanged. This local arm64 Swift 6.4 result does not establish hosted Swift 6.2, minimum-OS runtime, other platforms, complete public predecessor performance parity or release readiness. JPEG performance, VarDCT rate-distortion/ARM-oracle differences, animation steady-state and other Milestone 4 feature/platform gates remain separate. PR25 is a dependency; this follow-up does not merge it.
