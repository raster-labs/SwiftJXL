# Modular internal effort qualification — 13 October 2026

## Scope and result

Against main `0a4abd3459143411bd93130b0a49ce63187d2481`, single-section effort 4–7 encoding now retains only the activity property and residual token. The unused five tree properties and token bucket are omitted. The visible property-array payload falls from 36 to 8 bytes per sample on this 64-bit host. This excludes predictor rows, transformed planes, candidate outputs, array capacity and learner scratch. It is not a complete workspace bound.

The shared pass now checks cancellation/deadline before allocation, each row and every 1,024 columns; candidate selection checks again after stage B. The weighted predictor order, candidate ordering and tested codestreams are unchanged. No borrowed pointer, public storage owner, full-image hand-off, production limit or worker policy changes. Public API and CLI remain fixed at effort 3.

Contract 0.10.0 and all seven common contract documents are unchanged. Pinned predecessor `57e81cb9e2411d1efac435b429a306a031744c1e` remains the migration reference; this comparison uses current SwiftJXL main, not a new predecessor measurement. Existing predecessor gaps remain open.

## Correctness and safety evidence

- Six synthetic cases × efforts 1–9: all 54 original-main streams and all 54 candidate streams independently decoded by libjxl `djxl` 0.12.0 with exact dimensions, channel count, precision and sample bytes. All candidate streams match the baseline bytes. This corpus covers grey 8/16-bit, RGB 8-bit and RGBA 16-bit, including horizontal and vertical 512-pixel group boundaries. It does not cover every bit depth, grey-alpha or maximum dimensions.
- Efforts 1–3 share the retained effort-3 fixture and efforts 4–7 share effort-7 bytes on this corpus. Twenty-four golden files retain rungs 3, 7, 8 and 9. Fixtures are deterministic synthetic data under Apache-2.0, generated with seed 20261013; see [provenance](../../../Tests/SwiftJXLCoreTests/Fixtures/Modular/Effort/provenance.json).
- The new property tests compare compact and full predictor values, including signed transform-like input, and verify cancelled/expired work rejects before allocation. Full cancellation coverage through every higher-effort stage is still open.
- Debug, release, Address Sanitizer and Thread Sanitizer each passed 25 declarations / 191 argument cases in the affected five suites, with no failures, skips or sanitizer diagnostics. After correcting two explanatory comment blocks, final debug repeated the same scope successfully. The retained build and sanitizer sources differ from the final source only in those comments; the evidence pack checks this explicitly. No decoder experiment code remains.
- A final debug attempt was blocked by the sandbox's compiler-cache permissions before any test ran. Its report is retained; the authorised retry passed. The earlier wrong-grey-entry harness attempt and over-budget profiling attempt are also retained and are not codec failures.

Commands, source/test hashes, test logs and XML are retained in [qualification.json](Evidence/ModularEffort/qualification.json) and [raw evidence](Evidence/ModularEffort/raw-evidence.zip). The primary test is [ModularEffortTests.swift](../../../Tests/SwiftJXLCoreTests/ModularEffortTests.swift); the reusable probe is [modular-effort-benchmark.swift](../../../Scripts/TestSupport/modular-effort-benchmark.swift).

## Controlled release comparison

Both libraries were rebuilt from source with Swift 6.4, `-O`, whole-module optimisation, Swift 6 mode and complete concurrency checking, targeting arm64 macOS 26.0. The host actually ran macOS 27.0.1; this is not minimum-OS runtime proof. The internal probe uses the serial fallback without a public budget context. Comparisons use separate processes in ABBA order, then BAAB, with five warm-ups and ten timed iterations per block: twenty timed samples per implementation per comparison. No build, test or profiling job ran concurrently with the measurements. Recorded thermal states were nominal; external system load was not measured.

The raw records include median, p95, minimum/maximum, encoded size, RSS and every timing sample. Independent decoding of all twelve timed fixtures was performed after the measurements, not asserted as a preceding preflight. Every block retains the same bytes.

Negative latency change is faster. RSS is process peak, in MiB, baseline → candidate. Small differences are not claimed as speedups.

| Case | Median change, initial / repeat | Peak RSS, initial / repeat |
| --- | --- | --- |
| default-control | +5.97% / -0.94% | 20.11 → 23.38 / 19.09 → 19.08 |
| gray-activity | -0.21% / -0.38% | 47.53 → 43.42 / 47.53 → 43.48 |
| rgb-activity | +0.19% / -1.24% | 135.62 → 125.84 / 137.88 → 115.95 |
| rgba-activity | -1.21% / -0.25% | 54.20 → 41.23 / 49.44 → 41.22 |
| tree-control | +2.56% / +2.64% | 13.61 → 14.77 / 13.61 → 13.62 |
| group-control | +2.29% / +0.91% | 10.97 → 10.83 / 10.97 → 10.83 |

The retained benefit is reduced temporary property storage and lower observed RSS for activity-heavy cases, not an encode speedup. The effort-8 control is about 2.6% slower in both comparisons. The initial effort-3 latency/RSS excursion did not repeat; its full spread is retained. Peak algorithm workspace, allocation counts, copy-byte telemetry and concurrent steady-state memory were not measured here.

Compression choices are unchanged. For example, grouped RGB retains 26,981 / 26,370 / 24,628 / 24,248 bytes at efforts 3 / 7 / 8 / 9. Vertical RGBA retains 53,767 / 52,888 / 50,969 / 51,102 bytes: higher effort is not guaranteed to produce monotonically smaller output.

## Discarded decoder experiment

Profiling a retained pre-PR23 decoder suggested repeated coordinate calculations in the gradient loop. A direct-coordinate experiment was compiled and independently checked on nine public encode/decode cases against current main, twice in opposite order. Although greyscale decoding improved about 7–10%, RGB8 slowed 5.73% / 6.16% and grouped RGBA16 slowed 5.45% / 6.74%. The experiment was reverted. Its patch, unexecuted experimental unit-test source, exact source hashes, profiling record and both measurements remain in the archive. The inherited `predecessor` field in those two public measurement files means current SwiftJXL main, not JXLSwift. These results do not qualify the retained effort-only decoder, which is unchanged.

## Remaining gates

Before exposing higher efforts, complete the simultaneous/cumulative workspace ledger, candidate policy-error propagation, bounded learner/sort checkpoints and an exact learning-sample cap. The current floor-division sample stride can exceed the intended approximate cap. Then qualify tight resource limits, cancellation during work, multi-worker execution, more precision/alpha profiles and larger inputs before adding codec-specific public or CLI controls.

Public Modular latency gaps against the predecessor remain open, alongside allocation/steady-state and wider platform gates. Swift 6.2 and hosted checks for this branch have not run. JPEG performance, VarDCT rate-distortion/ARM-oracle differences, animation steady-state behaviour and remaining feature/platform qualification are separate Milestone 4 work. This checkpoint does not complete Milestone 4 or authorise production replacement, merge or release.
