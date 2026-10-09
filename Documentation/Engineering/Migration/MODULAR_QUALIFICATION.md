# Modular colour qualification work

PR #18 remains a draft. Existing transformation, owning-storage, public API, independent oracle and CLI evidence is retained under `Evidence/ModularColour`. Passing one stage does not close the remaining migration or release gates.

## Compiler compatibility

The first PR run, [37936477252](https://github.com/raster-labs/SwiftJXL/actions/runs/37936477252), exposed the same Swift 6.2 type-checker timeout on Linux x86_64 and ARM64 in the expected-sample expression in `ModularFrameDecoderTests`. The expression is now split into explicitly typed intermediate values with the same formula. Local Swift 6.4 reran the affected four declarations / eighteen cases successfully. Swift 6.2 remains pending until the corrected head passes hosted checks; this change does not alter codec behaviour.

## Malformed-input campaign

`Scripts/TestSupport/modular-mutation-probe.swift` exercises public inspect, allocating decode and decode into caller storage in separate modes. Decode success checks sample precision, storage extent and caller allocation identity. `Scripts/test-modular-mutations.py` runs one entry point per invocation in fresh processes with an outer 15-second timeout, retained failing input and deterministic mutation seed. Its PNM mode exercises the real CLI parser/encoder. It records input/binary/script hashes, accepted/rejected outcomes, elapsed wall time and child-process peak RSS. Runtime and sanitizer overhead are included in RSS; it is not peak algorithm workspace.

The library probe uses one worker, a five-second deadline, 128 MiB aggregate admission, 262144 pixels, 8192 maximum dimension, 1 MiB compressed input and bounded metadata/nesting. The initial 1024 dimension limit was too small for valid 1025/4097-wide seeds: preflight correctly stopped rather than counting their rejection as coverage. The corrected corpus contains 34 independently generated Modular streams spanning palette, progressive groups, grey/RGB, both transfers and straight/associated alpha. The separate reproducible PNM generator creates twelve synthetic 8/12/16-bit files; no private data is used.

Smoke runs accepted every conformant seed and completed ten seconds per entry: inspect 573 mutations, allocating decode 441, caller decode 444, PNM 581, with no unresolved findings. Timed one-hour-per-entry runs are the next gate; these smoke counts do not satisfy it. This harness is deterministic mutation testing, not coverage-guided fuzzing or a security certification. The full codec feature set and descriptor fuzzing remain separate scopes.

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
