# SwiftJXL `2.1.0` (`v2.1.0`) Release Qualification Record

**Release Version:** `2.1.0`  
**Git Tag:** `v2.1.0`  
**Release Date:** `16 November 2026`  
**Suite Policy & Common Contract Baseline:** `0.10.0` (`Documentation/COMMON_CONTRACT_SHA256.txt` verified `7/7` byte-identical)  
**Swift Toolchain Baseline:** `swift-tools-version: 6.2` manifest minimum; qualified primary `Swift 6.4` in `Swift 6` language mode with complete concurrency checking  
**Apple Deployment Minimum (`PLAT-01` / `PLAT-02`):** `macOS 26.0`, `iOS / iPadOS 26.0`, `tvOS 26.0`, `watchOS 26.0`, `visionOS 26.0`  
**Linux Baseline (`PLAT-01`):** `Ubuntu 24.04` (`x86_64` and `aarch64`)  
**Migration Predecessor Baseline:** `raster-labs/JXLSwift` at `57e81cb9e2411d1efac435b429a306a031744c1e` (`v1.5.0-rc.1`; API inspection baseline `760697a54dd253da8e8466c3fd09ecf2c2d89aec`)  
**Pre-release Engineering Baseline:** `307b7c9` over `v2.0.1` (`23ff41e`)  
**Licence (`POL-07` / Owner Decision):** `MIT` (`LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`)  

---

## 1. Executive Summary & Shipped Surface

SwiftJXL `2.1.0` (`v2.1.0`) is a minor feature and performance release in the `2.x` stable series of the standalone native Swift JPEG XL (`ISO/IEC 18181`) library and `swiftjxl-cli` executable for the **Swift Image Compression Suite**, keeping earlier tags `v2.0.0` and `v2.0.1` immutable:

1. **SIMD / Accelerate (`vDSP`) & Bounded Multi-Worker Codec Acceleration (`daffc2c`, `b52b9d2`, `307b7c9`)**:
   - **Modular & `jbrd` Acceleration**: Vectorised residual/RCT/Squeeze and `jbrd` JPEG coefficient reconstruction hot loops with bounded parallel group scheduling under caller `ResourceLimits`.
   - **Parallel VarDCT Single-Cell & Hierarchical Analysis**: Allocation-free per-worker transform scratch, explicit parallel AC histogram workspace budget accounting, truthful `OperationReport` worker tracking, and deterministic `1T == 8T` bitstream parity across both single-cell and large-grid frames.
2. **ThreadSanitizer & Cancellation Hardening (`6dadd52`)**:
   - Eliminates Brotli static dictionary TSan stack-frame overflow, enforces cooperative cancellation checkpoints in the native JPEG bridge transcoder, and hardens contended suite deadlines.
3. **Preserved Clean-Room MIT Provenance & Public API**:
   - Preserves 100% single-licence Raster Images `MIT` production source provenance across `Sources/`, byte-identical `0.10.0` shared contract manifests, and full `2.0.x` source compatibility across `SwiftJXL` and `swiftjxl-cli`.

---

## 2. Verified Release Preconditions & Qualification Evidence

| Gate | Verification / Evidence | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.10.0`) |
| **Source & fixture provenance (`M5-LICENCE-PROVENANCE`)** | `python3 Scripts/audit-release-provenance.py` and `python3 Scripts/Tests/test_release_provenance.py` | **PASSED** |
| **Documentation & synchronised example (`M5-DOCS-EXAMPLES`)** | `python3 Scripts/check-release-docs.py` and `Examples/ContractConsumer` execution | **PASSED** |
| **Release checklist & validator regressions** | `python3 Scripts/check-release-gates.py` (`checklistValid: true`, `2.1.0`) and `test-release-consumer.py`, `test-release-gates.py`, `test-release-sbom.py`, `test-derived-release-sbom.py` | **PASSED** |
| **Release test suite & `libjxl 0.12.0` oracle interoperability** | `SWIFTJXL_ORACLE_BIN=/opt/homebrew/bin swift test -c release` and `python3 Scripts/test-cli.py` | **PASSED** |
| **Clean versioned consumer rehearsal (`M5-VERSIONED-CONSUMER`)** | `python3 Scripts/validate-release-consumer.py` Debug and Release builds/runs on `2.1.0` | **PASSED** |
| **Private vulnerability reporting (`RELEASE-SECURITY-POLICY`)** | Confirmed enabled on `raster-labs/SwiftJXL` and documented in `SECURITY.md` | **PASSED** |

See [Documentation/RELEASE-v2.0.1.md](RELEASE-v2.0.1.md), [Documentation/RELEASE-v2.0.0.md](RELEASE-v2.0.0.md), [Documentation/Engineering/Release/QUALIFICATION.md](Engineering/Release/QUALIFICATION.md), and [Documentation/Engineering/Release/README.md](Engineering/Release/README.md) for the retained Milestone 5 qualification archives.

---

## 3. Unexecuted and Deferred Gates (Disclosed Explicitly per `POL-08`)

Per suite policy (`POL-08` — *"A missing required environment is an unexecuted gate, not a pass"*):

1. **Physical Apple device execution (`M4-PHYSICAL-DEVICES` — `iPhone`, `iPad`, `Apple Watch`, `Apple TV`, `Apple Vision Pro`)**: **Unexecuted** (excluded from the library qualification assignment).
2. **Universal runtime/allocator/stack workspace totals**: Scoped source bounds and operation admission are enforced; universal allocator/runtime/stack counters remain `nil` (`unknown`) on public `OperationReport`.
