# Apple simulator owning API smoke qualification

Executed 2026-10-12 with Swift 6.4, Swift 6 language mode and complete concurrency checking, under contract 0.10.0 and the Apple OS 26.0 deployment floor. SDK 27.0 builds ran on the installed OS 26.5 simulators. This is a bounded smoke qualification, not the full platform suite, physical-device evidence, or a release gate completion.

| Platform | Compilation | Runtime | Result |
| --- | --- | --- | --- |
| iOS arm64 simulator | Pass | 26.5 / 23F77 | Nine smoke checks passed |
| tvOS arm64 simulator | Pass | 26.5 / 23L470 | Nine smoke checks passed |
| visionOS arm64 simulator | Pass | 26.5 / 23O470 | Nine smoke checks passed |
| watchOS arm64 simulator | Pass | Unavailable | Not executed; no runtime downloaded |

The probe imports only the public SwiftJXL module. It exercises 12-bit lossless samples, shared-storage copy reports, caller destination allocation identity, animation durations/clock denominator/loop count, separately owned retained frames, independently generated 12-bit VarDCT, independently generated exact RGBA16 animation including alpha, defined low-memory rejection, and cancellation. The resource profile caps total admitted memory and workspace at 32 MiB; this is an admission ceiling, not a measured RSS claim. All three VarDCT comparisons had peak 0 LSB and RMS 0 LSB against the retained scalar reference; the unchanged gates remain peak <= 2 LSB and RMS <= 0.5 LSB.

The existing SDK-built SwiftJXL.o and SwiftJXLCore.o were reused. `provenance.json` records the current source hashes and original build revision; every source hash matched the SDK-build report. `compile.json` records exact commands, explicit target SDKROOT, SDK paths, object hashes, executable hashes, and Mach-O simulator platform/deployment metadata. Initial compilation inherited the host SDKROOT and warned about a macOS sysroot; all four probes were recompiled with the explicit per-platform SDKROOT, with exit 0 and no diagnostics. No library code was changed.

Runtime execution used:

```text
python3 Scripts/TestSupport/run-apple-runtime-probe.py /Users/raster/Documents/Codex/2026-10-07/https-github-com-raster-labs-swiftjxl/work/apple-runtime-qualification
```

The runner used a newly created task-local device set, selected device types from the recorded installed runtime inventory, and invoked exact absolute probe paths. CoreSimulator required permitted execution outside the service sandbox; the initial sandbox-only inventory request could not connect. `runtime-report.json` retains every executed simctl command and result. All three created devices were shut down and deleted with exit 0; the final device-set inventory is empty. No pre-existing simulator devices were addressed.

Fixtures are unchanged copies of retained repository assets:

- `Tests/SwiftJXLCoreTests/Fixtures/VarDCT/EncoderPrecision/precision-12-1.jxl` and `.scalar` (see existing EncoderPrecision provenance).
- `Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Animation/libjxl-lossless-rgba16.jxl` (see existing Animation provenance).

Fixture hashes are recorded in `provenance.json`. No oracle was built or invoked at runtime. Pinned predecessor: 57e81cb9e2411d1efac435b429a306a031744c1e. Existing scalar libjxl oracle: a7a9c787341cf703dede03c2009fa460cae5e5df.
