# Milestone 4 remaining work

Merged PR32 baseline: `efce6a973c96d3e49e9facc3510966d7ab0563a1`.
Its tree matches the original continuation checkpoint
`540a0b13c035c587915a5226a4f47f7db2f37bac`.
Pinned predecessor: `57e81cb9e2411d1efac435b429a306a031744c1e`.
Common contract: **0.10.0**, unchanged. Branch:
`codex/swiftjxl-milestone4-remaining`.

The owner requested implementation of remaining items 2–6 before validation,
then review, commit and push to a new branch. Unavailable hardware is recorded
for a later owner decision. That instruction does not waive physical runtime
gates or imply full platform qualification. The owner checks hosted CI and
merges; no CI polling, merge, release, tag or production cutover is authorised.

## Implementation and validation separation

Source, meaningful regression tests, fixture generators and all validation
harnesses were prepared and audited before the final validation phase. The
earlier [completion checkpoint](MILESTONE4_COMPLETION.md) records historical
results for its original source; it does not validate these changes. Final
validation results below are bound to the 1,195-file final source manifest
(`implementation-freeze-6.json`, `Package.swift`
`2733007bb6eff3094ab984520bf6add9ebcb328968a1af16bd5ce908c446c834`).

| Item | Prepared work | Final validation |
| --- | --- | --- |
| 2: predecessor regressions | Reduce entropy and transform scratch/loop overhead; compact constant-image coding retains strict terminal checks | Primary 48-row release matrix (`public-default-final-2` 36 rows / 28 paired + `native-results-3` 12 rows / 9 paired) passed with 0 repeated latency, RSS or lossless-size triggers; 10 constrained one-worker (`maximumWorkers=1`) latency triggers retained as diagnostic evidence; 11 candidate-only rows retained without predecessor speedup claims |
| 3: executable platforms | Reusable SDK/simulator and native/physical runtime runners | Local macOS arm64 debug/release/ASan/TSan suites, standalone consumer, 10 Apple SDK builds and 4 simulator smoke probes (`iOS 26.5`, `tvOS 26.5`, `visionOS 26.5`, `watchOS 26.0`) passed; native Intel, physical Apple devices and minimum-OS 26.0 runtimes on macOS/iOS/tvOS/visionOS remain **unexecuted** |
| 4: ARM integer reference | Explicit deterministic reference numerical profile; scalar default and both fixed tolerances retained | Passed all 123 retained historical integer cases, 8 caller-storage cases and 45,826 hardware reciprocal vectors across `release-6`, `asan-2`, `debug-1` and `tsan-1` (`arm/case-count-audit-release-6-asan-2-debug-1-tsan-1.json`) |
| 5: JPEG security | Defensive source review, bounds/admission fixes, canary self-tests, ordinary local regression/sanitizer suites, and source-pinned ASan mutation harness (`Scripts/test-jpeg-mutations.py`) | Defensive source review and local regression/ASan/TSan suites passed; the three 3,600-second per-entry mutation campaigns (`jpeg-inspect`, `jpeg-decode`, `jpeg-caller`) remain **unexecuted** on the final source manifest |
| 6: JPEG capabilities | 12-bit DCT, SOF3 predictive samples and explicit ICC/Exif interpretation | Passed 365 declarations / 2,048 cases in `release-6`, `asan-2`, `debug-1` and `tsan-1`, plus 91 extended CLI JPEG fixtures in `cli-release`, `cli-asan`, `cli-debug` and `cli-tsan`, and 91 extended JPEG cases in each of the 4 simulator smoke probes |

## Unavailable hardware and minimum runtimes

The 15 October 2026 local inventory reports an arm64 Mac and no physical Apple
devices. Available simulators are iOS/tvOS/visionOS 26.5 and watchOS 26.0 (some
27.0 runtimes are installed but are not substitutes for the minimum-runtime
gates). Native Intel macOS, representative physical iPhone/iPad/Apple TV/Watch/
Vision Pro, and iOS/tvOS/visionOS 26.0 runtime execution remain **unexecuted**.
The host runs macOS 27.0.1 (26A434), so macOS 26.0 runtime execution is also
unexecuted. A newer host does not prove the deployment-floor runtime behaviour. Cross-compilation does not close any of these
gates. No unavailable result is counted as passed or waived.

`Scripts/TestSupport/qualify-native-runtime.py` refuses Rosetta for native-host
claims, requires physical-device identity and optional exact 26.0 runtime,
and records commands/source hashes/results and executed-test counts. A physical
run requires an explicit device and existing signed Xcode test-host project/
workspace. Its output remains source-unverified until the test host's package
resolution and linked-source manifest establish that it exercised this checkout. The simulator
runner accepts `--runtime-version 26.0` and fails if that runtime is absent.

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

All executed gates below verified zero source/package drift against the 1,195
files in `Sources/` and `Tests/` plus `Package.swift`
(`2733007bb6eff3094ab984520bf6add9ebcb328968a1af16bd5ce908c446c834`, tracked
portably in [Evidence/Milestone4Remaining/source-manifest.json](Evidence/Milestone4Remaining/source-manifest.json)).
Earlier progression and failed discovery runs (`release-1` through `release-5`,
`asan-1`, and prior-source 14 October `release-7`/`asan-7` and
`release-8`/`asan-8`) are retained in
[Evidence/Milestone4Remaining/prior-attempts.json](Evidence/Milestone4Remaining/prior-attempts.json)
and superseded by the final-source runs below. Source provenance is recorded in
[Evidence/Milestone4Remaining/provenance.json](Evidence/Milestone4Remaining/provenance.json)
and the consolidated validation index is tracked at
[Evidence/Milestone4Remaining/validation.json](Evidence/Milestone4Remaining/validation.json):

- **Core test suites (365 declarations, 1,806 parameterised starts, 2,048 executed cases, 0 failures/errors/skips):**
  - Release (`release-6`, `2026-10-15T06:24:00.884366+00:00` to `06:26:19.568064+00:00`, raw SHA-256 `556d7bca06100008308e57931a5b75c65b1a1498b1b024a437be4e95abe5125d`, [report](Evidence/Milestone4Remaining/release-6-report.json), [log](Evidence/Milestone4Remaining/release-6-run.log.gz), [xml](Evidence/Milestone4Remaining/release-6-tests.xml.gz)): exit 0 (`138.676881875 s`).
  - AddressSanitizer (`asan-2`, `2026-10-15T07:07:14.177344+00:00` to `07:09:51.715130+00:00`, raw SHA-256 `276b789bf23c3dddaa4fee2ccbfb2b5f999c37ca9cf26c103cef4c0c6acdf60c`, [report](Evidence/Milestone4Remaining/asan-2-report.json), [log](Evidence/Milestone4Remaining/asan-2-run.log.gz), [xml](Evidence/Milestone4Remaining/asan-2-tests.xml.gz)): exit 0 (`157.532810542 s`).
  - Debug (`debug-1`, `2026-10-15T09:37:12.922420+00:00` to `09:48:23.026762+00:00`, raw SHA-256 `09d8583b266ce437f651de4ab4d636a8a072f700ddcb95b1af72fe49633a673b`, [report](Evidence/Milestone4Remaining/debug-1-report.json), [log](Evidence/Milestone4Remaining/debug-1-run.log.gz), [xml](Evidence/Milestone4Remaining/debug-1-tests.xml.gz)): exit 0 (`670.095734125 s`).
  - ThreadSanitizer (`tsan-1`, `2026-10-15T09:49:52.579527+00:00` to `10:05:34.638883+00:00`, raw SHA-256 `2c5ce9ec32039f55d77c95a266aac4ea88cc35adbad446bb3a867773051e8fb7`, [report](Evidence/Milestone4Remaining/tsan-1-report.json), [log](Evidence/Milestone4Remaining/tsan-1-run.log.gz), [xml](Evidence/Milestone4Remaining/tsan-1-tests.xml.gz)): exit 0 (`942.050330875 s`).
- **ARM integer-reference audit ([Evidence/Milestone4Remaining/arm-case-count-audit.json](Evidence/Milestone4Remaining/arm-case-count-audit.json), SHA-256 `7430104619badd72963863cc3dbf849e02bfcdc5da9d945f7e62c93911c21259`):** 123 unique cases started and passed in all four suites, with 45,826 hardware reciprocal vectors (`25b402b28eb3dc355f00c2d3c1cd1e130f49e45c6ced1c01550a1b82e7d5453b`, [Evidence/Milestone4Remaining/arm-evidence-audit.json](Evidence/Milestone4Remaining/arm-evidence-audit.json), [Evidence/Milestone4Remaining/arm-reciprocal-swift-report.json](Evidence/Milestone4Remaining/arm-reciprocal-swift-report.json)). See [VARDCT_ARM_PROFILE.md](VARDCT_ARM_PROFILE.md).
- **Standalone consumer & examples ([Evidence/Milestone4Remaining/consumer-final-report.json](Evidence/Milestone4Remaining/consumer-final-report.json), `2026-10-15T09:33:12.263506+00:00` to `09:34:00.856082+00:00`, raw SHA-256 `49025bb58b3f2acfc2d3c6cefcc090b334082598557c9d7fb1cdb1bf0f058fc0`):** `CLIValidationFixtures`, `ContractConsumer` and `MemoryProbe` manifest checks and release `ContractConsumer` run exited 0.
- **CLI qualification (build + 10 CLI/reference test groups including 91 extended JPEG fixtures):**
  - Release ([Evidence/Milestone4Remaining/cli-release-report.json](Evidence/Milestone4Remaining/cli-release-report.json), `2026-10-15T09:34:12.996016+00:00` to `09:35:20.582348+00:00`, command sum `67.544110251 s`, raw SHA-256 `61edd960fb515485184bb2a42e8d6379988f5cef803023d133a66cb3386ece4e`): all 11 commands exited 0.
  - AddressSanitizer ([Evidence/Milestone4Remaining/cli-asan-report.json](Evidence/Milestone4Remaining/cli-asan-report.json), `2026-10-15T09:35:29.598423+00:00` to `09:37:01.011598+00:00`, command sum `91.366463793 s`, raw SHA-256 `d3fa1ebbfb1fa4a7c8a7f1d1dcccdc84d0aac365c6b5c4316b87acae95b286ba`): all 11 commands exited 0.
  - Debug ([Evidence/Milestone4Remaining/cli-debug-report.json](Evidence/Milestone4Remaining/cli-debug-report.json), `2026-10-15T09:48:31.971741+00:00` to `09:49:41.302840+00:00`, command sum `69.286042125 s`, raw SHA-256 `f0970a16983b807e352aa144d267154de966fa6e0d9148b0f21a2608940b721e`): all 11 commands exited 0.
  - ThreadSanitizer ([Evidence/Milestone4Remaining/cli-tsan-report.json](Evidence/Milestone4Remaining/cli-tsan-report.json), `2026-10-15T10:06:05.296954+00:00` to `10:59:14.876010+00:00`, command sum `3189.501351295 s`, raw SHA-256 `635ed46d0b4162130846513d9bb5fc15ba5285c817bdf11b0f419db7a00e27dd`): all 11 commands exited 0.
- **Controlled release performance and RSS ([Evidence/Milestone4Remaining/performance.json](Evidence/Milestone4Remaining/performance.json), generated at `06:38:41 UTC` on the same unchanged final source, raw SHA-256 `94eb015eb0c4d19f3d16b40fa9db6407f902e078c92f891a508caeb9f3aa069e`, [raw evidence](Evidence/Milestone4Remaining/performance-raw.json.gz)):**
  - Primary 48-row matrix (`public-default-final-2` `cf16c4675625f6e5dfcd1654a97bba5a075144c7809e8195e643936ccecf6b1c` + `native-results-3` `cfa7bb258d16a5bbda9d1bc17ad59ceb8dc8ef755b24a25ba34953f37928672f`, 37 paired / 11 candidate-only): **0 repeated latency triggers, 0 repeated RSS triggers, 0 lossless size triggers**.
  - Constrained one-worker diagnostic matrix (`constrained-final-1` `77671a1136e12be17aa5e1b8dd346a783032d74027e7ccfd4c53b05ad6fd4c50`, 36 rows / 28 paired): **0 repeated RSS triggers, 0 lossless size triggers, 10 repeated latency triggers** retained as diagnostic evidence. See [MILESTONE4_PERFORMANCE_FOLLOWUP.md](MILESTONE4_PERFORMANCE_FOLLOWUP.md).
- **Available Apple SDK and simulator smoke checks ([Evidence/Milestone4Remaining/platform-validation-report.json](Evidence/Milestone4Remaining/platform-validation-report.json), `2026-10-15T10:59:31.546222+00:00` to `11:04:50.040696+00:00`, raw SHA-256 `79f00ec23232f58ccfd3a2eb39ef145a5fab26c6e6cc4d7caa1c9eb87ca8ac22`):**
  - 10 Apple SDK target builds ([Evidence/Milestone4Remaining/sdk-builds-report.json](Evidence/Milestone4Remaining/sdk-builds-report.json), raw SHA-256 `9380c64a841aac064a2bc1047f23f0b31e074adabb6d6a31827c21e5c8f08ae2`): all 10 profiles (`ios-device`, `ios-simulator`, `tvos-device`, `tvos-simulator`, `watchos-device`, `watchos-simulator`, `visionos-device`, `visionos-simulator`, `maccatalyst`, `macos-cli`) exited 0.
  - 4 simulator smoke probes ([Evidence/Milestone4Remaining/runtime-report.json](Evidence/Milestone4Remaining/runtime-report.json), raw SHA-256 `bcd724b97777aa4aa2cf2532d4988049065794e2bf9ea1eb9b4919d492751ad1`, [runtimes](Evidence/Milestone4Remaining/runtimes.json), [physical devices](Evidence/Milestone4Remaining/physical-devices.json)): `iOS 26.5`, `tvOS 26.5`, `visionOS (xrOS) 26.5` and `watchOS 26.0` probes all passed (`result.status == "passed"`, 15 checks and 91 `jpegExtendedCases` verified per simulator; `xcrun devicectl list devices` recorded 4 simulated device entries and 0 physical device entries).
- **Outstanding / unexecuted required gates (Milestone 4 is not declared complete as a whole):**
  - Native Intel macOS runtime execution (**unexecuted** on this `arm64` host).
  - Representative physical Apple device execution across iPhone/iPad/Apple TV/Apple Watch/Vision Pro (**unexecuted**; 0 physical devices in `devicectl` inventory).
  - Exact minimum-OS **26.0** runtime execution on macOS (host is `macOS 27.0.1` build `26A434`), iOS, tvOS and visionOS (exercised simulators are `26.5`; only `watchOS` simulator is `26.0`) (**unexecuted**).
  - Full XCTest / Swift Testing bundle execution inside non-macOS simulators (**unexecuted**; cross-platform verification on this host covers 10 SDK builds and 4 standalone simulator smoke probes).
  - Three 3,600-second ASan JPEG mutation campaigns (`jpeg-inspect`, `jpeg-decode`, `jpeg-caller` via `Scripts/test-jpeg-mutations.py`) against the final source manifest (**unexecuted**; security work in this session was limited to defensive source review and ordinary local regression/sanitizer suites).
  - Hosted CI on the published follow-up PR (**pending** owner check after push).
