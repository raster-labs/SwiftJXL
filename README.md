# SwiftJXL

JPEG XL for the **Swift Image Compression Suite**.

**Status: initial public scalar JPEG XL integration on the migration branch.** `Encoder`, `Decoder.inspect`, allocating decode and caller-destination decode support a bounded lossless unsigned greyscale profile. Encoding supports 9–16 meaningful bits through 512 × 512; decoding supports 8–16 bits through 1024 × 1024, in one frame/group without transforms. Both use 16-bit owning storage with explicit byte order, row padding and pixel stride. Resource admission covers retained input, destination, workspace and output. See [MIGRATION.md](MIGRATION.md) for metadata and profile limits. JPEG reconstruction, broader colour/VarDCT profiles and CLI file operations remain unavailable. Keep JXLSwift in production; **2.1.0 is not a published release**.

SwiftJXL is the standalone successor to [JXLSwift](https://github.com/Raster-Lab/JXLSwift). The successor is intended to provide a harmonised API, explicit memory ownership, high-precision sample preservation and efficient shared-storage integration. It has no mandatory dependency on another suite library or CompressionFamily. Apache-2.0 licensing applies to these documents and subsequent authorised in-house implementation; third-party material retains its own terms.

## Swift 6.4 development candidate

Current development version: **2.1.0-dev.2** ([VERSION](VERSION)); shared contract **0.10.0**. This increments the earlier unreleased 2.0.0 target and creates no release/tag. See the [migration preflight record](Documentation/Engineering/Migration/README.md) for adopted features, exact Xcode/Swift Build evidence and open platform gates. The historical [Milestone 1 evidence](Documentation/MILESTONE1.md) remains unchanged.

## Intended platform baseline

Swift 6.2 manifest minimum with Swift 6.4 as the qualified primary toolchain, Swift 6 language mode and complete concurrency checking. Apple OS deployment minima: macOS, iOS/iPadOS, tvOS, visionOS and watchOS 26.0. Apple Silicon is the primary optimisation target. macOS x86_64 and Linux ARM64/x86_64 are included with cleanly separated platform/architecture support. Ubuntu 24.04 is the initial Linux engineering baseline. These are requirements, not completed qualification claims.

## Start reading

Moving an application from JXLSwift? Read the [application migration guide](MIGRATION.md) for dependency/API mappings, ownership changes, a compilable preparation example and staged rollout checks. Real codec replacement remains blocked by the deferred encoding, decoding and reconstruction implementations.

The first coding task is **Milestone 1: API and memory-contract feasibility**, using synthetic buffers. Its implementation and local test evidence are recorded in [Milestone 1 validation](Documentation/MILESTONE1.md). Codec migration and the first real shared-storage transcode follow in Milestones 2 and 3. Use the staged instructions in [AGENTS.md](AGENTS.md).

- [Coding-agent entry point](AGENTS.md) and [codec-specific implementation plan](IMPLEMENTATION.md).
- [Suite policy](Documentation/SUITE_POLICY.md) and [common API](Documentation/COMMON_API.md).
- [Memory ownership and no-copy hand-off](Documentation/MEMORY_CONTRACT.md).
- [Unit, regression and security testing](Documentation/TESTING.md).
- [Performance gates](Documentation/PERFORMANCE.md), [platforms](Documentation/PLATFORMS.md) and [CLI](Documentation/CLI_CONTRACT.md).
- [History and source provenance](HISTORY.md), [change log](CHANGELOG.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md) and [Apache-2.0 licence](LICENSE).

## Native in-memory transcoding

Planned standalone **reversible existing-JPEG ↔ JPEG XL transcoding** restores the original JPEG bytes from the JXL alone, with coefficients and reconstruction metadata held in memory. The predecessor already exposes forward/reverse methods and byte-equality tests; the supported JPEG/metadata profiles still require qualification. This preserves an existing lossy JPEG without recovering pixels lost during its original encoding. See [transcoding instructions and source-review findings](TRANSCODING.md) for the API/CLI pattern, limits and acceptance tests. This remains planned successor functionality.

## Relationship to the suite

The four independent libraries are SwiftJ2K, SwiftJLS, SwiftJXL and SwiftJLI, all intended to live under Raster-Lab. A future optional umbrella adapts them for codec selection and in-process transcoding. The codecs do not depend on that umbrella. SwiftCompressionFamily is not part of this successor plan. The common contract is mirrored documentation plus behavioural tests, not a shared runtime package.

The package exports `SwiftJXL`; the diagnostic CLI `swiftjxl-cli` provides help/version/capabilities. A [standalone public consumer](Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift) has been compiled and run. It creates a padded 12-in-16 greyscale image, checks known samples and verifies explicit codec unavailability. Run `bash Scripts/validate.sh` for the local contract checks. Features from the predecessor are migration candidates whose exact coverage must be verified; see IMPLEMENTATION.md. Nothing here changes the predecessor repository's current maintenance configuration.

## Command-line help and manual

The diagnostic CLI now provides `-h` / `--help`, `help <command>`, version and truthful capability reporting. Codec commands remain unavailable. Verbosity has five levels: `-v`, `-vv`, `--verbose 1..5`, `--verbose=+++` and `-verbose: 3`; diagnostics use stderr and `--quiet` suppresses optional messages. See [CLI usage and installation](CLI.md). The installer updates both the executable and its UNIX man page together. The current contract keeps Apple deployment floors at 26.0 and the compiler minimum at Swift 6.2; OS 27 qualification records remain historical.
