# SwiftJXL `2.0.0` (`v2.0.0`) Release Qualification Record

**Release Version:** `2.0.0`  
**Git Tag:** `v2.0.0`  
**Release Date:** `6 November 2026`  
**Suite Policy & Common Contract Baseline:** `0.10.0` (`Documentation/COMMON_CONTRACT_SHA256.txt` verified `7/7` byte-identical)  
**Swift Toolchain Baseline:** `swift-tools-version: 6.2` manifest minimum; qualified primary `Swift 6.4` in `Swift 6` language mode with complete concurrency checking  
**Apple Deployment Minimum (`PLAT-01` / `PLAT-02`):** `macOS 26.0`, `iOS / iPadOS 26.0`, `tvOS 26.0`, `watchOS 26.0`, `visionOS 26.0`  
**Linux Baseline (`PLAT-01`):** `Ubuntu 24.04` (`x86_64` and `aarch64`)  
**Migration Predecessor Baseline:** `raster-labs/JXLSwift` at `57e81cb9e2411d1efac435b429a306a031744c1e` (`v1.5.0-rc.1`; API inspection baseline `760697a54dd253da8e8466c3fd09ecf2c2d89aec`)  
**Pre-release Engineering Baseline:** `b9a6f26` (Merge pull request #37 over `065b17d` / frozen runtime `00f03ff288a7c8e0e2b82d2e71ec22622ede71ae`, promoting `2.1.0-dev.2` to `2.0.0`)  
**Licence (`POL-07` / Owner Decision):** `MIT` (`LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`)  

---

## 1. Executive Summary & Shipped Surface

SwiftJXL `2.0.0` (`v2.0.0`) is the first stable release of the standalone native Swift JPEG XL (`ISO/IEC 18181`) library and `swiftjxl-cli` executable for the **Swift Image Compression Suite**:

1. **`SwiftJXL` Library Product**:
   - **Common Owning API (`API-01..14`, `MEM-01..14`)**: `Encoder`, `Decoder`, `Transcoder`, `EncoderConfiguration`, `DecoderConfiguration`, `EncodeOptions`, `DecodeOptions`, `TranscodeOptions`, `ImageDescriptor`, `PlaneDescriptor`, `Image`, `ImageDestination`, `ReadOnlyImageStorage`, `WritableImageStorage`, `StorageWriteLease`, `ImageInfo`, `EncodedImage`, `DecodedImage`, `OperationReport`, `CodecCapabilities`, `ResourceLimits`, and `CodecError`.
   - **Modular Lossless Coding**: Bounded `1..16`-bit unsigned greyscale and RGB with optional straight/premultiplied alpha, grouped and progressive integer streams, RCT, simple palettes, Squeeze transforms, embedded grey/RGB ICC profile preservation on decode, direct caller-owned `ImageDestination` planar/interleaved `UInt8`/`UInt16` decoding (`CopyPolicy.requireSharedStorage`), and `8..16`-bit integer Modular encoding across esfuerzos/learners with bounded resource admission and cooperative cancellation.
   - **VarDCT Lossy Coding & Numerical Profiles**: Bounded single-frame sRGB `8..16`-bit greyscale/RGB with optional straight alpha, multiple DC/AC groups, transform strategies through `64×64` (`.fixedDCT8`, `.singleCell`, `.hierarchical`), small transforms, AFV, Gaborish, and EPF restoration, plus explicit `.libjxl012ARMInteger` reference numerical conventions.
   - **Native Reversible JPEG ↔ JPEG XL Transcoding (`POL-09`)**: Autonomous in-memory `Transcoder` preserving and restoring original JPEG bitstreams (`Fidelity.originalBitstream`) via quantised DCT8 coefficients, `jbrd` reconstruction boxes, RGB/greyscale ICC profiles, and bounded native Brotli metadata boxes without pixel round-tripping or original-file fallback.
   - **Containers, Animation & Native JPEG Pixel Input**: Raw codestream and ISO box (`PixelContainerFormat.codestream` / `.iso`) framing, independent full-canvas animation encoding/decoding (`encodeAnimation`, `decodeAll`, `decodeFrame(at:)`, `inspectFrames`, `countFrames`) with exact rational tick clocks, and bounded native `8/12`-bit Huffman DCT and `2..16`-bit `SOF3` lossless JPEG pixel decoding.
2. **`swiftjxl-cli` Executable Product & UNIX Manual (`ManPages/swiftjxl-cli.1`)**:
   - Commands: `encode`, `decode`, `transcode`, `inspect`, `validate`, `capabilities`, `help`, and `version` over JPEG XL codestreams/ISO containers, 2D unsigned 16-bit `NRRD`, `8..16`-bit binary `PGM`/`PPM`/`PAM` (`pnm` and `pnm-srgb`), and `jpeg`/`jpeg-srgb`, with atomic sibling output transactions, structured JSON telemetry, five diagnostic verbosity levels (`CLI-08`), and staged binary/manual installation via `Scripts/install-cli.sh` (`CLI-09`).

---

## 2. Verified Release Preconditions & Qualification Evidence

| Gate | Verification / Evidence | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.10.0`) |
| **Linux ASan/LSan & TSan matrix (`M4-LINUX-SANITIZERS`)** | Native Linux `x86_64` and `aarch64`, Swift `6.2.4` and `6.4.2`, ASan+LSan and TSan (`8` cells, `374` declarations / `2,059` cases per cell, `0` failures/skips) | **PASSED** |
| **Native `macOS 26.0` minimum floor (`M4-MACOS-MINIMUM`)** | Isolated `macOS 26.0` (`25A354`, ARM64) runtime (`368` declarations / `2,053` cases, `432` profiles, `45,826` reciprocal vectors, `98` CLI checks) | **PASSED** |
| **Native Intel `macOS` (`M4-MACOS-INTEL`)** | Native `x86_64` macOS execution (`368` declarations / `2,053` cases, `10` CLI groups / `1,059` checks) | **PASSED** |
| **Apple Simulator suites (`M4-IOS-SANITIZERS`, `M4-OTHER-SIMULATORS`)** | `iOS 26.0` Simulator (`Debug`, `ASan`, `TSan`) and `tvOS 26.0`, `watchOS 26.0`, `visionOS 26.0` Simulator (`Release`) (`362` declarations / `1,960` cases per bundle + Watch resource profile probe) | **PASSED** |
| **Complete CLI TSan matrix (`M4-CLI-TSAN`)** | All `10` CLI process groups (`1,059` checks) under ThreadSanitizer with pinned NRRD and scalar high-precision `libjxl` / `libjpeg` oracles | **PASSED** |
| **Clean versioned & HTTPS consumers (`M5-VERSIONED-CONSUMER`, `M5-URL-CONSUMER`)** | `Scripts/validate-release-consumer.py` Debug and Release builds/runs and `Examples/ContractConsumer` verification | **PASSED** |
| **Documentation, provenance & derived SBOMs (`M5-DOCS-EXAMPLES`, `M5-LICENCE-PROVENANCE`, `RELEASE-SBOM-SCHEMA`)** | `Scripts/check-release-docs.py`, `Scripts/audit-release-provenance.py` (`120` production sources, `995` fixtures), and schema/SHACL-validated derived SPDX `3.0.1` & CycloneDX `1.7` SBOMs | **PASSED** |
| **Private vulnerability reporting (`RELEASE-SECURITY-POLICY`)** | Confirmed enabled on `raster-labs/SwiftJXL` (`gh api repos/raster-labs/SwiftJXL/private-vulnerability-reporting`) and documented in `SECURITY.md` | **PASSED** |

See [Documentation/Engineering/Release/QUALIFICATION.md](Engineering/Release/QUALIFICATION.md) and [Documentation/Engineering/Release/README.md](Engineering/Release/README.md) for the complete retained evidence archives.

---

## 3. Unexecuted and Deferred Gates (Disclosed Explicitly per `POL-08`)

Per suite policy (`POL-08` — *"A missing required environment is an unexecuted gate, not a pass"*):

1. **Physical Apple device execution (`M4-PHYSICAL-DEVICES` — `iPhone`, `iPad`, `Apple Watch`, `Apple TV`, `Apple Vision Pro`)**: **Unexecuted** (excluded from the library qualification assignment; all 10 Apple OS 26 device/simulator SDK targets compile and all OS 26 simulator and native `macOS 26.0` / Intel runtime suites pass).
2. **DICOMKit & downstream application cutover**: **Deferred** to separate consumer-repository tasks.
3. **Universal runtime/allocator/stack workspace totals**: Scoped source bounds and operation admission are enforced; universal allocator/runtime/stack counters remain `nil` (`unknown`) on public `OperationReport`.
