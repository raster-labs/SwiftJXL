# Milestone 4 remaining work

Merged PR32 baseline: `efce6a973c96d3e49e9facc3510966d7ab0563a1`.
Its tree matches the original continuation checkpoint
`540a0b13c035c587915a5226a4f47f7db2f37bac`.
Pinned predecessor: `57e81cb9e2411d1efac435b429a306a031744c1e`.
Common contract: **0.10.0**, unchanged. Branch:
`codex/swiftjxl-milestone4-remaining`.

The owner requested implementation of remaining items 2–6 before validation,
then review, commit and push to a new branch, followed by scoped macOS and iOS
simulator qualification (including exact iOS 26.0 minimum-floor runtime
execution) and hosted CI verification on PR #33. Unavailable or out-of-scope
hardware/runtimes are recorded explicitly. Merge is authorised only if all
agreed scoped Milestone 4 requirements and final-head CI pass.

## Implementation and validation separation

Source, meaningful regression tests, fixture generators and all validation
harnesses were prepared and audited before the final validation phase. The
earlier [completion checkpoint](MILESTONE4_COMPLETION.md) records historical
results for its original source; it does not validate these changes. Pre-fix
full validation results are bound to the 1,195-file baseline source manifest
(`implementation-freeze-6.json`, [Evidence/Milestone4Remaining/source-manifest.json](Evidence/Milestone4Remaining/source-manifest.json),
`Package.swift` `2733007bb6eff3094ab984520bf6add9ebcb328968a1af16bd5ce908c446c834`).
After hosted GitHub Actions CI runs `38726940479` and `38750702077` exposed Swift
6.2 expression type-checking timeouts in three files
(`Sources/SwiftJXLCore/VarDCT/VarDCTSmallAnalysis.swift`,
`Tests/SwiftJXLCoreTests/VarDCTEncoderPreparationTests.swift`, and
`Tests/SwiftJXLCoreTests/VarDCTWorkspaceTests.swift`), the 90-line
`withUnsafeMutableBufferPointer` closure body in `VarDCTSmallAnalysis.swift`
was extracted into a private helper method `apply(_:identifier:buffer:dct:)`
and explicit closure parameter/return type annotations were added in
`implementation-freeze-8.json` ([Evidence/Milestone4Remaining/source-manifest-final.json](Evidence/Milestone4Remaining/source-manifest-final.json)),
validated by full native macOS `release-8`, targeted `debug-3-vardct` /
`asan-4-vardct` / `tsan-3-vardct`, and full `iOS 26.0` Simulator Release
(`ios-simulator-26.0-release-2`), with byte-for-byte identical `SwiftJXL.o`
across `Release`, `Debug`, `ASan` and `TSan` and zero numerical, order,
ownership or default changes.

| Item | Prepared work | Final validation |
| --- | --- | --- |
| 2: predecessor regressions | Reduce entropy and transform scratch/loop overhead; compact constant-image coding retains strict terminal checks | Primary 48-row release matrix (`public-default-final-2` 36 rows / 28 paired + `native-results-3` 12 rows / 9 paired) passed with 0 repeated latency, RSS or lossless-size triggers; 10 constrained one-worker (`maximumWorkers=1`) latency triggers retained as diagnostic evidence; 11 candidate-only rows retained without predecessor speedup claims |
| 3: executable platforms | Reusable SDK/simulator (`Scripts/TestSupport/qualify-ios-simulator.py`) and native/physical runtime runners | Local macOS arm64 debug/release/ASan/TSan suites (`release-6`, `release-8`, `asan-2`, `debug-1`, `tsan-1` + post-fix `debug-3-vardct`/`asan-4-vardct`/`tsan-3-vardct`), standalone consumer, 10 Apple SDK builds, 4 simulator smoke probes (`iOS 26.5`, `tvOS 26.5`, `visionOS 26.5`, `watchOS 26.0`), and **full 359-declaration / 1,955-case iOS Simulator test suites** on **`iOS 26.0` (`23A343`, Release)** and **`iOS 26.5` (`23F77`, Release, Debug, ASan, TSan)** passed; exact `macOS 26.0` native/VM runtime remains **unexecuted** (local host is `macOS 27.0.1` `26A434`; GitHub `macos-26-arm64` runner is `macOS 26.6.2` `25G83`); Intel/physical devices/full non-iOS simulator bundles are out of the owner-scoped macOS+iOS slice and remain **unexecuted** |
| 4: ARM integer reference | Explicit deterministic reference numerical profile; scalar default and both fixed tolerances retained | Passed all 123 retained historical integer cases, 8 caller-storage cases and 45,826 hardware reciprocal vectors across native macOS `release-6`, `release-8`, `asan-2`, `debug-1` and `tsan-1` AND across all 5 full iOS Simulator suite runs (`iOS 26.0` Release and `iOS 26.5` Release, Debug, ASan, TSan) plus negative reciprocal-vector delivery/evaluation sentinels |
| 5: JPEG security | Defensive source review, bounds/admission fixes, canary self-tests, ordinary local regression/sanitizer suites, and source-pinned ASan mutation harness (`Scripts/test-jpeg-mutations.py`) | Defensive source review and local macOS + iOS Simulator regression/ASan/TSan suites passed; the three 3,600-second per-entry mutation campaigns (`jpeg-inspect`, `jpeg-decode`, `jpeg-caller`) remain **unexecuted** |
| 6: JPEG capabilities | 12-bit DCT, SOF3 predictive samples and explicit ICC/Exif interpretation | Passed 365 declarations / 2,048 cases in native macOS (`release-6`, `release-8`, `asan-2`, `debug-1`, `tsan-1`), 359 declarations / 1,955 cases in iOS Simulator (`iOS 26.0` Release and `iOS 26.5` Release/Debug/ASan/TSan), 91 extended CLI JPEG fixtures in `cli-release`, `cli-asan`, `cli-debug` and `cli-tsan`, and 91 extended JPEG cases in each of the 4 simulator smoke probes |

## Scoped hardware and minimum runtimes

The owner scoped hardware/simulator qualification for this slice to **this Apple
Silicon Mac and installed iOS simulators (`iOS 26.0` and `iOS 26.5`)**, with
exact **OS 26.0** minimum-floor coverage required where obtainable:

- **iOS 26.0 minimum deployment floor (`23A343`, `com.apple.CoreSimulator.SimRuntime.iOS-26-0`):** Acquired via `xcodebuild -downloadPlatform iOS -buildVersion 26.0 -architectureVariant arm64` and qualified across the full compatible library suite (`359` declarations / `1,955` cases, `0` failures, `0` skips) in `ios-simulator-26.0-release-2` ([report](Evidence/Milestone4Remaining/ios-simulator-26.0-release-report.json)).
- **iOS 26.5 simulator (`23F77`, `com.apple.CoreSimulator.SimRuntime.iOS-26-5`):** Qualified across the full compatible library suite (`359` declarations / `1,955` cases, `0` failures, `0` skips) in `Release` ([report](Evidence/Milestone4Remaining/ios-simulator-26.5-release-report.json)), `Debug`, `ASan` and `TSan` ([report](Evidence/Milestone4Remaining/ios-simulator-26.5-debug-sanitizers-report.json)).
- **macOS 26.0 minimum deployment floor:** Remains **unexecuted**. The local workstation runs `macOS 27.0.1` (`26A434`) with ~`6.0 GiB` free disk space and no local `macOS 26.0` VM image installed, and GitHub Actions' `macos-26-arm64` hosted runner image (`20260907.0351.1`) runs **`macOS 26.6.2` (`25G83`)** rather than `26.0`.
- **Out-of-scope targets for this slice (explicitly unqualified / unexecuted):** Native Intel (`x86_64`) macOS, physical iPhone/iPad/Apple TV/Apple Watch/Vision Pro devices (`0` attached in `xcrun devicectl list devices`), and full test-bundle execution inside `tvOS`, `watchOS` and `visionOS` simulators (covered by 10-target SDK builds and standalone smoke probes on `tvOS 26.5`, `visionOS 26.5` and `watchOS 26.0`).

`Scripts/TestSupport/qualify-native-runtime.py` refuses Rosetta for native-host
claims, requires physical-device identity and optional exact 26.0 runtime,
and records commands/source hashes/results and executed-test counts.
`Scripts/TestSupport/qualify-ios-simulator.py` enforces exact 359-declaration /
1,955-case reconciliation against the 365-declaration / 2,048-case macOS
baseline (`6` `#if os(macOS) || os(Linux)` external-process declarations / `93`
cases excluded on iOS), refuses to reuse a non-empty `output_dir` for new
executions ([guard proof](Evidence/Milestone4Remaining/ios-nonempty-guard-proof.json)),
hashes all `13` DerivedData built products before cleanup, verifies `45,826`
hardware reciprocal vectors with negative delivery/evaluation sentinels, and
runs an 8-scenario fail-closed validator self-test.

## JPEG interpretation

DCT decoding retains scalar IDCT and nearest chroma reconstruction at declared
8/12-bit precision. SOF3 reconstructs predictive samples at declared 2–16-bit
precision; nonzero point transform does not promise recovery of discarded
source bits. Allocating output uses UInt8 through 8 bits and UInt16 above it;
caller storage may preserve samples in the supported planar/interleaved layouts.
The original-byte Transcoder remains a separate bounded 8-bit DCT operation.

`.srgb` remains an explicit caller declaration for untagged samples. Embedded
ICC/Exif requires `.embedded(orientation: .preserve)` or `.apply`; ICC bytes
remain attached to samples without an implicit colour conversion. Preserving
orientation retains required interpretation metadata; applying orientation is
an explicit spatial transformation. Ancillary discard cannot drop information
needed to interpret samples. Explicit discards are reported by bounded optional
`jpeg.discardedAncillary` metadata containing marker kinds, counts and payload
byte totals; no discarded payload is retained and the report counts towards
metadata limits. The CLI retains its explicit `jpeg-srgb` route and
rejects metadata it cannot preserve in NRRD/PNM output.

## Numerical profiles and performance claims

`DecoderConfiguration.varDCTNumericalProfile` defaults to scalar nearest-integer
output. `.libjxl012ARMInteger` explicitly selects the pinned ARM reference's
reciprocal/rounding and 8-bit dither semantics. The original maximum 2 LSB and
RMS 0.5 gates remain unchanged for this reference profile; scalar output keeps
its own independent gate. A pass in one profile is not a pass for the other.
No hardware-dependent or fixture-specific automatic selection is used.

Performance claims require controlled repeated predecessor/candidate comparisons
with correctness and output-size evidence. Public Modular effort remains 3.
RSS is process memory, not an exact workspace-allocation peak or proof of leak
freedom. Existing unrelated signed/float, advanced CLI and wider codec-profile
deferrals remain separate.

## Final evidence — 15 October 2026

Pre-fix full gates verified zero source/package drift against the 1,195 files
in [Evidence/Milestone4Remaining/source-manifest.json](Evidence/Milestone4Remaining/source-manifest.json)
(`implementation-freeze-6.json`, `Package.swift`
`2733007bb6eff3094ab984520bf6add9ebcb328968a1af16bd5ce908c446c834`). Post-fix
gates verified zero source/package drift against the 1,195 files in
[Evidence/Milestone4Remaining/source-manifest-final.json](Evidence/Milestone4Remaining/source-manifest-final.json)
(`implementation-freeze-8.json`), where `VarDCTSmallAnalysis.swift` extracted
its 90-line `withUnsafeMutableBufferPointer` closure body into private helper
`apply(_:identifier:buffer:dct:)` and explicit closure parameter/return type
annotations were added in `VarDCTEncoderPreparationTests.swift` and
`VarDCTWorkspaceTests.swift`, with `SwiftJXL.o` (`1102488958caf5f9385e3bfdaa56fa5abb057abc39209dcfd2ebeb6737931ac2`
in Release) byte-for-byte identical across all four modes (`Release`, `Debug`,
`ASan`, `TSan`) and `SwiftJXLCore.o` (`813d5b7132feffc779b14de6f6a855c5d6116ce3f7a1be4351610fd3e2a36bbd`
in Release) verified by full native Release, full `iOS 26.0` Simulator Release,
and targeted `Debug`/`ASan`/`TSan` VarDCT suites. Earlier progression and failed
discovery runs are retained in [Evidence/Milestone4Remaining/prior-attempts.json](Evidence/Milestone4Remaining/prior-attempts.json),
source provenance is in [Evidence/Milestone4Remaining/provenance.json](Evidence/Milestone4Remaining/provenance.json),
and the consolidated validation index is tracked at
[Evidence/Milestone4Remaining/validation.json](Evidence/Milestone4Remaining/validation.json):

- **Native macOS core test suites (365 declarations, 1,806 parameterised starts, 2,048 executed cases, 0 failures/errors/skips):**
  - Pre-fix Release (`release-6`, `2026-10-15T06:24:00.884366+00:00` to `06:26:19.568064+00:00`, raw SHA-256 `556d7bca06100008308e57931a5b75c65b1a1498b1b024a437be4e95abe5125d`, [report](Evidence/Milestone4Remaining/release-6-report.json), [log](Evidence/Milestone4Remaining/release-6-run.log.gz), [xml](Evidence/Milestone4Remaining/release-6-tests.xml.gz)): exit 0 (`138.676881875 s`).
  - Post-fix Release (`release-8`, `2026-10-15T15:04:22.222355+00:00` to `15:06:43.090665+00:00`, raw SHA-256 `fa1c5de31dab6e07b953e7cec1032cd4b94a80ec7098822095df84e48b70da11`, [report](Evidence/Milestone4Remaining/release-8-report.json), [log](Evidence/Milestone4Remaining/release-8-run.log.gz), [xml](Evidence/Milestone4Remaining/release-8-tests.xml.gz)): exit 0 (`140.865894 s`).
  - Pre-fix AddressSanitizer (`asan-2`, `2026-10-15T07:07:14.177344+00:00` to `07:09:51.715130+00:00`, raw SHA-256 `276b789bf23c3dddaa4fee2ccbfb2b5f999c37ca9cf26c103cef4c0c6acdf60c`, [report](Evidence/Milestone4Remaining/asan-2-report.json), [log](Evidence/Milestone4Remaining/asan-2-run.log.gz), [xml](Evidence/Milestone4Remaining/asan-2-tests.xml.gz)): exit 0 (`157.532810542 s`).
  - Pre-fix Debug (`debug-1`, `2026-10-15T09:37:12.922420+00:00` to `09:48:23.026762+00:00`, raw SHA-256 `09d8583b266ce437f651de4ab4d636a8a072f700ddcb95b1af72fe49633a673b`, [report](Evidence/Milestone4Remaining/debug-1-report.json), [log](Evidence/Milestone4Remaining/debug-1-run.log.gz), [xml](Evidence/Milestone4Remaining/debug-1-tests.xml.gz)): exit 0 (`670.095734125 s`).
  - Pre-fix ThreadSanitizer (`tsan-1`, `2026-10-15T09:49:52.579527+00:00` to `10:05:34.638883+00:00`, raw SHA-256 `2c5ce9ec32039f55d77c95a266aac4ea88cc35adbad446bb3a867773051e8fb7`, [report](Evidence/Milestone4Remaining/tsan-1-report.json), [log](Evidence/Milestone4Remaining/tsan-1-run.log.gz), [xml](Evidence/Milestone4Remaining/tsan-1-tests.xml.gz)): exit 0 (`942.050330875 s`).
  - Post-fix targeted Debug/ASan/TSan (`debug-3-vardct` [report](Evidence/Milestone4Remaining/debug-3-vardct-report.json) `70.09 s`, `asan-4-vardct` [report](Evidence/Milestone4Remaining/asan-4-vardct-report.json) `116.33 s`, `tsan-3-vardct` [report](Evidence/Milestone4Remaining/tsan-3-vardct-report.json) `118.83 s`): each passed 17 declarations / 43 cases covering `VarDCTWorkspaceTests`, `VarDCTEncoderPreparationTests`, `VarDCTSmallAnalysisTests`, `VarDCTPixelEncoderTests` and `VarDCTDirectRoundTripTests`, and built the full `SwiftJXL.o` and `SwiftJXLCore.o` products.
- **Full iOS Simulator library suite qualification (`359` declarations, `1,955` cases, `0` failures, `0` skips per configuration; `6` `#if os(macOS) || os(Linux)` external-process declarations / `93` cases excluded):**
  - **iOS 26.0 (`23A343`) Minimum-Floor Release (`ios-simulator-26.0-release-2`, final post-fix source, [report](Evidence/Milestone4Remaining/ios-simulator-26.0-release-report.json), [log](Evidence/Milestone4Remaining/ios-simulator-26.0-release-xcodebuild.log.gz), [validator self-test](Evidence/Milestone4Remaining/ios-simulator-26.0-release-validator-self-test.json)):** Passed `359` declarations / `1,955` cases in `204.15 s` (`2026-10-15T15:09:27.677380+00:00` to `15:14:06.361030+00:00`) on `iPhone 17 Pro` (`arm64`), including all `123` `VarDCTARMIntegerTests.retainedHistoricalIntegerOracle` cases, all `45,826` hardware reciprocal vectors, all `3` repaired negative reciprocal-vector sentinels (`missing_file_path`, `short_vector_count_below_40000`, `corrupted_vector_bitpattern` with canonical `[2, 1056931840]` padding producing a `3,364`-byte log), `8/8` validator self-test scenarios, and full contemporaneous pre/post source manifests, runner hashes (`4be74712e4a1fe7a2b1da5e189c15e9e5b0bdb0d3f6383124592d3830001c6d4`), vector hashes, and `13` DerivedData built artifact hashes. Independently audited in `/Users/raster/Documents/Codex/2026-10-15/i/outputs/independent-ios-26.0-results-audit.json`.
  - **iOS 26.5 (`23F77`) Release (`ios-simulator-release`, pre-fix source, [report](Evidence/Milestone4Remaining/ios-simulator-26.5-release-report.json), [log](Evidence/Milestone4Remaining/ios-simulator-26.5-release-xcodebuild.log.gz), [validator self-test](Evidence/Milestone4Remaining/ios-simulator-26.5-release-validator-self-test.json)):** Passed `359` declarations / `1,955` cases in `272.14 s` (`2026-10-15T12:01:43.778286+00:00` to `12:06:15.918318+00:00`), including all `123` ARM integer cases, `45,826` reciprocal vectors, and all `3` negative reciprocal-vector sentinels. Re-audited from preserved `report.original.json` (`d70f101f0115de16699d6cbd05ef87e965c579f51786dc5b2d4e619c7a35f876`) with `evaluationMode: "historical_reaudit"` and `runnerNonDriftStatus: "unknown_not_captured_at_execution"` (original runner hash and DerivedData binary hashes were not captured before cleanup during that initial run; `200` compiled `.swift` source bindings and `8` resource bundles are verified from `xcodebuild.log`).
  - **iOS 26.5 (`23F77`) Debug, AddressSanitizer, and ThreadSanitizer (`ios-simulator-debug-sanitizers`, pre-fix source, [report](Evidence/Milestone4Remaining/ios-simulator-26.5-debug-sanitizers-report.json), [validator self-test](Evidence/Milestone4Remaining/ios-simulator-26.5-debug-sanitizers-validator-self-test.json)):** Passed `359` declarations / `1,955` cases in each configuration with full contemporaneous pre/post source manifests, `runnerSHA256 == runnerSHA256After` (`11d1f427a9310807b584345e7f54d8390f53cce289095ba22451ccdcfb382eed`), and `13` DerivedData built artifact hashes per configuration:
    - `debug` ([log](Evidence/Milestone4Remaining/ios-simulator-26.5-debug-xcodebuild.log.gz)): `359` declarations / `1,955` cases passed in `581.16 s` (`12:14:15` to `12:43:48 UTC`; includes the `15.6 MB` unedited initial `corrupted_vector_bitpattern.log` where all `40,000` vectors failed prior to the canonical `[2, 1056931840]` padding fix).
    - `asan` ([log](Evidence/Milestone4Remaining/ios-simulator-26.5-asan-xcodebuild.log.gz)): `359` declarations / `1,955` cases passed in `893.03 s` (`12:43:50` to `12:58:44 UTC`, `-enableAddressSanitizer YES` / `-sanitize=address`).
    - `tsan` ([log](Evidence/Milestone4Remaining/ios-simulator-26.5-tsan-xcodebuild.log.gz)): `359` declarations / `1,955` cases passed in `1646.99 s` (`12:58:45` to `13:26:12 UTC`, `-enableThreadSanitizer YES` / `-sanitize=thread`).
    - Independently audited across all four `iOS 26.5` configurations in `/Users/raster/Documents/Codex/2026-10-15/i/outputs/independent-ios-results-audit.json`.
- **ARM integer-reference audit ([Evidence/Milestone4Remaining/arm-case-count-audit.json](Evidence/Milestone4Remaining/arm-case-count-audit.json), SHA-256 `7430104619badd72963863cc3dbf849e02bfcdc5da9d945f7e62c93911c21259`):** 123 unique cases started and passed in all native macOS suites (`release-6`, `release-8`, `asan-2`, `debug-1`, `tsan-1`) and all five iOS Simulator suites (`iOS 26.0` Release and `iOS 26.5` Release/Debug/ASan/TSan), with 45,826 hardware reciprocal vectors (`25b402b28eb3dc355f00c2d3c1cd1e130f49e45c6ced1c01550a1b82e7d5453b`, [Evidence/Milestone4Remaining/arm-evidence-audit.json](Evidence/Milestone4Remaining/arm-evidence-audit.json), [Evidence/Milestone4Remaining/arm-reciprocal-swift-report.json](Evidence/Milestone4Remaining/arm-reciprocal-swift-report.json)). See [VARDCT_ARM_PROFILE.md](VARDCT_ARM_PROFILE.md).
- **Standalone consumer & examples ([Evidence/Milestone4Remaining/consumer-final-report.json](Evidence/Milestone4Remaining/consumer-final-report.json), `2026-10-15T09:33:12.263506+00:00` to `09:34:00.856082+00:00`, raw SHA-256 `49025bb58b3f2acfc2d3c6cefcc090b334082598557c9d7fb1cdb1bf0f058fc0`):** `CLIValidationFixtures`, `ContractConsumer` and `MemoryProbe` manifest checks and release `ContractConsumer` run exited 0.
- **CLI qualification (build + 10 CLI/reference test groups including 91 extended JPEG fixtures):**
  - Release ([Evidence/Milestone4Remaining/cli-release-report.json](Evidence/Milestone4Remaining/cli-release-report.json), `2026-10-15T09:34:12.996016+00:00` to `09:35:20.582348+00:00`, command sum `67.544110251 s`, raw SHA-256 `61edd960fb515485184bb2a42e8d6379988f5cef803023d133a66cb3386ece4e`): all 11 commands exited 0.
  - AddressSanitizer ([Evidence/Milestone4Remaining/cli-asan-report.json](Evidence/Milestone4Remaining/cli-asan-report.json), `2026-10-15T09:35:29.598423+00:00` to `09:37:01.011598+00:00`, command sum `91.366463793 s`, raw SHA-256 `d3fa1ebbfb1fa4a7c8a7f1d1dcccdc84d0aac365c6b5c4316b87acae95b286ba`): all 11 commands exited 0.
  - Debug ([Evidence/Milestone4Remaining/cli-debug-report.json](Evidence/Milestone4Remaining/cli-debug-report.json), `2026-10-15T09:48:31.971741+00:00` to `09:49:41.302840+00:00`, command sum `69.286042125 s`, raw SHA-256 `f0970a16983b807e352aa144d267154de966fa6e0d9148b0f21a2608940b721e`): all 11 commands exited 0.
  - ThreadSanitizer ([Evidence/Milestone4Remaining/cli-tsan-report.json](Evidence/Milestone4Remaining/cli-tsan-report.json), `2026-10-15T10:06:05.296954+00:00` to `10:59:14.876010+00:00`, command sum `3189.501351295 s`, raw SHA-256 `635ed46d0b4162130846513d9bb5fc15ba5285c817bdf11b0f419db7a00e27dd`): all 11 commands exited 0.
- **Controlled release performance and RSS ([Evidence/Milestone4Remaining/performance.json](Evidence/Milestone4Remaining/performance.json), generated at `06:38:41 UTC` on the unchanged production object code, raw SHA-256 `2cbb1f8148abed19a18ab56c7eefc069e61b9726ef440b4d4aa82ca821d99f46`, portable SHA-256 `bd85589677342ac9d61d1b6dfd9c8e958de41ebb1af0c9e45f145ec2e04cbae8`, [raw evidence](Evidence/Milestone4Remaining/performance-raw.json.gz)):**
  - Primary 48-row matrix (`public-default-final-2` `cf16c4675625f6e5dfcd1654a97bba5a075144c7809e8195e643936ccecf6b1c` + `native-results-3` `cfa7bb258d16a5bbda9d1bc17ad59ceb8dc8ef755b24a25ba34953f37928672f`, 37 paired / 11 candidate-only): **0 repeated latency triggers, 0 repeated RSS triggers, 0 lossless size triggers**.
  - Constrained one-worker diagnostic matrix (`constrained-final-1` `77671a1136e12be17aa5e1b8dd346a783032d74027e7ccfd4c53b05ad6fd4c50`, 36 rows / 28 paired): **0 repeated RSS triggers, 0 lossless size triggers, 10 repeated latency triggers** retained as diagnostic evidence. See [MILESTONE4_PERFORMANCE_FOLLOWUP.md](MILESTONE4_PERFORMANCE_FOLLOWUP.md).
- **Available Apple SDK and simulator smoke checks ([Evidence/Milestone4Remaining/platform-validation-report.json](Evidence/Milestone4Remaining/platform-validation-report.json), `2026-10-15T10:59:31.546222+00:00` to `11:04:50.040696+00:00`, raw SHA-256 `79f00ec23232f58ccfd3a2eb39ef145a5fab26c6e6cc4d7caa1c9eb87ca8ac22`):**
  - 10 Apple SDK target builds ([Evidence/Milestone4Remaining/sdk-builds-report.json](Evidence/Milestone4Remaining/sdk-builds-report.json), raw SHA-256 `9380c64a841aac064a2bc1047f23f0b318074adabb6d6a31827c21e5c8f08ae2`): all 10 profiles (`ios-device`, `ios-simulator`, `tvos-device`, `tvos-simulator`, `visionos-device`, `visionos-simulator`, `watchos-device`, `watchos-device-32`, `watchos-simulator`, `macos-intel`) exited 0.
  - 4 simulator smoke probes ([Evidence/Milestone4Remaining/runtime-report.json](Evidence/Milestone4Remaining/runtime-report.json), raw SHA-256 `bcd724b97777aa4aa2cf2532d4988049065794e2bf9ea1eb9b4919d492751ad1`, [runtimes](Evidence/Milestone4Remaining/runtimes.json), [physical devices](Evidence/Milestone4Remaining/physical-devices.json)): `iOS 26.5`, `tvOS 26.5`, `visionOS (xrOS) 26.5` and `watchOS 26.0` probes all passed (`result.status == "passed"`, 15 checks and 91 `jpegExtendedCases` verified per simulator; `xcrun devicectl list devices` recorded 4 simulated device entries and 0 physical device entries).
- **Outstanding / unexecuted gates (Milestone 4 is not declared complete as a whole):**
  - Exact `macOS 26.0` native/VM runtime execution (**unexecuted**; local host is `macOS 27.0.1` build `26A434`, and GitHub Actions' `macos-26-arm64` hosted runner image runs `macOS 26.6.2` build `25G83`).
  - Out-of-scope hardware and non-iOS/macOS simulator targets (**unexecuted / out of scope** for this macOS+iOS slice: native Intel `x86_64` macOS, physical iPhone/iPad/Apple TV/Apple Watch/Vision Pro devices, and full XCTest/Swift Testing bundles on `tvOS`/`watchOS`/`visionOS` simulators).
  - Three 3,600-second ASan JPEG mutation campaigns (`jpeg-inspect`, `jpeg-decode`, `jpeg-caller` via `Scripts/test-jpeg-mutations.py`) (**unexecuted**; security work is scoped to defensive source review and ordinary local regression/sanitizer suites).
  - Hosted GitHub Actions CI verification on the updated PR #33 head commit (**pending** CI execution after push).

## Milestone 1–4 completion and pending summary (excluding Milestone 5)

| Milestone | Scope | Completed & verified | Pending / unexecuted or out of scope |
| --- | --- | --- | --- |
| **Milestone 1** | Public API, owning-memory contract, `Span`/`RawSpan` borrows, cancellation/resource budgets, `swiftjxl-cli` foundation ([Documentation/MILESTONE1.md](../../MILESTONE1.md)) | **Complete.** Public types, owning `ImageBuffer`/`EncodedImage`, non-escaping unsafe borrows, `ContractConsumer` independent package, and CLI exit/diagnostic contract verified under Swift 6.2 & 6.4. | None within Milestone 1 scope. |
| **Milestone 2** | Lossless Modular still-image codec (integer greyscale/RGB/alpha, RCT/squeeze/palette, MA trees, rANS/prefix entropy, ICC/low-precision/PNM/NRRD) | **Complete for implemented integer profiles.** Full 1–16-bit integer Modular encode/decode, ICC preservation, PNM/NRRD CLI adapters, and higher-effort admission/learner caps verified against independent `libjxl` (`djxl`/`cjxl`). | Signed/float sample types and higher-effort public exposure beyond default effort 3 remain explicitly deferred outside the implemented integer profile. |
| **Milestone 3** | Reversible native JPEG recompression (`JBRD` container, Brotli metadata, progressive/sequential DCT bridge) and bounded VarDCT still/animation codec | **Complete for implemented profiles.** Reversible 8-bit DCT JPEG transcoding (`Transcoder`), VarDCT 8–16-bit sRGB lossy encode/decode (21 transform strategies, hierarchical search, adaptive quantisation, Gaborish, EPF), and independent-frame animation verified against independent scalar and `libjxl` oracles. | Lossy ICC encoding, associated-alpha VarDCT encoding, and progressive/dependent-frame VarDCT decoding remain explicitly unsupported boundaries. |
| **Milestone 4** | Predecessor performance parity, ARM integer reference profile, extended JPEG pixel decoding (12-bit DCT, 2–16-bit SOF3, ICC/Exif), platform & sanitizer qualification | **Substantially complete in scoped macOS + iOS slice:**<br>• 48-row primary release benchmark matrix passed (`0` repeated latency/RSS/lossless-size triggers; 10 one-worker diagnostic latency rows retained).<br>• All `123` ARM integer reference cases & `45,826` hardware reciprocal vectors passed on macOS and iOS Simulator.<br>• Native macOS `Release` (`release-6`, `release-8`), `Debug` (`debug-1`, `debug-3-vardct`), `ASan` (`asan-2`, `asan-4-vardct`), `TSan` (`tsan-1`, `tsan-3-vardct`) passed (`365` declarations / `2,048` cases) plus CLI `Release`/`Debug`/`ASan`/`TSan` (`44/44` commands).<br>• Full iOS Simulator library suite (`359` declarations / `1,955` cases) passed on **`iOS 26.0` (`23A343`, Release)** and **`iOS 26.5` (`23F77`, Release, Debug, ASan, TSan)**.<br>• 10 Apple SDK target builds and 4 simulator smoke probes (`iOS 26.5`, `tvOS 26.5`, `visionOS 26.5`, `watchOS 26.0`) passed.<br>• Swift 6.2 type-checker timeout repaired and verified across macOS and iOS 26.0 Simulator. | • **Exact `macOS 26.0` runtime execution:** Unexecuted (host is `macOS 27.0.1` `26A434`; GitHub `macos-26-arm64` runner is `macOS 26.6.2` `25G83`).<br>• **Hosted CI on updated PR #33 head:** Pending execution after push.<br>• **10 constrained one-worker (`maximumWorkers=1`) latency rows:** Retained as diagnostic evidence.<br>• **3×3600s malformed-JPEG mutation campaigns:** Unexecuted.<br>• **Out of scoped macOS+iOS slice:** Native Intel `x86_64`, physical Apple devices (`0` attached), and full test-bundle runs on `tvOS`/`watchOS`/`visionOS` simulators. |

