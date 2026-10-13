# Compact native JPEG AC entropy qualification

Contract 0.10.0; pinned predecessor JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e`.
The comparison baseline is merged SwiftJXL `f10c1deaa47c04f440ec95297076a19032d2e7a4`.
Its runtime is byte-identical to the recorded `f84c0fd` baseline build. Candidate
source hashes are in `candidate-build.json` and the validation records. This is
bounded milestone 4 work, not release or complete performance qualification.

## Behaviour and selection

The JPEG bridge retains prefix coding for greyscale, single-group, flat and
small streams. For three-component streams with multiple AC groups, at least
16384 tokens and more than one used token symbol, it costs a single-cluster
rANS alternative. The costing walk uses the actual quantised on-wire frequencies
and reverse state transitions. HybridUint extra bits cancel in the comparison.
It chooses rANS only when savings exceed 40 bits per changed AC/HFGlobal section:
8 for byte alignment and 32 for a complete TOC entry. The latter is conservative;
the actual TOC-entry increase is at most 20 bits. Geometry bounds keep the bit
accumulators below signed 32-bit limits. No error is caught to bypass admission.

Emission reuses a UInt16 symbol buffer for refill words and keeps one flag bit
per token. The maximum group has 196608 tokens: 384 KiB of symbols and 24 KiB of
flags, within the existing admitted 4 MiB scratch. Costing and emission are
sequential and retain only one group at a time; fixed coefficient-block and
alias-table workspace remains separately within that allowance. The immutable
coefficient owner supplies the same values during synchronous replay. There
are no new raw pointers, workers, pixel allocations, coefficient hand-off
copies, external runtime dependencies or file staging. Symbol/refill processing
checks cancellation and output-limit failures every 256 tokens; coefficient
replay preserves the existing row checkpoints. Replay count mismatch rejects.

## Executed comparison

`host.json` pins the local macOS 27.0.1 arm64 machine, Swift 6.4 identity,
AC power and libjxl 0.12.0 decoder hash. Builds use `-O -g` and whole-module
optimisation without sanitizers. They compare synchronous native core operations,
not public async dispatch overhead. The host is not thermally instrumented.

Sixteen inputs comprise eight retained JPEG/ICC fixtures and eight generated
flat, ramp, textured and noisy multi-group images, up to 1024×1024. The generator,
seed, cjpeg options/hash, dimensions and input hashes are retained. All sixteen
candidate and baseline streams pass native byte-exact reconstruction, independent
djxl byte-exact JPEG reconstruction, and independent pixel decoding. Twelve
candidate streams remain byte-identical to baseline. The four changed streams
preserve the original JPEG exactly.

Two comparisons each alternate baseline/candidate then candidate/baseline.
Each process uses five warm-ups and twenty timed iterations per direction;
there are forty samples per case/codec/direction per comparison, 5120 timed
operations across both comparisons. Equality checks occur outside the timer.
`predecessor` in these comparison JSON slots means **merged SwiftJXL**, not
JXLSwift. `successor` means this candidate. Both use
`SWIFT_DETERMINISTIC_HASHING=1`; the earlier predecessor variability investigation
is separate. Raw samples, p95, spread, size and process high-water RSS are retained.

Confirmation results (negative percentages are reductions):

| Case | Baseline bytes | Candidate bytes | Size | Encode median |
| --- | ---: | ---: | ---: | ---: |
| multigroup-420 | 116126 | 93341 | -19.6% | -4.7% |
| rgb-ramp | 55607 | 43816 | -21.2% | -6.7% |
| rgb-noise444 | 123686 | 115980 | -6.2% | -10.4% |
| rgb-textured420 | 966068 | 830435 | -14.0% | -7.6% |

No confirmation median latency regression exceeds 5%. Unchanged cases and noisy
tails remain in the full records. One initial noisy-RGB process had a 21.2%
high-water RSS increase; the independent confirmation did not reproduce a >5%
increase. A fixed six-pair follow-up after all tests found a consistent ~4%
increase (about 384 KiB), below the investigation threshold; see
`rss-confirmation.json`. The initial outlier remains retained. High-water RSS includes
process setup/runtime and is not measured peak algorithm workspace or allocation
counts; those fields remain unqualified. The pinned-predecessor compression gap
is reduced, not closed, and the wider corpus/platform gates remain open.

## Rejected trials

- `split-prefix`: separating count/coefficient histograms saved only 34 bytes on
  the original multi-group case and increased encode time about 28%; discarded.
- `compact-ans`: the first UInt32-values/refills implementation saved size and
  latency, but its later cost-gated variant regressed small/flat streams.
- `final`: a 16384-token/non-flat threshold removed those timing regressions,
  but separate values/refills buffers increased noisy-RGB high-water RSS about
  14.4% in both comparisons. The two-buffer implementation was discarded.
- `replay`: reusing UInt16 symbols removed the repeated memory increase, but
  greyscale-ramp encoding regressed 7–9%. Greyscale remains on the original path.

Patches and summary records preserve these findings. The candidate includes
only the colour-qualified selection and reused-symbol emission. No threshold,
quality or memory budget was weakened to make a trial pass.

## Reproduction and verification

Copy the scripts to a fresh scratch directory, not into a production checkout.
Use `original-config.json` as the schema for `config.json`, setting `successor`
to a clean source snapshot and `work` to the scratch directory. The recorded
absolute command paths identify this run; replace only checkout/output paths
for another host. Keep fixtures and tool versions pinned.

1. With the baseline source selected, run `python3 prepare-inputs.py`,
   `python3 build.py SwiftJXLCore fresh` and `python3 compile-probe.py fresh`.
   Then run `SWIFT_DETERMINISTIC_HASHING=1 python3 preflight.py successor fresh`.
2. Select the candidate source in the configuration. Run
   `python3 build.py SwiftJXLCore compact-ans-colour` and
   `python3 compile-probe.py compact-ans-colour`, followed by
   `SWIFT_DETERMINISTIC_HASHING=1 python3 preflight.py successor compact-ans-colour`.
3. Run `python3 compare-experiment.py colour-comparison compact-ans-colour` and
   `python3 compare-experiment.py colour-confirmation compact-ans-colour`
   sequentially with no builds, tests or other benchmark workload running.

Build results, oracle commands and exits, full source hashes, and raw timing
samples are committed alongside this record. Unit tests compare compact output
byte-for-byte with the existing buffered writer at empty, checkpoint and maximum
group boundaries, then decode it. Separate tests cover replay-count errors,
cancellation, output limits, grouped coefficient fidelity and a compression
regression; existing native oracle and public resource/lifetime tests also apply.
Full debug and release each pass 288 declarations / 1129 cases. Focused ASan
and TSan each pass 28 declarations / 102 cases. All runs exit zero with no
failures, skips or sanitizer diagnostics. Exact commands and tested-source
hashes are recorded in `validation.json`. Hosted CI must pass on
the submitted head before review readiness. No release, tag or cutover follows.
