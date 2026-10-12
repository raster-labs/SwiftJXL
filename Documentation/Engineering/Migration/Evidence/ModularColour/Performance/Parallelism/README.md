# Controlled predecessor comparison — 12 October 2026

This records the retained implementation and the completed performance investigation for the bounded Modular milestone. It is not a stable-release performance pass. Source revisions, object/binary hashes and exact commands are in [validation.json](validation.json), [probe-builds.json](probe-builds.json) and the native/serial predecessor build records. The pinned predecessor checkout is unchanged.

The native and diagnostic serial predecessor use the same `-O` whole-module compilation; the only source substitution is the small test-only `ParallelMap.swift`. Native and serial output bytes match for all nine cases. The successor includes checked ownership/resource admission, direct caller-storage reconstruction and bounded cancellation. The libraries retain their own deployment floors, so these comparisons do not isolate public-wrapper overhead alone.

Each operation has two process blocks with five warmups and ten measured iterations per block. Order is native predecessor, serial predecessor, successor, successor, serial predecessor, native predecessor. Allocating decode consumes the same independently decoded successor file. Every output sample and independent PAM dimension/channel/precision header matches. All recorded thermal states were nominal; AC power and low-power mode zero were reported. Migration builds and mutation work were stopped for timing; a separate project's idle test coordinator was not altered. Raw observations, p95, spread, throughput and RSS are in [controlled-report.json](controlled-report.json).

## Median milliseconds

| Case | Native encode | Serial encode | Successor encode | Native decode | Serial decode | Successor decode |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| small-rgb8 | 0.194 | 0.247 | 0.208 | 0.393 | 0.389 | 0.051 |
| gray16 | 10.214 | 12.807 | 14.294 | 3.906 | 3.957 | 5.481 |
| rgb8 | 9.816 | 12.118 | 13.219 | 3.864 | 3.772 | 3.811 |
| group-rgb8 | 18.840 | 27.452 | 28.443 | 7.531 | 7.620 | 8.389 |
| group-rgba16 | 23.044 | 31.639 | 33.911 | 7.843 | 7.601 | 8.381 |
| flat-gray16 | 9.571 | 11.561 | 12.961 | 3.631 | 3.475 | 5.386 |
| noise-rgb8 | 22.913 | 32.283 | 33.975 | 20.669 | 20.942 | 24.018 |
| large-gray16 | 103.274 | 258.764 | 266.072 | 21.511 | 78.514 | 111.898 |
| large-gray8 | 198.035 | 555.629 | 578.635 | 49.112 | 163.454 | 226.253 |

The large encodes are 2.8% and 4.1% slower than the serial control, while native parallel encoding is substantially faster. This isolates execution policy as a large contributor; it does not make the native predecessor comparison disappear. Smaller encodes retain measurable additional cost. Greyscale decode remains 38–55% slower than the serial control in this baseline; a separate packed/power-of-two address experiment passed correctness but increased both large decodes by about 6% in each block, so it was rejected and the source restored. [Rejected experiment](../RejectedAddress/decision.json) retains its evidence.

Eight-bit allocating decode returns UInt16 in the successor and UInt8 in the predecessor. Caller decode in this probe uses the matching UInt8 destination; it is recorded separately because caller allocation occurs before timing. These output-layout differences must not be described as identical allocation work.

No case increased process high-water RSS by more than 5% against the native predecessor. Large-case successor RSS was lower, but this process measurement includes source/fixture preparation, compressed buffers, warmups and retained results. It is not peak algorithm workspace and does not replace the [direct storage audit](../../Memory/README.md). The probe explicitly allows 2 GiB cumulative workspace / 3 GiB aggregate admission with one successor worker; production defaults are unchanged.

Grouped successor streams are four bytes larger because they emit the empty global ANS terminal state. Every stream is independently sample-exact and this is below the 1% size-investigation threshold on these cases. The output difference is recorded rather than misrepresented as byte identity with the predecessor.

## Engineering disposition

Retain deterministic scalar execution for this feature milestone. The predecessor parallel helper creates a GCD work fan-out using an unsafe pointer bridge; copying that helper would not establish bounded worker admission, inherited cancellation or retained storage lifetimes. The measured serial control shows that parallelism explains most large encode overhead and a substantial part of large decode overhead. The new baseline records that cost explicitly rather than presenting scalar performance as native-parallel parity.

The serial decoder comparison also includes direct reconstruction into strided UInt8/UInt16 caller storage instead of the predecessor's Int32 channel arrays followed by final-image assembly, plus resource/precision/cancellation enforcement. These are real architectural differences; this experiment does not separately quantify each one's cost. Residual confirmed latency differences are therefore **not waived for stable release**. The remaining release performance work is a bounded parallel execution design and further profiling of scalar decode; it must preserve exact samples, admission, cancellation and zero extra final-image handoff allocations. The rejected address experiment is not shipped.

This disposition closes measurement and investigation for the current feature PR, not the suite's final performance/release gate. No performance parity, stable release or production cutover is claimed. The native predecessor and retained successor measurements above remain the recorded baselines for the next optimisation stage.
