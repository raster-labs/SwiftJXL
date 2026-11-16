# SwiftJXL `2.1.1` (`v2.1.1`) Release Qualification Record

**Release Version:** `2.1.1`  
**Git Tag:** `v2.1.1`  
**Release Date:** `16 November 2026`  
**Suite Policy & Common Contract Baseline:** `0.10.0` (`Documentation/COMMON_CONTRACT_SHA256.txt` verified `7/7` byte-identical)  
**Swift Toolchain Baseline:** `swift-tools-version: 6.2` manifest minimum; qualified primary `Swift 6.4` (and `Xcode 26.6` / `Swift 6.3.3` macOS/Apple OS 26 SDK compatibility) in `Swift 6` language mode with complete concurrency checking  
**Apple Deployment Minimum (`PLAT-01` / `PLAT-02`):** `macOS 26.0`, `iOS / iPadOS 26.0`, `tvOS 26.0`, `watchOS 26.0`, `visionOS 26.0`  
**Linux Baseline (`PLAT-01`):** `Ubuntu 24.04` (`x86_64` and `aarch64`)  
**Preceding Release Baseline:** `89065d36364c138c4d34c1c6569ab822532fbe15` (`v2.1.0`)  
**Licence (`POL-07` / Owner Decision):** `MIT` (`LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`)  

---

## 1. Executive Summary & Scope (`2.1.1`)

SwiftJXL `2.1.1` (`v2.1.1`) is a toolchain and qualification patch release over `v2.1.0` (`89065d3`), keeping published tag `v2.1.0` immutable:

1. **`Xcode 26.6` (`Swift 6.3.3`) Debug, Sanitizer & Apple OS `26.0` SDK Compilation**:
   - Decomposes chained `SIMD4<Double> * Double` and `Double` sum expressions in `Sources/SwiftJXLCore/VarDCT/ScaledDCT.swift` and `Sources/SwiftJXLCore/VarDCT/VarDCTAFV.swift` into explicitly typed intermediate values with identical IEEE-754 left-to-right associativity and zero bitstream change.
2. **Independent Brotli Dictionary Verification**:
   - Updates `Scripts/validate-brotli-decoder.py` to decode `BrotliStaticDictionary.base64Chunks` when verifying the embedded 122,784-byte RFC 7932 static dictionary against `libbrotlicommon`.
3. **Version & CLI Promotion (`2.1.1` / `v2.1.1`)**:
   - Promotes `VERSION`, `swiftjxl-cli` (`Sources/SwiftJXLCLI/main.swift`), `ManPages/swiftjxl-cli.1`, and `Documentation/Engineering/Release/release-gates.json` to `2.1.1`.

---

## 2. Verified Release Preconditions & Qualification Evidence

| Gate | Verification / Evidence | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.10.0`) |
| **Source & fixture provenance (`M5-LICENCE-PROVENANCE`)** | `python3 Scripts/audit-release-provenance.py` and `python3 Scripts/Tests/test_release_provenance.py` | **PASSED** |
| **Documentation & synchronised example (`M5-DOCS-EXAMPLES`)** | `python3 Scripts/check-release-docs.py` and `Examples/ContractConsumer` execution | **PASSED** |
| **Release checklist & validator regressions** | `python3 Scripts/check-release-gates.py` (`checklistValid: true`, `2.1.1`) and `test-release-consumer.py`, `test-release-gates.py`, `test-release-sbom.py`, `test-derived-release-sbom.py` | **PASSED** |
| **Apple OS `26.0` SDK cross-builds** | `python3 Scripts/validate-apple-sdks.py --build-system native` | **PASSED** (`10/10` Apple OS `26.0` device/simulator targets) |
| **Independent Brotli framing & dictionary verification** | `python3 Scripts/validate-brotli-framing.py` & `python3 Scripts/validate-brotli-decoder.py` | **PASSED** (`29` framing checks; `41` streams, `5,082` transforms) |
| **Debug & Release test suites + `libjxl 0.12.0` oracle** | `swift build` & `SWIFTJXL_ORACLE_BIN=/opt/homebrew/bin swift test -c release` & `python3 Scripts/test-cli.py` | **PASSED** |
| **Clean versioned consumer rehearsal (`M5-VERSIONED-CONSUMER`)** | `python3 Scripts/validate-release-consumer.py` Debug and Release builds/runs on `2.1.1` | **PASSED** |

See [Documentation/RELEASE-v2.1.0.md](RELEASE-v2.1.0.md), [Documentation/RELEASE-v2.0.1.md](RELEASE-v2.0.1.md), and [Documentation/RELEASE-v2.0.0.md](RELEASE-v2.0.0.md) for retained release records.

---

## 3. Unexecuted and Deferred Gates (Disclosed Explicitly per `POL-08`)

1. **Physical Apple device execution (`M4-PHYSICAL-DEVICES` — `iPhone`, `iPad`, `Apple Watch`, `Apple TV`, `Apple Vision Pro`)**: **Unexecuted** (excluded from the library qualification assignment).
2. **Universal runtime/allocator/stack workspace totals**: Scoped source bounds and operation admission are enforced; universal allocator/runtime/stack counters remain `nil` (`unknown`) on public `OperationReport`.
