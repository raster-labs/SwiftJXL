# SwiftJXL

JPEG XL for the **Swift Image Compression Suite**.

**Status: migration branch, not a published release.** The public Modular decoder now supports bounded greyscale/RGB and optional alpha, grouped/progressive integer streams, RCT, simple palettes and Squeeze. It writes directly to owning planar/interleaved UInt8/UInt16 destinations with explicit offsets and strides; allocating decode uses UInt16. Encoding now accepts the same integer colour/alpha layouts at fixed effort 3. See [MIGRATION.md](MIGRATION.md) for precise bounds and unqualified gates. CLI UInt16 NRRD and integer colour PGM/PPM/PAM encode/decode and bounded native JPEG reconstruction are available. Broader VarDCT pixel profiles and full migration qualification are pending. Keep JXLSwift in production; **2.1.0 is not a published release**.

SwiftJXL is the standalone successor to [JXLSwift](https://github.com/Raster-Lab/JXLSwift). The successor is intended to provide a harmonised API, explicit memory ownership, high-precision sample preservation and efficient shared-storage integration. It has no mandatory dependency on another suite library or CompressionFamily. Apache-2.0 licensing applies to these documents and subsequent authorised in-house implementation; third-party material retains its own terms.

## Swift 6.4 development candidate

Current development version: **2.1.0-dev.2** ([VERSION](VERSION)); shared contract **0.10.0**. This increments the earlier unreleased 2.0.0 target and creates no release/tag. See the [migration preflight record](Documentation/Engineering/Migration/README.md) for adopted features, exact Xcode/Swift Build evidence and open platform gates. The historical [Milestone 1 evidence](Documentation/MILESTONE1.md) remains unchanged.

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
- [History and source provenance](HISTORY.md), [change log](CHANGELOG.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md) and [Apache-2.0 licence](LICENSE).

## Native in-memory transcoding

Standalone **reversible existing-JPEG ↔ JPEG XL transcoding** restores the original JPEG bytes from the JXL alone for the implemented bounded profile, with coefficients and reconstruction metadata held in memory. This preserves an existing lossy JPEG without recovering pixels lost during its original encoding. See the [current profile](MIGRATION.md#native-jpeg-transcoder-integration) and [validation record](Documentation/Engineering/Migration/NATIVE_JPEG.md) for exact limits and evidence; broader JPEG XL coverage remains open.

## Relationship to the suite

The four independent libraries are SwiftJ2K, SwiftJLS, SwiftJXL and SwiftJLI, all intended to live under Raster-Lab. A future optional umbrella adapts them for codec selection and in-process transcoding. The codecs do not depend on that umbrella. SwiftCompressionFamily is not part of this successor plan. The common contract is mirrored documentation plus behavioural tests, not a shared runtime package.

The package exports `SwiftJXL`; the diagnostic CLI `swiftjxl-cli` provides help/version/capabilities and supported-profile inspection/validation. A [standalone public consumer](Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift) has been compiled and run. It creates a padded 12-in-16 greyscale image, checks known samples and exercises the public API. Run `bash Scripts/validate.sh` for the local contract checks. Features from the predecessor are migration candidates whose exact coverage must be verified; see IMPLEMENTATION.md. Nothing here changes the predecessor repository's current maintenance configuration.

## Command-line help and manual

The diagnostic CLI now provides `-h` / `--help`, `help <command>`, version and truthful capability reporting. The `inspect` and `validate` commands process the bounded scalar profile; encode/decode use explicit NRRD or integer colour PNM/PAM profiles; transcode supports the qualified native JPEG reconstruction pair. Verbosity has five levels: `-v`, `-vv`, `--verbose 1..5`, `--verbose=+++` and `-verbose: 3`; diagnostics use stderr and `--quiet` suppresses optional messages. See [CLI usage and installation](CLI.md). The installer updates both the executable and its UNIX man page together. The current contract keeps Apple deployment floors at 26.0 and the compiler minimum at Swift 6.2; OS 27 qualification records remain historical.
