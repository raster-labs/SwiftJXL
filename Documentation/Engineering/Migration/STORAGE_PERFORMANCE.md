# Sample-storage performance investigation

Follow-up: [public sample-read qualification](STORAGE_READ_PERFORMANCE.md) records the subsequent PR22-based investigation, rejected capture experiment, retained direct reads and remaining start-of-process timing uncertainty. The original comparisons below are preserved.

Contract distribution 0.10.0; 13 October 2026. This record qualifies the synchronous `ImageDestination.writeUInt16` sample helper. It does not measure codec throughput or complete Milestone 4.

## Historical finding and current source

The preserved [Swift 6.4 record](../Swift64/README.md#performance-investigation) reports a repeated 64×63 write regression of 6.46% / 6.47% after span adoption. It used the shared implementation through a SwiftJ2K consumer. That finding remains valid for those recorded sources and binaries.

Commit `8d601c972ff310e815ac3c5cea2fed9edd1a8edd` subsequently replaced span operations with portable byte-wise helpers for the OS 26 baseline. The merged SwiftJXL baseline for this investigation is `aa6d75c7028e0e3eda4e8ce06fdd60907ecd59fd` (PR21). Its writer checks each sample extent, and it contains no span construction. Repeated span construction cannot therefore explain its current performance.

Fresh same-toolchain builds compare that merged baseline with the original pre-span SwiftJXL revision `423b8ae404ca5029a6a5fa1abe736d57dc8f0a96`. The original `Image.swift` SHA-256 is `a10dda5b5d33b63aec4afb4eb060a3a2d8017dbb9bc0c3b1059a4498f77222e5`, identical to the original shared-source benchmark record. Both fresh comparisons found a current write regression: 9.45% / 10.48% at 64×63, 12.24% / 12.14% at 512×511 and 13.26% / 14.35% at 2048×2047. This is a comparison of complete public paths: ownership, admission and validation also evolved. It is not an isolated measurement of span overhead.

## Bounded change

The writer caches its immutable dimensions and byte order, computes the row payload once, and checks the full row extent before entering the sample loop. Descriptor construction already checks dimensions, offset/stride arithmetic, row non-overlap and capacity. Within the positive validated width, `rowOffset + x * pixelStride` and its second byte lie inside the admitted row. Byte writes initialise even uninitialised external sample storage and do not require physical alignment. No pointer escapes the synchronous exclusive borrow.

The callback remains in row-major order with one meaningful-precision check per sample. Cancellation remains checked once per row and at the existing write/publication boundaries. Throwing callbacks still invalidate the destination. Single-pixel widths, pixel gaps, row padding and a final row ending exactly at its last sample retain their semantics. The change adds no pixel or workspace allocation; allocation identity is verified separately. No public API, codec, dependency, resource ceiling or common contract changes.

## Controlled measurements

The unchanged historical benchmark probe was renamed from SwiftJ2K to SwiftJXL. It records allocation, write, public per-pixel read and total duration separately for 16-bit little-endian rows with eight padding bytes. Every timed operation verifies the expected analytical checksum. An additional untimed preflight checks individual sample bytes, padding and allocation identity against the exact benchmark libraries.

All comparisons use Swift 6.4, `-O`, whole-module optimisation, Swift 6 mode and complete concurrency checking on the same macOS 27 arm64 host on AC power. Five warm-ups precede twenty interleaved observations per implementation and size. A second fixed comparison starts fresh processes with reversed order. The final comparisons interleave the original baseline, merged baseline and candidate. Raw samples, p95, spread, thermal readings, build commands and source hashes are preserved in [the evidence directory](Evidence/StorageRows/).

| Image | Candidate write vs merged, first / repeat | Candidate write vs original, first / repeat |
| --- | ---: | ---: |
| 64×63 | −22.72% / −16.33% | −15.25% / −12.13% |
| 512×511 | −23.51% / −22.62% | −12.90% / −12.96% |
| 2048×2047 | −25.79% / −24.85% | −15.19% / −13.73% |

The candidate's total duration improved 2.7–3.5% against the merged baseline. Whole-process peak RSS changed by less than 1% against that baseline in both final comparisons. RSS includes the runtime and complete linked codec; it is not peak algorithm workspace or direct allocation/copy telemetry. The microsecond-scale allocation measurements vary between runs. Host frequency, scheduling and thermal conditions were observed rather than laboratory-controlled; retain every sample and outlier.

The standalone benchmarks target macOS 27 to reuse the source-hash-verified PR21 core module; an initial attempted macOS 26 link failed because that experimental module targeted 27. The failure is retained. Both accepted comparator builds use the same target. The repository deployment floor remains 26.0, and these measurements do not establish minimum-OS or physical-device support.

## Disposition and remaining gates

The scoped historical **write** investigation is resolved by the candidate on these cases: the span implementation is absent and the current writer beats both retained baselines. The old record is preserved, with no retroactive pass or threshold change.

The unchanged public **read** path still requires investigation against the original baseline. In the final two comparisons, its 512×511 median was 6.62% / 5.33% above the original. Those measurements exceed PERF-03's investigation threshold; the write improvement does not waive them. Other sizes and total durations vary. Keep this read item open alongside codec performance, broader corpus, platform/runtime and feature-disposition gates. No stable release or production cutover is authorised by these results.

Executed correctness and sanitizer commands, exact counts, source hashes and review findings are recorded in [validation.json](Evidence/StorageRows/validation.json). Existing golden-byte, odd-address, uninitialised-provider, precision and lifetime tests are retained; new cases exercise strided rows, exact final capacity, callback order and failure inside a later row.
