# SwiftJXL — staged implementation instructions

Read AGENTS.md and every common contract document first. Milestone 1 now implements API/storage feasibility; later codec milestones require an owner-assigned task. Follow the common contract when predecessor conventions differ. Maintain performance, reliability and security together. [MIGRATION.md](MIGRATION.md) covers downstream application adoption; update its mappings and availability statements as milestones land.

## Source and destination

Predecessor: [Raster-Lab/JXLSwift](https://github.com/Raster-Lab/JXLSwift) at inspected SHA `760697a54dd253da8e8466c3fd09ecf2c2d89aec`. Highest stable-shaped tag observed: `v1.4.0` (resolve independently before choosing it as a baseline). Target module/product: `SwiftJXL`. Target CLI: `swiftjxl-cli`. Intended first stable library version: `2.1.0`.

Do not migrate code from moving main without recording the selected revision. Reproduce relevant source tests and inspect source-level capabilities. Existing test totals and benchmark claims are historical, not successor acceptance evidence.

## Milestones and exit evidence

| Milestone | Work | Exit evidence |
| --- | --- | --- |
| 1 — contract feasibility | Establish Swift 6.2-minimum package with Swift 6.4 qualification, independent local API/owning-memory types, descriptor validation and safe adapter experiment; no codec algorithm migration | Compiling equivalent public calls, lifecycle/race/error tests, standalone consumer build and contract issues resolved explicitly |
| 2 — migration baseline | Inventory predecessor subsystems/products; select and migrate the smallest native scalar lossless path with Apache-2.0/provenance reconciliation | Pinned predecessor comparison, independent decode/encode validation, exact sample/precision results, no new runtime codec dependency |
| 3 — shared-storage path | Direct final decode into caller storage and encode from compatible sealed storage | Required-sharing copy/allocation/lifetime proof; first suite pair or corresponding codec extension passes |
| 4 — feature/platform coverage | Extend supported modes/layouts, CLI, optional acceleration and all required OS/architecture paths | Capability matrix, codec-specific regressions, platform results, security and performance evidence |
| 5 — release preparation | Validate clean versioned consumption, docs/examples, migration guide, licence/fixture notices and release gates | Reviewed complete evidence; stable tag only after explicit release task |

Work one owner-assigned milestone at a time. Preserve internal algorithm names where helpful, but provide the agreed common public module surface. Do not publish a stable version or announce complete platform support while required gates are missing.


### Migration focus

- The predecessor explicitly removed CompressionFamily and has an independent library target. Preserve that property; replace convention-only API similarity with the common conformance tests.
- `Sources/JXLSwift/Codec/ImageFrame.swift` stores interleaved `[UInt8]`. Adapt final decode output and encoding input to owner-backed, strided storage. Do not simply convert the new Image to another full byte array under require-sharing.
- `Sources/JXLSwift/Codec/AsyncOverloads.swift` forwards directly to synchronous operations. Implement documented background execution, bounded cancellation and progress in the real work path, while preserving structured lifetimes.
- Retain the actual conformant Modular lossless and VarDCT paths. Inventory greyscale/alpha, colour/ICC, extra channels, containers, multi-frame and precision support from source/tests. Do not ship placeholder/private codestream paths as JPEG XL.
- The predecessor implements signed Int16 through a level shift to unsigned samples and explicit signed-output interpretation. The JPEG XL codestream does not acquire native signed-sample semantics from that flag. Define the supported external interpretation contract or reject a standalone signed-preserving request. Test -32768, -1, 0 and 32767 and any copy/transform cost explicitly.
- JPEG-to-JXL reconstructible recompression and restoration are specialised operations. Preserve byte-exact reconstruction evidence independently of decoded-pixel losslessness, with separate evidence for each supported DCT JPEG profile. The DCT reconstruction bridge does not imply SOF3 lossless-JPEG or 12/16-bit JPEG bitstream reconstruction; see TRANSCODING.md.
- The predecessor's Apple-only policy is superseded: add Linux ARM64/x86_64 scalar support by isolating Accelerate/Metal/platform integration. Keep libjxl test-only, never a runtime dependency. Optional native kernels need profiling and a correct scalar Swift reference.

### Codec-specific tests

Test container box sizes/offsets, codestream headers, Modular transforms/predictors/entropy bounds, multi-group boundaries, VarDCT geometries and restoration, alpha/ICC/extra-channel semantics, integer precision and frame compositing where supported. For lossless integer output compare every sample with an independent JPEG XL decoder. For lossy output define colour-domain metrics and tolerances before changes.

Use pinned cjxl/djxl or equivalent independent tools only in oracle jobs. Required interoperability must not pass because a tool is absent. Include independently generated textured/multi-group inputs, not only solid synthetic images. Retain JPEG reconstruction byte-equality fixtures separately. Do not repeat the predecessor's documented lesson of self-round-trip success without independent codestream validity.

### Initial codec delivery — Milestones 2–4

The following codec work follows Milestone 1 contract feasibility. It is not part of the first coding task. Migrate the scalar path in Milestone 2, prove shared storage in Milestone 3, and extend features/CLI/platform coverage in Milestone 4.

Build on the validated local common surface and portable memory access to implement the unsigned 16-bit Modular lossless shared-buffer path. Join the cross-codec harness after the JPEG 2000 -> JPEG-LS proof. Preserve specialised JPEG reconstruction through an explicit extension rather than forcing it through the uncompressed-image transcode API.


## Native transcoding work

Implement reversible existing-JPEG ↔ JPEG XL using [TRANSCODING.md](TRANSCODING.md) and the common native format-pair API/CLI. Audit the recorded predecessor limitations in Milestone 2; qualify the in-memory native operation in Milestone 3 and extend profiles in Milestone 4. Preserve the initial J2K → JPEG-LS proof and the Milestone 1 feasibility boundary.

## Product dispositions (POL-05)

Decided 22 September 2026 under contract 0.8.0 §3, which requires this inventory before any subsystem is relocated. Measured at predecessor JXLSwift `57e81cb` with `swift package dump-package`. "Imports" counts files across DICOMKit, CompressionFamily, VoxeliaValidation, DICOMAdapter, RasterOneImage, OneImageViewer-iOS and telerad-dicom-viewer containing a top-level `import <module>`.

POL-05 requires every product to be explicitly **retained** (migrates, stays a public product), **adapted** (migrates with a changed shape — folded into the principal module, renamed, or re-expressed through the common API) or **deferred** (does not migrate for the first stable; stays with the predecessor through the maintenance window). Deferred is not deleted.

| Predecessor product | Files / lines | Imports | Disposition | Successor | Basis |
| --- | --- | --- | --- | --- | --- |
| `JXLSwift` | 122 / 45,117 | 1 | Adapted — renamed | `SwiftJXL` | API-01 |
| `JXLSwiftContract` | 7 / 1,059 | 0 | Adapted — folded in | `SwiftJXL` | The module rename dissolves the name collision that justified a separate product. Contract 0.8.0 §5 forbids two parallel surfaces in one module. |
| `jxl-tool` (exec) | 13 / 2,983 | — | Adapted — renamed | `swiftjxl-cli` | CLI-01 |
| `jxl` (exec) | same target | — | Deferred — dropped | none | A second binary built from the same target for family parity with `j2k`. CLI-01 replaces that scheme with `swiftj2k`/`swiftjls`/`swiftjxl`/`swiftjli` and avoids names that could replace a predecessor binary. |

**Product list after migration:** `SwiftJXL` (library) and `swiftjxl-cli` (executable).

### Decisions recorded with these dispositions

**X1 — reversible JPEG recompression migrates inside `SwiftJXL` with its own gate.** POL-09 requires this repository to preserve and qualify the predecessor's reversible existing-JPEG ↔ JPEG XL capability, restoring the original JPEG bytes from the JXL alone. The implementation lives inside the `JXLSwift` target and moves with it, but it does not inherit the predecessor's qualification. It gets a named Milestone 4 gate: byte-exact reconstruction over a pinned corpus, with the corpus revision and commands recorded. It is not a separate product.

**X2 — Linux support is not claimed at 2.1.0.** The predecessor is Apple-only by manifest and by design. Migrating its source does not make it build or run on Linux, and POL-08 forbids publishing support as verified when its gate has not executed. The common contract's Linux requirement is unchanged and not weakened; the claim is simply not made until the gate passes. Linux ARM64 and x86_64 qualification is a named milestone after the first stable, and README and capability text must not imply it beforehand.

**CLI surface.** Retained and adapted: the CLI-01 verbs `encode`, `decode`, `inspect` (renamed from `Info`), `validate` and `capabilities`, plus `transcode` under POL-09. Deferred to a CLI milestone after the first stable: `Batch`, `BatchEncode`, `BatchDecode`, `Benchmark`, `Compare`, `Convert` and `Completions`. `Version` is absorbed by `--version`.

## Required handover

Update CHANGELOG.md and migration provenance. Provide the exact commands, commits, fixture hashes and outcomes; report tests not run and why, unsupported cases, allocation/copy evidence and performance impact. Map each advertised feature to a test and capability entry. Keep DICOMKit/Voxelia source changes outside this repository task unless the owner separately assigns them.

## Owner-authorised OS 27 and CLI foundation

Before codec migration, the owner raised Apple floors to 27.0 and requested executable help, verbosity and UNIX manuals. This bounded CLI foundation implements help/version/capabilities only; codec commands remain explicitly unavailable. See [CLI.md](CLI.md) and [new evidence](Documentation/Engineering/OS27CLI/README.md). The later codec/CLI milestones still govern real payload operations.
