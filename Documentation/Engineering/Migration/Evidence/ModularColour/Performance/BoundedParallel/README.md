# Bounded encoder parallelism qualification

The parent runtime adds at most eight joined encoder workers, within the caller ceiling, with serial nested maps, task-local accounting propagation and live cancellation. Decoder parallelism is unchanged. No unchecked concurrency annotation or escaped source pointer is introduced.

Full local debug passed 188 declarations / 713 cases, zero skips. The isolated ASan and TSan runs each passed 20 declarations / 129 cases across five affected suites, with independent libjxl encoder checks enabled. Release compilation passed. Exact source hashes, commands and scope are in the JSON records. These results precede any later predictor security fix or gradient experiment; they are not relabelled as final-head evidence.

All nine outputs are byte-identical to the retained serial successor. Independent libjxl decoded all 27 successor/native-predecessor/serial-predecessor streams with exact samples and PAM dimensions, depth and maximum. Grouped predecessor outputs retain their previously explained four-byte difference.

## Controlled encode comparison

Two interleaved blocks per implementation, five warmups and ten timed iterations per block; no sanitizers, all observed thermal states nominal. Other migration builds/probes were held for this window. The native and diagnostic serial predecessor are pinned to 57e81cb9e2411d1efac435b429a306a031744c1e; serial substitution is recorded in the sibling Parallelism evidence. Successor worker ceiling is eight, workspace 2 GiB and aggregate 3 GiB for these explicit benchmark calls. Production defaults are unchanged.

| Case | Native predecessor ms | Serial predecessor ms | Successor ms | Versus native |
| --- | ---: | ---: | ---: | ---: |
| small-rgb8 | 0.223 | 0.231 | 0.164 | -26.7% |
| gray16 | 10.008 | 12.617 | 11.035 | +10.3% |
| rgb8 | 9.951 | 11.978 | 10.568 | +6.2% |
| group-rgb8 | 18.574 | 28.789 | 27.815 | +49.8% |
| group-rgba16 | 20.358 | 30.995 | 24.083 | +18.3% |
| flat-gray16 | 9.470 | 11.309 | 10.232 | +8.1% |
| noise-rgb8 | 20.536 | 30.631 | 23.590 | +14.9% |
| large-gray16 | 80.704 | 231.870 | 102.094 | +26.5% |
| large-gray8 | 166.088 | 504.440 | 209.093 | +25.9% |

Raw samples, p95, spread and process high-water RSS are retained in encode-comparison.json. Process RSS is not algorithm peak workspace. This improves the previous serial successor large-image results, but several native-predecessor gaps remain over 5%; speed parity and the final release performance gate are not claimed. Native predecessor dispatch is not constrained to the same worker ceiling, so this comparison includes execution-policy differences. Further attribution must not present them as pure public-API overhead.

The full debug and sanitizers validate exact output, cancellation after worker entry, bounded nested concurrency, deterministic ordered errors, pre-dispatch admission and shared immutable source use. Per-worker reservations and ordered-result capacity are documented in RESOURCE_ADMISSION.md. Hosted CI must still run on the committed final source.
