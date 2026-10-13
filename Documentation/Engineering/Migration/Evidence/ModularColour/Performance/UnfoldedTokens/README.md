# Unfolded integer-token conversion — 13 October 2026

This bounded milestone 4 change simplifies HybridUint encoding when both folded-bit counts are zero, including the Modular encoder's raw4 configuration. Values below the literal threshold retain their existing path. Other configurations retain the general formula. No public API, allocation, concurrency, resource limit or cancellation behaviour changes.

## Source and correctness

Merged baseline: `4e6b012bc3c54da968085dd35a6df9ff90e7606f`. Pinned native predecessor: `57e81cb9e2411d1efac435b429a306a031744c1e`. Contract: 0.10.0; all seven common documents remain unchanged. The original algorithm provenance remains in HybridUint.swift. Candidate source and binary hashes are recorded in environment-final.json and validation.json; commands are in commands.json.

For a non-literal value, its highest set-bit index n is at least the split exponent. With no folded bits, the general formula reduces to token = split + n - splitExponent, extraBits = value minus its highest set bit, and extraNBits = n. n is at most 31, so the subtraction/conversion and token sum fit on Watch's 32-bit Int as well as 64-bit hosts. There are no new unsafe operations or storage owners.

The new regression checks all 31 valid split exponents against the unchanged general token-only formula and decoder, using low values, every 32-bit power-of-two boundary, UInt32.max and deterministic random values. Independent libjxl preflights validate exact samples. All nine candidate streams are byte-identical to the merged baseline in both accepted comparison runs. oracle-headers.json additionally validates PAM dimensions, depth, maximum and exact payload lengths across 69 preflights. These checks do not substitute for physical-device qualification.

## Controlled measurements

Apple M4, 16 GiB, macOS 27.0.1, Apple Swift 6.4; AC power, low-power mode off. Optimised builds with no sanitizers or profiling during accepted timing. Each comparison interleaves baseline/candidate/candidate/baseline processes, five warmups and ten timed iterations per process: twenty timed samples per implementation and operation. No other task builds or tests ran during these windows. All sampled thermal states were nominal.

The comparison binaries use the same eight-worker ceiling and explicit benchmark-only workspace/aggregate budgets. In unfolded.json and confirmation.json, the harness's legacy `predecessor` slot means merged main, not the pinned historical codec. Raw samples, p95, range, throughput, encoded size, retained heap observations and process high-water RSS are retained. Caller-storage timing is candidate-only; no comparative caller claim is made. RSS and retained heap observations are not peak algorithm workspace or allocation-count measurements.

Confirmation encode results:

| Case | Merged main ms | Candidate ms | Change |
| --- | ---: | ---: | ---: |
| small-rgb8 | 0.160 | 0.165 | +3.0% |
| gray16 | 11.116 | 10.802 | -2.8% |
| rgb8 | 10.573 | 10.282 | -2.7% |
| group-rgb8 | 21.871 | 20.608 | -5.8% |
| group-rgba16 | 23.654 | 23.573 | -0.3% |
| flat-gray16 | 10.239 | 10.199 | -0.4% |
| noise-rgb8 | 22.998 | 22.502 | -2.2% |
| large-gray16 | 103.025 | 100.473 | -2.5% |
| large-gray8 | 208.552 | 205.851 | -1.3% |

The initial small-image result (-11.1%) did not repeat (+3.0% in confirmation); it is not claimed as a reliable gain. Larger-image improvements are modest and case-specific. Neither accepted comparison shows an encode median regression over 5%. Confirmation decode medians range from -1.8% to +1.0%; no compared process high-water RSS increase exceeds 5%.

Tail observations remain visible: initial RGB p95 was +5.2%; confirmation RGBA encode/decode p95 was +5.1%/+5.3%, with the elevated RGBA samples concentrated in one candidate block and absent from its second block. Small-image decode p95 changed by about 4 microseconds (+9.2%). A separate three-case repeat after all test runs did not reproduce those p95 increases (all corresponding tails improved), but RGB decode showed a new +9.7% p95 fluctuation with a +2.9% median. Both runs remain in the evidence; no sustained tail-latency improvement or final performance qualification is claimed. The decoder source and its input bytes are unchanged.

The fresh baseline.json comparison still shows eight of nine merged-main encode cases 7.7–26.6% slower than the pinned native predecessor. That predecessor does not enforce the same worker ceiling, so this includes execution-policy differences. This small optimisation does not close that gap or waive the stable-release performance gate. Broader mode/platform qualification remains open.

## Discarded experiments

inline.json adds only `@inline(__always)` to HybridUintConfig.encode. neighbour.json additionally annotates Neighbourhood.init(at:_:in:width:). Gains were modest and uneven, so both annotations were removed. dynamic.json measures the retained dynamic-experiment.json: workers claim the next chunk instead of fixed stripes. It did not produce meaningful gains and was reverted, including its test changes. None of these experiments is part of the candidate runtime. Their raw samples remain available to avoid repeating unproductive work.

profile-summary.txt is a separate five-second baseline sampling diagnostic, not accepted timing evidence. It identified token conversion and neighbour/predictor work among the hot paths.

## Validation

Full debug and release each passed 284 declarations / 1,119 argument cases with independent libjxl enabled. Focused AddressSanitizer and ThreadSanitizer each passed 25 declarations / 100 argument cases across seven affected suites. All runs exited zero, without failures, skips or sanitizer diagnostics. validation.json records exact commands, full runtime/test source hashes and results; the four xUnit files are retained. The source review found no actionable issues. Hosted CI on the submitted head remains required. No milestone completion, release, tag or production cutover is claimed.
