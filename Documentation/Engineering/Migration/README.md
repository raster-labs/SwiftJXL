# SwiftJXL migration — execution record

Started 7 October 2026 at the owner's request to complete the SwiftJXL migration. The first change repairs the verification foundation; it does not claim codec migration or production cutover. JXLSwift remains the supported production dependency until successor qualification and a separately scoped consumer cutover.

## Source and contract

- Successor baseline: `raster-labs/SwiftJXL` at `24ff6b3d1d3bf52214eb2ce3cfa971345a29da5a`; clean checkout, branch `codex/swiftjxl-codec-migration`.
- Selected predecessor: `Raster-Lab/JXLSwift` at `57e81cb9e2411d1efac435b429a306a031744c1e`, the exact commit of `v1.5.0-rc.1`. This includes the contract storage integration absent from the older `760697a` documentation snapshot. The candidate is not a stable release; no predecessor tag or source is changed.
- Common contract distribution: 0.10.0. The seven files and `COMMON_CONTRACT_SHA256.txt` are unchanged. Several constituent documents retain earlier version headings; the suite policy records cumulative precedence.
- Active requirements: Swift tools 6.2 minimum, Swift 6 language mode, Swift 6.4 qualification, Apple deployment floors 26.0, executable `swiftjxl-cli`. Older repository-specific OS 27 and compiler-floor statements are superseded by the common contract.

## Prerequisite failures and corrections

The original [CI run](https://github.com/raster-labs/SwiftJXL/actions/runs/35800215617) had no executed steps because of an account billing lock. Attempt 2 on 7 October executed jobs: macOS, both Swift 6.4 Linux architectures and document hashes passed; both Swift 6.2 Linux jobs and the independent consumer failed. The billing lock is therefore no longer the observed blocker. Codec relocation still requires a fully passing successor workflow.

Swift 6.2 Linux traps in `Synchronization.Mutex.withLockIfAvailable` when a callback attempts to acquire its already-held mutex. `OwnedImageStorage` now admits one operation through an atomic flag before entering the mutex. Reentrant and competing access returns `storageUnavailable`; the flag is released after the mutex on success or throw. The array, borrow scope, allocation identity and sealing path are unchanged. The existing regression reproduced the CI crash; added checks cover reentrant abort/reservation and throwing-borrow recovery. No unchecked Sendable annotation or raw-pointer owner was introduced. The extra atomic operations have not yet received a controlled performance qualification.

The isolated consumer checkout is named `package`, so SwiftPM identifies its dependency as `package`, regardless of its declared product name. CI now uses that identity and runs the public sample/ownership consumer instead of merely importing the module. Local and example consumers declare the actual 6.2/26.0 minima.

Contract CLI-01 requires `swiftjxl-cli` to avoid case-only collisions with `SwiftJXL` on some Swift Build configurations. The product, executable help/version, installer, manual and tests now use that name. A clean baseline build did pass on this local Swift 6.4 host; that result is not evidence that the documented collision affects every compiler. CLI platform reporting is corrected to 26.0. macOS CI now executes the CLI/manual installation checks.

## Predecessor inventory and reconciliation

[The inventory](predecessor-inventory.json) records every tracked source/test path, SHA-256, byte size and textual line count at the selected predecessor commit. No implementation, test or fixture from that inventory is copied by this preflight.

| Product or material | Observed files / lines | Disposition |
| --- | --- | --- |
| JXLSwift core | 122 / 45,117 | Adapt algorithms behind the existing SwiftJXL common surface in milestones 2–4 |
| JXLSwiftContract | 7 / 1,059 | Fold useful codec seams into SwiftJXL; retain the successor's canonical descriptors, ownership and options, with no parallel public contract module |
| JXLTool | 13 / 2,983 | Adapt qualified verbs to `swiftjxl-cli`; defer the advanced commands listed in IMPLEMENTATION.md |
| JXLPerfC | 2 / 71 | Test/development-only optional primitives; audit equivalence and provenance before any import; not a core runtime dependency |
| JXLSwiftTests | 7 / 28,322 | Audit and retain useful regressions and independent-oracle assertions in the relevant milestone |
| Contract tests | 1 / 273 | Adapt caller-storage, byte-identity and lifetime regressions to the successor surface |

In-house predecessor material is MIT at the pinned commit; owner-authorised Apache-2.0 relocation follows POL-07 and records each actual destination path when it moves. `Tests/Fixtures/conformance/CREDITS.md` identifies two third-party JPEG XL conformance vectors as BSD-3-Clause. Preserve and independently verify their notices/upstream provenance before redistribution; a root licence is not sufficient. Their bytes are inventoried, not imported here.

The predecessor contract adapter is evidence, not a drop-in complete implementation: it needs review of meaningful precision, metadata preservation, deadline/workspace enforcement, error mapping and executor/cancellation policy against the successor contract. The public reconstruction path separately needs byte-exact JPEG validation and unsupported-profile rejection.

## Executed local checks

Host: Apple arm64, Xcode 27.0 / Apple Swift 6.4 `swiftlang-6.4.0.34.1`; this host does not establish native Linux, Intel, minimum-OS or physical-device qualification.

```sh
bash Scripts/validate.sh --checks debug,release,consumer,asan,tsan \
  --jobs 2 --disable-package-sandbox --output ../evidence/preflight-local
```

Exit 0. Clean/incremental debug and release builds, the public independent consumer and separate AddressSanitizer/ThreadSanitizer runs passed. Each configuration executed 32 test declarations / 33 argument cases, zero failures or skips. [Report with exact commands and tested-source hashes](Evidence/report.json); [debug](Evidence/debug-tests.xml), [release](Evidence/release-tests.xml), [ASan](Evidence/asan-tests.xml), [TSan](Evidence/tsan-tests.xml). The source report precedes later documentation/workflow-only edits; its hashes identify the actual tested implementation.

The CLI check `python3 Scripts/test-cli.py --binary .build/out/Products/Debug/swiftjxl-cli --output ../evidence/cli-preflight-final` exited 0 with 109 process checks, including staged install/update, manual lint/rendering, closed pipes and unavailable operations without I/O. [CLI report](Evidence/cli-report.json). An initial invocation used the wrong build-output path; a subsequent manual lint check exposed a line exceeding 80 columns, which was corrected before the final pass.

Selected predecessor baseline, executed from the unmodified pinned checkout:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
xcrun swift test --disable-sandbox --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" \
  --build-system swiftbuild --jobs 2 -c release \
  --filter 'JXLSwiftContractTests|SpecModular|PublicAPILosslessJPEGTests'
```

Exit 0: 35 XCTest cases and 14 Swift Testing declarations (18 argument cases), zero selected failures/skips. The empty XCTest wrapper for the Swift Testing target is not counted as coverage. [Exact baseline output](Evidence/predecessor-selected-tests.log). This is a selected baseline, not the complete predecessor regression suite. Independent tools on this host report `cjxl`/`djxl` 0.12.0; future oracle evidence must pin binaries and fixture generation. The resolved CLI-only ArgumentParser revision is `6a52f3251125d74daf04fcbd5e6f08a75d074382` (1.8.2); it is not added to SwiftJXL.

The subsequent complete release test invocation used the same command without the filter and with `--skip-build`. It exited 0: 717 XCTest cases (694 passed, 23 skipped, zero failures), plus 14 Swift Testing declarations / 18 argument cases. [Full baseline summary and every skip](Evidence/predecessor-full-summary.json). Skips include missing external fixtures, disabled diagnostics and unsupported parser patterns. A diagnostic-only VarDCT distance-10 sweep also reports a decode failure without failing its test. These are unresolved coverage/behaviour findings; the process exit is not full feature qualification.

A focused external public consumer demonstrates a real precision defect in the pinned predecessor contract adapter: an image declared with 12 meaningful bits produces an inspected codestream declaring 16 bits. The internal `encodeGrayscale16` supports an explicit precision, but `encodeGreyscale16` omits that argument and uses the 16-bit default. [Probe source](Evidence/precision-probe.swift) and [result](Evidence/precision-probe.json). The first probe raised its failed expectation at top level (exit 133); the final probe reports structured evidence and exits 1. Neither changes predecessor code. Migration must forward and validate declared precision and test it independently, rather than preserve this defect or infer precision from sample maxima.

## Contract adapter audit — 7 October continuation

At this earlier audit checkpoint, run 35800215617 attempt 2 had failed and publication awaited owner approval after automatic approval review rejected the push. The owner subsequently authorised proceeding. Commit `759940492a68bcd7a49b09d7c7b2d0375b97b0df` was published in [draft PR #14](https://github.com/raster-labs/SwiftJXL/pull/14), and [run 37616664498](https://github.com/raster-labs/SwiftJXL/actions/runs/37616664498) passed all seven jobs. This satisfied the CI prerequisite before the first codec source was copied.

A new external consumer exercised six small, deterministic policy cases against the unmodified pinned predecessor. All six failed their contract expectations. [Source](Evidence/policy-probe.swift) and [results with source/binary hashes](Evidence/policy-probe.json).

| Requirement | Executed observation | Required successor acceptance |
| --- | --- | --- |
| Encoding workspace ceiling (TEST-06) | Encoding succeeds with one byte of allowed workspace despite an Int32 plane | Reject before allocating workspace beyond the declared ceiling |
| Encoding aggregate admission (TEST-06) | Encoding an existing 16-byte image succeeds with a one-byte total budget | Account for retained samples, compressed bytes and workspace before starting |
| Required acceleration (API-07) | Encoder and decoder both succeed with unavailable acceleration required | Return `backendUnavailable`, without silent scalar fallback |
| Decoding workspace ceiling (TEST-06) | Decoding succeeds with one byte of allowed workspace | Preflight and enforce bounded algorithm workspace |
| Required metadata preservation (API-07) | An image with required `interpretation` metadata encodes and decodes without it | Preserve representable required metadata or reject before publication |

These findings concern `JXLSwiftContract.JXLContractCodec`, not a claim about every legacy API path. The successor must retain its existing operation preflight and extend it through real codec execution; importing the predecessor adapter wholesale would regress those policies. The probe does not allocate large images or exercise unbounded inputs. Its first compile needed an explicit main-actor annotation for its serial results collector. The corrected source compiled and linked, but debug-symbol generation was denied by the local environment. Running that linked executable separately returned the six structured failures and exit 1; this is behavioural evidence, not a passing build gate.

## Outstanding completion gates

1. Foundation CI passed. Complete scalar migration qualification, including review of the internal algorithms, broader profiles and the separate common API integration below.
2. Complete common API integration and direct caller-storage encode/decode, with precision, stride, lifecycle, resource, cancellation and measured copy/allocation evidence. No full final-frame adapter copy.
3. Qualify all required retained modes, colour/alpha/ICC, frames and native JPEG reconstruction; explicitly account for deferred features. Implement and test the supported CLI verbs.
4. Execute required parser mutation/fuzz campaigns, regressions, independent interoperability in both directions, sanitizers, controlled release performance and platform gates. Existing synthetic tests are not codec evidence.
5. Verify clean versioned consumption, SBOM/provenance, examples, migration documentation and release readiness. No stable tag or production cutover follows from this preflight.

The programme history sequences SwiftJLS and SwiftJLI before SwiftJXL; their completed migration evidence is not established by this repository's checks. Other repository releases, downstream application edits and predecessor archival remain separate tasks.

## First internal scalar migration — 8 October continuation

After the foundation CI prerequisite passed, 39 predecessor algorithm files were copied and adapted into `Sources/SwiftJXLCore`, together with a rewritten scalar scheduling helper and a decoder adapted from the predecessor's single-section Modular flow. [Path-level provenance and modifications](relocated-sources.json) records original and destination hashes. The predecessor checkout remains unmodified. The new target is currently a dependency of the core tests only: it is not a second exported library and is not yet connected to the public `Encoder`/`Decoder`. Existing public capabilities correctly remain unavailable.

The first tested profile is unsigned greyscale with 9, 10, 12, 14 or 16 meaningful bits, lossless Modular, a single frame and group, no extra channels, ICC, transforms or ancillary metadata. The encoder admission cap for this initial profile is 512 pixels per dimension. Other functions retained within the imported algorithm files have not inherited predecessor qualification. Public caller limits, direct sample storage, exact copy/allocation accounting, colour interpretation and the remaining features are separate outstanding integration work.

The reference encoder automatically emits a level-10 container for high precision despite `--container=0`. The first 14-/16-bit oracle cases exposed that packaging assumption, rather than a sample mismatch. The adapted container parser now handles complete and partial codestream boxes with checked extended sizes, nonzero `Data.startIndex`, duplicate/mixed-box rejection and complete partial sequence validation. Metadata boxes outside this restricted internal profile are rejected rather than silently discarded.

Other changes remove environment-controlled payload logging; replace the predecessor's integer-encoded pointer/GCD helper with deterministic scalar execution; check entropy terminal states and incomplete LZ77 runs; bound nested entropy parsing and tree size; reject unimplemented extensions; validate input samples and reconstructed samples before predictor updates; and add cancellation/deadline checkpoints. These targeted changes do not establish a complete parser security audit or replace the required hour-long fuzz campaigns. Parser/core limits at this stage are internal constants, not the public `ResourceLimits` integration.

Tests under `Tests/SwiftJXLCoreTests` generate synthetic greyscale data with zero, maximum and changing samples. `ScalarOracleTests` invokes test-only `cjxl` and `djxl` 0.12.0 for 25 images: five precisions × five geometries (`1×1`, `2×3`, `31×17`, `128×129`, `255×17`). Both directions check exact samples and precision, including the PNM header. The tests require `SWIFTJXL_ORACLE_BIN`; without it the oracle gate is explicitly skipped. They add no reference codec runtime dependency. Malformed-input tests cover every truncated prefix and single-bit mutation of a generated fixture, trailing bytes, invalid input samples, sliced data, extreme bit-reader offsets, container size overflow, duplicate/mixed/missing partials and cancellation.

The first expanded validation run correctly stopped on an evidence-harness defect: test discovery assumed only `SwiftJXLTests`, although execution now included `SwiftJXLCoreTests` too. All 41 declarations had passed, but discovery counted 32. The harness now inventories every named local test target and continues to require discovery/execution agreement; the failed run is retained under `work/evidence/scalar-qualification` and is not reported as a passing qualification.


The corrected qualification command completed with exit 0:

```sh
SWIFTJXL_ORACLE_BIN=/opt/homebrew/bin \
SWIFTJXL_ORACLE_OUTPUT="$PWD/../evidence/scalar-qualification-oracle" \
bash Scripts/validate.sh --checks debug,release,consumer,asan,tsan \
  --jobs 2 --disable-package-sandbox --output ../evidence/scalar-qualification-v2
```

Debug, release, AddressSanitizer and ThreadSanitizer each executed 41 declarations / 50 argument cases, with zero failures or skips. The independent public consumer also passed. [Exact commands and tested-source hashes](Evidence/Scalar/report.json), [debug](Evidence/Scalar/debug-tests.xml), [release](Evidence/Scalar/release-tests.xml), [ASan](Evidence/Scalar/asan-tests.xml), [TSan](Evidence/Scalar/tsan-tests.xml), and [oracle executable/fixture hashes](Evidence/Scalar/oracle-manifest.json) preserve the evidence. These are local Apple arm64/Swift 6.4 results. This snapshot has not yet established Linux or other Apple runtime qualification for the migrated algorithms. Controlled performance/allocation measurements and the full fuzz gate remain outstanding; scalar scheduling may reduce predecessor throughput.

## Internal caller-storage integration — 8 October continuation

The scalar decoder now prepares its frame and entropy state separately from final writes. Its sample loop accepts scoped storage access; the caller-buffer path writes samples directly into the existing allocation. Checked geometry supports plane offsets, row/pixel strides and either byte order. Tests preserve allocation identity/address and untouched sentinel bytes in padding, reject undersized buffers before writing, and invalidate a destination when cancellation occurs during its write lease.

Encoding reads an immutable source borrow into one Int32 algorithm working plane, then calls the same scalar encoder. Tests compare exact compressed bytes with the array-based reference path, including eight concurrent encoders sharing one sealed source. The 25 independent fixtures also exercise padded big-endian caller storage in both directions. No pointer escapes its synchronous borrow. The Int32 plane is four bytes per sample, but this is not a measurement of total codec workspace. Allocation/copy instrumentation required by MEM-13 and full resource-policy admission remain open; pointer identity tests alone do not close that gate. The public codec remains unavailable.

Local Swift 6.4 / Apple arm64 validation used the same source and manifest hashes in every configuration: 45 declarations / 59 argument cases each for debug, release, AddressSanitizer and ThreadSanitizer, with no failures or skips. The independent public consumer passed. The first combined run passed debug but failed release debugging-symbol generation with `Operation not permitted` in the agent environment; the failed report is retained. Separate consumer/sanitizer checks passed. Running the same release build in the owner's Terminal succeeded in 30.97 seconds. The owner then ran the supplied continuation script, which reused the build cache and passed the incremental build, test discovery and all release tests. This is a resumed build, not a newly claimed clean build. Evidence: [debug/initial failure](Evidence/Storage/debug-report.json), [sanitizers/consumer](Evidence/Storage/sanitizers-consumer-report.json), [release](Evidence/Storage/release-report.json), [release continuation script](Evidence/Storage/run-release-validation.sh), and [reference binary/fixture hashes](Evidence/Storage/oracle-manifest.json).

The earlier internal-scalar commit `4bfa209` passed all seven jobs in [CI run 37730317969](https://github.com/raster-labs/SwiftJXL/actions/runs/37730317969). That run predates this storage checkpoint; it is not CI evidence for the newer changes. Required public integration, allocation measurements, controlled performance, fuzz campaigns, wider codec profiles and release/platform gates remain outstanding.

## Decoder admission controls and mandatory CI oracle — 8 October

Commit `c5d149a` passed all seven jobs in [run 37741943394](https://github.com/raster-labs/SwiftJXL/actions/runs/37741943394). Subsequent internal decoder changes accept smaller compressed-input, dimension, pixel-count and nesting ceilings, and carry one monotonic deadline from parsing through final writes. Container loops check cancellation/deadline, and expired prepared frames reject before touching the destination. These controls retain the restricted profile's hard maxima. They do not yet implement full workspace/aggregate accounting or enable the public codec.

Five additional tests cover exact size boundaries, expired deadlines before parsing and after frame preparation, nesting rejection and invalid/oversized policy values. [Local debug/ASan/TSan report](Evidence/DecodeLimits/report.json): 50 declarations / 64 cases in each configuration, no failures or skips, including independent oracles. Release execution for this newer source awaits CI; earlier release evidence covers the storage checkpoint only.

A new independent CI job builds test-only libjxl 0.12.0 from commit `a7a9c787341cf703dede03c2009fa460cae5e5df`, with its pinned Brotli/Highway/Little-CMS submodules. `Scripts/validate-oracle.py` requires both tools and all debug/release tests, rejects missing/skipped oracle coverage, records source/tool/fixture hashes and uploads evidence. This does not add a package dependency or runtime external process to SwiftJXL. The new job is pending first execution; its addition alone is not a passing gate.
