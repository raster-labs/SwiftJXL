# SwiftJXL

JPEG XL for the **Swift Image Compression Suite**.

**Status: stable release `2.0.1` (`v2.0.1`).** The public Modular decoder supports bounded 1–16-bit greyscale/RGB and optional alpha, grouped/progressive integer streams, RCT, simple palettes and Squeeze. It writes directly to owning planar/interleaved UInt8/UInt16 destinations with explicit offsets and strides; allocating decode uses UInt16. Decode also preserves embedded grey/RGB ICC profiles exactly; encoding accepts the integer colour/alpha layouts without ICC at fixed effort 3. See [MIGRATION.md](MIGRATION.md), [Documentation/RELEASE-v2.0.1.md](Documentation/RELEASE-v2.0.1.md) and [Documentation/RELEASE-v2.0.0.md](Documentation/RELEASE-v2.0.0.md) for precise bounds and disclosed gates. CLI UInt16 NRRD and integer colour PGM/PPM/PAM encode/decode and bounded native JPEG reconstruction are available. Bounded single-frame sRGB VarDCT decoding and explicit lossy encoding support 8–16 meaningful bits with optional straight alpha, through the public storage API and CLI. Hierarchical transform search through 64×64, grouped encoding/decoding and bounded independent-frame animation encoding/decoding are implemented.

SwiftJXL is the standalone successor to [JXLSwift](https://github.com/Raster-Lab/JXLSwift). The successor is intended to provide a harmonised API, explicit memory ownership, high-precision sample preservation and efficient shared-storage integration. It has no mandatory dependency on another suite library or CompressionFamily. MIT licensing applies to these documents and subsequent authorised in-house implementation; third-party material retains its own terms.

Milestone 5 library qualification is tracked in the [qualification record](Documentation/Engineering/Release/QUALIFICATION.md): platform/sanitizer execution, clean versioned consumption, synchronised examples, source/fixture provenance and validated derived SBOMs. Physical-device testing and DICOMKit integration remain excluded from the library qualification assignment and are disclosed in [Documentation/RELEASE-v2.0.1.md](Documentation/RELEASE-v2.0.1.md) and [Documentation/RELEASE-v2.0.0.md](Documentation/RELEASE-v2.0.0.md). The [checklist](Documentation/Engineering/Release/release-gates.json) distinguishes assigned-task completion from physical-device readiness.

## Release version

Current stable version: **2.0.1** ([VERSION](VERSION), tagged `v2.0.1`); shared contract **0.10.0**. Consumable via Swift Package Manager with `.package(url: "https://github.com/raster-labs/SwiftJXL.git", from: "2.0.1")`. See [Documentation/RELEASE-v2.0.1.md](Documentation/RELEASE-v2.0.1.md), [Documentation/RELEASE-v2.0.0.md](Documentation/RELEASE-v2.0.0.md) and the [migration preflight record](Documentation/Engineering/Migration/README.md) for adopted features, exact Xcode/Swift Build evidence and open platform gates. The historical [Milestone 1 evidence](Documentation/MILESTONE1.md) remains unchanged.

## Intended platform baseline

Swift 6.2 manifest minimum with Swift 6.4 as the qualified primary toolchain, Swift 6 language mode and complete concurrency checking. Apple OS deployment minima: macOS, iOS/iPadOS, tvOS, visionOS and watchOS 26.0. Apple Silicon is the primary optimisation target. macOS x86_64 and Linux ARM64/x86_64 are included with cleanly separated platform/architecture support. Ubuntu 24.04 is the initial Linux engineering baseline. These are requirements, not completed qualification claims.

## Start reading

Moving an application from JXLSwift? Read the [application migration guide](MIGRATION.md) for dependency/API mappings, ownership changes, a compilable preparation example and staged rollout checks. Bounded integer Modular and native JPEG reconstruction profiles are implemented; broader feature coverage and release qualification remain open.

The first coding task is **Milestone 1: API and memory-contract feasibility**, using synthetic buffers. Its implementation and local test evidence are recorded in [Milestone 1 validation](Documentation/MILESTONE1.md). Codec migration and the first real shared-storage transcode follow in Milestones 2 and 3. Use the staged instructions in [AGENTS.md](AGENTS.md).

- [Coding-agent entry point](AGENTS.md) and [codec-specific implementation plan](IMPLEMENTATION.md).
- [Suite policy](Documentation/SUITE_POLICY.md) and [common API](Documentation/COMMON_API.md).
- [Memory ownership and no-copy hand-off](Documentation/MEMORY_CONTRACT.md).
- [Unit, regression and security testing](Documentation/TESTING.md).
- [Performance gates](Documentation/PERFORMANCE.md), [platforms](Documentation/PLATFORMS.md) and [CLI](Documentation/CLI_CONTRACT.md).
- [History and source provenance](HISTORY.md), [change log](CHANGELOG.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md) and [MIT licence](LICENSE).

## Native in-memory transcoding

Standalone **reversible existing-JPEG ↔ JPEG XL transcoding** restores the original JPEG bytes from the JXL alone for the implemented bounded profile, with coefficients and reconstruction metadata held in memory. This preserves an existing lossy JPEG without recovering pixels lost during its original encoding. See the [current profile](MIGRATION.md#native-jpeg-transcoder-integration) and [validation record](Documentation/Engineering/Migration/NATIVE_JPEG.md) for exact limits and evidence; broader JPEG XL coverage remains open.

## Relationship to the suite

The four independent libraries are SwiftJ2K, SwiftJLS, SwiftJXL and SwiftJLI, all intended to live under Raster-Lab. A future optional umbrella adapts them for codec selection and in-process transcoding. The codecs do not depend on that umbrella. SwiftCompressionFamily is not part of this successor plan. The common contract is mirrored documentation plus behavioural tests, not a shared runtime package.

The package exports `SwiftJXL`; the diagnostic CLI `swiftjxl-cli` provides help/version/capabilities and supported-profile inspection/validation. A [standalone public consumer](Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift) has been compiled and run. It creates a padded 12-in-16 greyscale image, checks known samples and exercises the public API. Run `bash Scripts/validate.sh` for the local contract checks. Features from the predecessor are migration candidates whose exact coverage must be verified; see IMPLEMENTATION.md. Nothing here changes the predecessor repository's current maintenance configuration.

## Command-line help and manual

The diagnostic CLI now provides `-h` / `--help`, `help <command>`, version and truthful capability reporting. The `inspect` and `validate` commands process the bounded scalar profile; encode/decode use explicit NRRD or integer colour PNM/PAM profiles; transcode supports the qualified native JPEG reconstruction pair. Verbosity has five levels: `-v`, `-vv`, `--verbose 1..5`, `--verbose=+++` and `-verbose: 3`; diagnostics use stderr and `--quiet` suppresses optional messages. See [CLI usage and installation](CLI.md). The installer updates both the executable and its UNIX man page together. The current contract keeps Apple deployment floors at 26.0 and the compiler minimum at Swift 6.2; OS 27 qualification records remain historical.

The [Milestone 4 completion record](Documentation/Engineering/Migration/MILESTONE4_COMPLETION.md) tracks the remaining feature work, implementation-before-validation order, and evidence gates. The development branch adds explicit pixel containers, bounded JPEG pixel convenience decoding and CLI animation; it does not claim final qualification or a production cutover.

The [remaining-work follow-up](Documentation/Engineering/Migration/MILESTONE4_REMAINING.md) tracks predecessor regressions, ARM reference semantics, extended JPEG pixels, per-entry security campaigns and unavailable hardware separately. New implementation is not qualified by historical checkpoint results.
