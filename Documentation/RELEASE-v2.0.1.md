# SwiftJXL `2.0.1` (`v2.0.1`) Release Qualification Record

**Release Version:** `2.0.1`  
**Git Tag:** `v2.0.1`  
**Release Date:** `11 November 2026`  
**Suite Policy & Common Contract Baseline:** `0.10.0` (`Documentation/COMMON_CONTRACT_SHA256.txt` verified `7/7` byte-identical)  
**Swift Toolchain Baseline:** `swift-tools-version: 6.2` manifest minimum; qualified primary `Swift 6.4` in `Swift 6` language mode with complete concurrency checking  
**Apple Deployment Minimum (`PLAT-01` / `PLAT-02`):** `macOS 26.0`, `iOS / iPadOS 26.0`, `tvOS 26.0`, `watchOS 26.0`, `visionOS 26.0`  
**Linux Baseline (`PLAT-01`):** `Ubuntu 24.04` (`x86_64` and `aarch64`)  
**Migration Predecessor Baseline:** `raster-labs/JXLSwift` at `57e81cb9e2411d1efac435b429a306a031744c1e` (`v1.5.0-rc.1`; API inspection baseline `760697a54dd253da8e8466c3fd09ecf2c2d89aec`)  
**Pre-release Engineering Baseline:** `b27fe39` (Merge pull request #40 over `8dd800d` / `e3adb2d`, promoting `2.0.0` to `2.0.1` on preserved branch `codex/release-2.0.1`)  
**Licence (`POL-07` / Owner Decision):** `MIT` (`LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`)  

---

## 1. Executive Summary & Shipped Surface

SwiftJXL `2.0.1` (`v2.0.1`) is a patch release in the `2.0.x` stable series of the standalone native Swift JPEG XL (`ISO/IEC 18181`) library and `swiftjxl-cli` executable for the **Swift Image Compression Suite**, keeping earlier tag `v2.0.0` immutable:

1. **100% Clean-Room `ISO/IEC 18181` & `RFC 7932` Swift Implementation**:
   - Replaces all 37 third-party-adapted source files in `Sources/SwiftJXLCore/` with clean-room, first-principles Swift implementations derived directly from `IETF RFC 7932`, `ISO/IEC 18181-1:2024`, `ISO/IEC 18181-2:2024`, `ITU-T Rec. T.81`, and in-house spatial VarDCT encoder analysis across:
     - **Phase A (`40680e0`)**: Brotli decompressor (`BrotliContext`, `BrotliPrefixCode`, `BrotliStaticDictionary`, `BrotliDecoder`).
     - **Phase B (`eb3fd69`)**: Entropy token stream reader, compressed ICC stream, and Modular pipeline (`TokenStreamReader`, `ICCStream`, `PixelFrameHeader`, `ModularFrameDecoder`, `ModularImage`, `InverseTransforms`, `SpecRCT`, `SpecSqueeze`, `LibjxlPredictor`).
     - **Phase C (`f95b44f`)**: VarDCT decode and reconstruction pipeline (`VarDCTFrameEnvelope`, `VarDCTStrategyMap`, `VarDCTQuantWeights`, `VarDCTEntropy`, `VarDCTCoefficients`, `ScaledDCT`, `VarDCTSmallTransforms`, `VarDCTAFV`, `VarDCTNumerics`, `VarDCTReconstruction`, `Gaborish`, `EdgePreservingFilter`, `DefaultOpsin`).
     - **Phase D (`ee8b0e9`)**: In-house VarDCT encoder analysis and frame emission (`VarDCTEncoderPreparation`, `VarDCTSmallAnalysis`, `VarDCTLargeAnalysis`, `VarDCTHierarchicalAnalysis`, `VarDCTFrameWriter`, `VarDCTPixelEncoder`).
     - **Phase E (`3269d6d`)**: Lossless JPEG reconstruction and native `jbrd` transcoder bridge (`JPEGCoefficientDecoder`, `JPEGReconstructionWriter`, `JPEGBridgeCoefficients`, `JPEGBridgeEntropy`, `JPEGBridgeFrameWriter`, `JPEGBridgeFrameReader`).
     - **Phase F (`28b7a1f`)**: Single-licence production source provenance enforcement (`120/120` files in `Sources/`) and removal of third-party source notices from production targets.
2. **Modular, VarDCT, JPEG Transcoding & CLI Hot-Path Optimisations (`e3adb2d`)**:
   - **Bitstream & Entropy**: 4-byte `BitReader` refill / `BitWriter` flush, `O(1)` LSB-first `PrefixCodeTable` LUT, flat multi-cluster `AliasTable` slots, and fast multi-context ANS readers/writers.
   - **Modular**: Specialised single-leaf and multi-leaf WP/no-WP ANS decode cores, `BorrowedScalarPlane` row pointers, and allocation-free residual/WP encoding loops.
   - **VarDCT**: Precomputed EPF mirror tables and stage-2 shared patches, cached `VarDCTSmallTransforms` and static `lowFrequencies` cosine tables, specialised 4/8/16/32/64-point `ScaledDCT` 1D passes, intra-tile horizontal 1D DCT reuse, and exact branch-and-bound pruning in `VarDCTHierarchicalAnalysis`.
   - **Native JPEG & CLI**: 8-bit `JPEGHuffmanTable` LUT without byte over-read, inlined `.raw4` `BridgePrefix` encoding, raw-pointer coefficient/zigzag loops, `[UInt8]`-backed `JPEGOutput`, and 64 KiB batched NRRD/PNM row writes.
3. **MIT Relicensing (`c815ff7` / `b27fe39`)**:
   - Relicenses SwiftJXL in-house source, tests, examples, tooling scripts, and documentation from `Apache-2.0` to `MIT` (`Copyright (c) 2026 Raster Images Private Limited`) by explicit owner decision under `Documentation/SUITE_POLICY.md` Document Precedence Rule 1, while keeping the seven shared contract documents in `Documentation/` byte-identical at `0.10.0`.
   - Enforces `SOURCE_LICENCES = {"MIT"}` across all `120` production source files in `Scripts/audit-release-provenance.py`, while preserving pinned test fixtures and historical engineering evidence archives byte-for-byte.
4. **Unchanged Public Surface (`SwiftJXL` & `swiftjxl-cli`)**:
   - Retains the complete `2.0.0` public API (`Encoder`, `Decoder`, `Transcoder`, `ImageDescriptor`, `Image`, `ImageDestination`, `ReadOnlyImageStorage`, `WritableImageStorage`, `StorageWriteLease`, `ImageInfo`, `EncodedImage`, `DecodedImage`, `OperationReport`, `CodecCapabilities`, `ResourceLimits`, `CodecError`) and `swiftjxl-cli` command surface (`encode`, `decode`, `transcode`, `inspect`, `validate`, `capabilities`, `help`, `version`), promoted to version `2.0.1` (`v2.0.1`).

---

## 2. Verified Release Preconditions & Qualification Evidence

| Gate | Verification / Evidence | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.10.0`) |
| **Source & fixture provenance (`M5-LICENCE-PROVENANCE`)** | `python3 Scripts/audit-release-provenance.py` (`120` MIT production sources, `995` fixtures) and `python3 Scripts/Tests/test_release_provenance.py` (`12/12` checks) | **PASSED** |
| **Documentation & synchronised example (`M5-DOCS-EXAMPLES`)** | `python3 Scripts/check-release-docs.py` and `Examples/ContractConsumer` execution | **PASSED** |
| **Release checklist & validator regressions** | `python3 Scripts/check-release-gates.py` (`checklistValid: true`, `2.0.1`) and `test-release-consumer.py` (`8`), `test-release-gates.py` (`17`), `test-release-sbom.py` (`4`), `test-derived-release-sbom.py` (`6`) | **PASSED** |
| **Clean versioned consumer rehearsal (`M5-VERSIONED-CONSUMER`)** | `python3 Scripts/validate-release-consumer.py` Debug and Release builds/runs on `2.0.1` | **PASSED** |
| **Hosted CI matrix (`contract.yml`, `release-preparation.yml`, `milestone5-linux-sanitizers.yml`, `milestone5-native-macos.yml`)** | Linux `x86_64`/`aarch64` Swift `6.4` debug/release/ASan/TSan, macOS 26 debug/ASan/TSan, Apple OS 26 SDK builds, native Intel macOS, pinned `libjxl 0.12.0` interoperability, and release-preparation workflows | **PASSED** |
| **Private vulnerability reporting (`RELEASE-SECURITY-POLICY`)** | Confirmed enabled on `raster-labs/SwiftJXL` (`gh api repos/raster-labs/SwiftJXL/private-vulnerability-reporting`) and documented in `SECURITY.md` | **PASSED** |

See [Documentation/RELEASE-v2.0.0.md](RELEASE-v2.0.0.md), [Documentation/Engineering/Release/QUALIFICATION.md](Engineering/Release/QUALIFICATION.md), and [Documentation/Engineering/Release/README.md](Engineering/Release/README.md) for the retained Milestone 5 qualification archives.

---

## 3. Unexecuted and Deferred Gates (Disclosed Explicitly per `POL-08`)

Per suite policy (`POL-08` — *"A missing required environment is an unexecuted gate, not a pass"*):

1. **Physical Apple device execution (`M4-PHYSICAL-DEVICES` — `iPhone`, `iPad`, `Apple Watch`, `Apple TV`, `Apple Vision Pro`)**: **Unexecuted** (excluded from the library qualification assignment; all 10 Apple OS 26 device/simulator SDK targets compile and hosted macOS 26 / Intel / Linux runtime suites pass).
2. **DICOMKit & downstream application cutover**: **Deferred** to separate consumer-repository tasks.
3. **Universal runtime/allocator/stack workspace totals**: Scoped source bounds and operation admission are enforced; universal allocator/runtime/stack counters remain `nil` (`unknown`) on public `OperationReport`.
