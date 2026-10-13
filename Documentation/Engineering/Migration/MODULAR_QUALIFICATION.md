# Modular colour qualification work

PR #18 remains a draft. Existing transformation, owning-storage, public API, independent oracle and CLI evidence is retained under `Evidence/ModularColour`. Passing one stage does not close the remaining migration or release gates.

## Compiler compatibility

The first PR run, [37936477252](https://github.com/raster-labs/SwiftJXL/actions/runs/37936477252), exposed the same Swift 6.2 type-checker timeout on Linux x86_64 and ARM64 in the expected-sample expression in `ModularFrameDecoderTests`. The expression is now split into explicitly typed intermediate values with the same formula. Local Swift 6.4 reran the affected four declarations / eighteen cases successfully. Corrected head `526d6bb` passed all eight hosted checks, including macOS 26 / Swift 6.2, both Linux architectures/compiler versions and pinned libjxl interoperability. This change does not alter codec behaviour.

## Malformed-input campaign

`Scripts/TestSupport/modular-mutation-probe.swift` exercises public inspect, allocating decode and decode into caller storage in separate modes. Decode success checks sample precision, storage extent and caller allocation identity. `Scripts/test-modular-mutations.py` runs one entry point per invocation in fresh processes with an outer 15-second timeout, retained failing input and deterministic mutation seed. Its PNM mode exercises the real CLI parser/encoder. It records input/binary/script hashes, accepted/rejected outcomes, elapsed wall time and child-process peak RSS. Runtime and sanitizer overhead are included in RSS; it is not peak algorithm workspace.

The library probe uses one worker, a five-second deadline, 128 MiB aggregate admission, 262144 pixels, 8192 maximum dimension, 1 MiB compressed input and bounded metadata/nesting. The initial 1024 dimension limit was too small for valid 1025/4097-wide seeds: preflight correctly stopped rather than counting their rejection as coverage. The corrected corpus contains 34 independently generated Modular streams spanning palette, progressive groups, grey/RGB, both transfers and straight/associated alpha. The separate reproducible PNM generator creates twelve synthetic 8/12/16-bit files; no private data is used.

Smoke runs accepted every conformant seed and completed ten seconds per entry: inspect 573 mutations, allocating decode 441, caller decode 444, PNM 581, with no unresolved findings. The subsequent one-hour-per-entry runs completed: inspect 152768, allocating decode 90315, caller decode 89494 and PNM 138581 mutations, totalling 471158 with no reported failures. [Terminal reports and hashes](Evidence/ModularColour/Mutation/validation.json) preserve the exact scope. This harness is deterministic mutation testing, not coverage-guided fuzzing or a security certification. The full codec feature set and descriptor fuzzing remain separate scopes.

Example commands from the repository root (use fresh output directories):

```sh
xcrun swiftc -g -sanitize=address -swift-version 6 -strict-concurrency=complete \
  -parse-as-library -module-cache-path .build/module-cache \
  -I ../evidence/cli-validation-qualification/build/asan/out/Products/Debug \
  Scripts/TestSupport/modular-mutation-probe.swift \
  ../evidence/cli-validation-qualification/build/asan/out/Products/Debug/SwiftJXL.o \
  ../evidence/cli-validation-qualification/build/asan/out/Products/Debug/SwiftJXLCore.o \
  -o ../modular-preflight/modular-mutation-probe
python3 Scripts/test-modular-mutations.py \
  --binary ../modular-preflight/modular-mutation-probe --entry decode \
  --seeds Tests/SwiftJXLCoreTests/Fixtures/Modular \
  --output ../modular-preflight/mutation-hour-decode --seconds 3600
python3 Scripts/TestSupport/pnm-mutation-seeds.py ../modular-preflight/pnm-mutation-seeds-final
python3 Scripts/test-modular-mutations.py \
  --binary ../evidence/cli-validation-qualification/build/asan/out/Products/Debug/swiftjxl-cli \
  --entry pnm --seeds ../modular-preflight/pnm-mutation-seeds-final \
  --output ../modular-preflight/mutation-hour-pnm --seconds 3600
```

The ASan module objects must be built from the recorded codec revision first. Repeat the decode invocation with `--entry inspect` or `--entry caller` and a separate output directory for those entry points. Do not substitute combined wall time for an hour per entry. Record terminal results before declaring the gate passed. Do not run controlled performance measurements concurrently with these campaigns.

## ICC, low precision and review follow-up — 12 October 2026

Head `bfd12bc` passed all eight hosted checks, including macOS 26 / Swift 6.2. The additional ICC campaigns accepted all twelve conformant seeds per entry and completed 107174 inspect, 96155 allocating-decode and 93940 caller-decode mutations. The low-precision campaigns accepted all 28 conformant seeds per entry and completed 97614, 91071 and 91290 mutations respectively. Each entry ran at least 3600 seconds after seed admission and exited zero, with no reported failures. These six campaigns total 577244 mutations. See the [ICC terminal reports](Evidence/ModularColour/ICC/Mutation/validation.json) and [low-precision terminal reports](Evidence/ModularColour/LowPrecision/Mutation/validation.json); their runtime revisions remain explicit.

A focused review corrected the public error category for unsupported delta/predicted palettes. Invalid channel geometry is checked first. Ten declarations / fourteen cases passed in the affected ordinary-build tests; [review evidence](Evidence/ModularColour/review-validation.json) explains the header-only fixture scope. Existing sanitizer campaigns are not relabelled as runs of this later rejection-only correction.

[Ordinary-build memory evidence](Evidence/ModularColour/Memory/README.md) covers larger grey/colour profiles, exact padded storage, unchanged caller allocation identity, concurrent readers, admission denial and cancellation. Audit counters distinguish final storage from signed algorithm planes. Cumulative reservations and retained-heap snapshots are not peak live workspace; unknown peak metrics remain unknown.

## Performance disposition

The [controlled nine-case comparison](Evidence/ModularColour/Performance/Parallelism/README.md) uses exact samples, two interleaved process blocks, ten total warmups and twenty timed iterations per operation. It separates native predecessor execution from a diagnostic serial control. Parallelism explains most large encode overhead; residual scalar decode differences remain recorded. No measured case increased process high-water RSS by more than 5%, but this is not a peak-workspace measurement. A further address specialisation passed debug/ASan/TSan yet slowed both large decodes by about 6%, and was removed.

The measured baseline records the scalar cost; it does not waive the stable-release latency gate or claim predecessor speed parity. [Bounded encoder parallelism](Evidence/ModularColour/Performance/BoundedParallel/README.md) adds explicit per-worker admission, joined work and propagated cancellation. Its nine-case comparison retains exact output; several native-predecessor gaps still exceed 5%. The [gradient specialisation experiment](Evidence/ModularColour/Performance/Gradient/decision.json) then reduced decode medians by 15–27% in both interleaved blocks across five representative cases, preserving samples and the generic fallback. Both comparison binaries predate the later Select-predictor magnitude fix; final combined source validation is recorded separately. Hosted CI must pass on the final committed head. The remaining codec/platform migration and stable-release performance gate stay open.

### Integer-token conversion follow-up — 13 October 2026

The [unfolded-token comparison](Evidence/ModularColour/Performance/UnfoldedTokens/README.md) starts from merged main `4e6b012`. A small algebraic simplification preserves byte-identical output across nine independently decoded cases. Confirmed larger-case encode median improvements are 0.3–5.8%; the noisy small-case result is retained without a speedup claim. No compared decode median or process high-water RSS regression exceeds 5%. The native-predecessor gap remains open. This record includes discarded inlining and worker-scheduling trials, exact source/binary hashes and local qualification; hosted CI must still validate the submitted head.

## Final-head compiler follow-up

Run `38216628517` passed both Swift 6.4 Linux jobs and the pinned independent oracle, but both Swift 6.2 Linux jobs timed out while type-checking the expected-sample expression in `ModularGradientTests`. Explicitly typed intermediate values retain the same calculation. The affected four declarations / 29 cases passed locally; all codec source hashes still match the fully tested `e639259` runtime. A fresh CI run is required for the corrected test source, including macOS. See `FinalReview/swift62-test-expression.json`.

### Deterministic cancellation regression

Run `38217995853` exposed a test scheduling race in the Swift 6.2 Linux ARM release suite: polling a worker allocation did not guarantee the encoder was still running when cancellation was requested. Separate deterministic tests now exercise cancellation inside a synchronous worker, joining all entered callbacks, and public cancellation before returning a completed result. The affected six declarations / 12 cases passed locally. Codec sources are unchanged; final-head CI, including macOS, remains required. See `FinalReview/deterministic-cancellation.json`.
